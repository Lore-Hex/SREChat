#!/usr/bin/env python3
"""Ways for an agent to pull a human into the loop, loudest last.

    push_notify_human(reason)   quiet   — banner on the phone
    sms_human(reason)           louder  — text message
    call_human(reason)          loudest — the phone actually rings

Two independent carriers behind SMS and voice (Telnyx and Twilio), tried in
order, because a pager with one vendor is a pager with one outage away from
silence. Which carrier delivered is recorded, so a quietly-failing primary is
visible instead of merely slower.

Stdlib only, like the rest of the agent — urllib is enough here (unlike APNs,
neither carrier needs HTTP/2), and a pip dependency is one more thing that can
be broken on the night it matters.

THE LEASH
---------
These are the only tools an agent has that can wake someone at 3am, so every
one of them is rate limited, deduplicated, and persisted to disk. Persistence
is the important part: an agent in a crash loop restarts with fresh memory, and
without an on-disk counter it would phone a sleeping human once per restart,
forever. The limits are deliberately tight — an escalation that fires
constantly trains its reader to ignore it, which is worse than no pager at all.

Configuration (all optional; a channel with no credentials reports that it is
unavailable rather than pretending to succeed):

    HUMAN_PHONE            E.164 number to reach, e.g. +15551234567
    EMAIL_TO / EMAIL_FROM  where after-action reports go, and from whom
    SENDGRID_API_KEY       SendGrid (primary email path)
    SMTP_HOST/PORT/USER/PASS   any SMTP server (second, vendor-independent path)
    TELNYX_API_KEY         Telnyx v2 API key
    TELNYX_FROM            Telnyx number to send from
    TWILIO_ACCOUNT_SID     Twilio account SID
    TWILIO_AUTH_TOKEN      Twilio auth token
    TWILIO_FROM            Twilio number to send from
    ESCALATE_STATE         override the rate-limit state file
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

HUMAN_PHONE = os.environ.get("HUMAN_PHONE", "").strip()

TELNYX_API_KEY = os.environ.get("TELNYX_API_KEY", "").strip()
TELNYX_FROM = os.environ.get("TELNYX_FROM", "").strip()

# Twilio supports two credential styles and they are NOT interchangeable in the
# URL. An API Key ("SK…") authenticates as SID:SECRET, but the request path must
# still carry the ACCOUNT sid ("AC…"). Using the SK in both places looks fine
# against some read endpoints and then fails on send, so they are kept separate.
TWILIO_SID = os.environ.get("TWILIO_ACCOUNT_SID", "").strip()
TWILIO_TOKEN = os.environ.get("TWILIO_AUTH_TOKEN", "").strip()
TWILIO_KEY_SID = os.environ.get("TWILIO_API_KEY_SID", "").strip()
TWILIO_KEY_SECRET = os.environ.get("TWILIO_API_KEY_SECRET", "").strip()
TWILIO_FROM = os.environ.get("TWILIO_FROM", "").strip()

STATE_PATH = os.environ.get("ESCALATE_STATE", os.path.expanduser("~/.srechat_escalations.json"))

# (max sends, window seconds, minimum gap between sends)
LIMITS = {
    "push": (20, 3600, 0),
    "sms": (6, 3600, 120),
    "call": (2, 3600, 900),
    "email": (20, 3600, 0),
}

# The same incident must not page twice through the same channel inside this
# window. Flapping is the normal failure mode, and it is what turns a pager
# into noise.
DEDUPE_SECONDS = 1800


def _now() -> float:
    return time.time()


def _load_state() -> dict:
    try:
        with open(STATE_PATH) as fh:
            state = json.load(fh)
        return state if isinstance(state, dict) else {}
    except (OSError, ValueError):
        return {}


def _save_state(state: dict) -> None:
    try:
        with open(STATE_PATH, "w") as fh:
            json.dump(state, fh)
    except OSError:
        pass  # a rate limiter that cannot persist must not break paging


def _fingerprint(reason: str) -> str:
    return hashlib.sha1(reason.strip().lower().encode()).hexdigest()[:16]


def allowed(channel: str, reason: str, now: float | None = None) -> tuple[bool, str]:
    """Rate limit + dedupe. Returns (allowed, why_not).

    Deliberately checked BEFORE any carrier call, so a blocked escalation costs
    nothing and cannot be half-sent.
    """
    now = _now() if now is None else now
    limit, window, min_gap = LIMITS.get(channel, (5, 3600, 60))
    state = _load_state()
    sends = [t for t in state.get(channel, []) if now - t < window]

    # Dedupe first: when the same incident repeats, "you already said this" is
    # a more useful thing to tell the agent than "too soon", even though both
    # suppress. The agent reads these and acts on them.
    key = f"dedupe:{channel}:{_fingerprint(reason)}"
    last = state.get(key)
    if isinstance(last, (int, float)) and now - last < DEDUPE_SECONDS:
        return False, f"duplicate: same reason already sent by {channel} {int(now - last)}s ago"

    if len(sends) >= limit:
        return False, f"rate limited: {len(sends)} {channel} in the last {window // 60}min (max {limit})"

    if sends and min_gap and now - max(sends) < min_gap:
        wait = int(min_gap - (now - max(sends)))
        return False, f"too soon: another {channel} in {wait}s (min gap {min_gap}s)"

    return True, ""


def record(channel: str, reason: str, now: float | None = None) -> None:
    now = _now() if now is None else now
    state = _load_state()
    window = LIMITS.get(channel, (5, 3600, 60))[1]
    state[channel] = [t for t in state.get(channel, []) if now - t < window] + [now]
    state[f"dedupe:{channel}:{_fingerprint(reason)}"] = now
    _save_state(state)


def _post(url: str, data: dict, headers: dict, timeout: int = 20) -> tuple[int, str]:
    body = urllib.parse.urlencode(data).encode()
    req = urllib.request.Request(url, data=body, method="POST")
    for key, value in headers.items():
        req.add_header(key, value)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode(errors="replace")[:200]
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode(errors="replace")[:200]
    except Exception as exc:  # noqa: BLE001 — a carrier being down is normal
        return 0, f"{type(exc).__name__}: {exc}"


def _post_json(url: str, payload: dict, headers: dict, timeout: int = 20) -> tuple[int, str]:
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    for key, value in headers.items():
        req.add_header(key, value)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode(errors="replace")[:200]
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode(errors="replace")[:200]
    except Exception as exc:  # noqa: BLE001
        return 0, f"{type(exc).__name__}: {exc}"


# ------------------------------------------------------------------ carriers

def telnyx_available() -> bool:
    return bool(TELNYX_API_KEY and TELNYX_FROM and HUMAN_PHONE)


def twilio_available() -> bool:
    has_auth = bool(TWILIO_KEY_SID and TWILIO_KEY_SECRET) or bool(TWILIO_TOKEN)
    return bool(TWILIO_SID and has_auth and TWILIO_FROM and HUMAN_PHONE)


def _twilio_auth() -> dict:
    user, secret = (
        (TWILIO_KEY_SID, TWILIO_KEY_SECRET) if TWILIO_KEY_SID and TWILIO_KEY_SECRET
        else (TWILIO_SID, TWILIO_TOKEN)
    )
    return {"Authorization": "Basic " + base64.b64encode(f"{user}:{secret}".encode()).decode()}


def telnyx_sms(text: str) -> tuple[int, str]:
    return _post_json(
        "https://api.telnyx.com/v2/messages",
        {"from": TELNYX_FROM, "to": HUMAN_PHONE, "text": text[:1500]},
        {"Authorization": f"Bearer {TELNYX_API_KEY}"},
    )


def twilio_sms(text: str) -> tuple[int, str]:
    return _post(
        f"https://api.twilio.com/2010-04-01/Accounts/{TWILIO_SID}/Messages.json",
        {"From": TWILIO_FROM, "To": HUMAN_PHONE, "Body": text[:1500]},
        _twilio_auth(),
    )


EMAIL_TO = os.environ.get("EMAIL_TO", "").strip()
EMAIL_FROM = os.environ.get("EMAIL_FROM", "").strip()
SENDGRID_KEY = os.environ.get("SENDGRID_API_KEY", "").strip()
SMTP_HOST = os.environ.get("SMTP_HOST", "").strip()
SMTP_PORT = int(os.environ.get("SMTP_PORT", "587") or 587)
SMTP_USER = os.environ.get("SMTP_USER", "").strip()
SMTP_PASS = os.environ.get("SMTP_PASS", "").strip()


def sendgrid_available() -> bool:
    return bool(SENDGRID_KEY and EMAIL_TO and EMAIL_FROM)


def smtp_available() -> bool:
    return bool(SMTP_HOST and SMTP_USER and SMTP_PASS and EMAIL_TO and EMAIL_FROM)


def sendgrid_email(subject: str, body: str) -> tuple[int, str]:
    return _post_json(
        "https://api.sendgrid.com/v3/mail/send",
        {
            "personalizations": [{"to": [{"email": EMAIL_TO}]}],
            "from": {"email": EMAIL_FROM},
            "subject": subject[:200],
            "content": [{"type": "text/plain", "value": body}],
        },
        {"Authorization": f"Bearer {SENDGRID_KEY}"},
    )


def smtp_email(subject: str, body: str) -> tuple[int, str]:
    """Plain SMTP, stdlib only — a second path that shares no vendor with
    SendGrid, so an outage at one does not take the record-keeping with it."""
    import smtplib
    from email.message import EmailMessage

    message = EmailMessage()
    message["Subject"] = subject[:200]
    message["From"] = EMAIL_FROM
    message["To"] = EMAIL_TO
    message.set_content(body)
    try:
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=25) as smtp:
            smtp.starttls()
            smtp.login(SMTP_USER, SMTP_PASS)
            smtp.send_message(message)
        return 250, "sent"
    except Exception as exc:  # noqa: BLE001
        return 0, f"{type(exc).__name__}: {exc}"


def _spoken(text: str) -> str:
    """What the phone call actually says. Repeated once — a ringing phone is
    answered mid-sentence, so the first pass is usually half heard."""
    body = text[:400].replace("&", " and ").replace("<", " ").replace(">", " ")
    # Spoken, not written: the colon is silent, so the brand becomes a sentence
    # rather than "Trusted Router colon disk full".
    if body.lower().startswith(BRAND.lower() + ":"):
        body = body[len(BRAND) + 1:].strip()
    elif body.lower().startswith(BRAND.lower()):
        body = body[len(BRAND):].strip()
    return f"{BRAND} notification. {body}. Again. {body}."


def twilio_call(text: str) -> tuple[int, str]:
    # Inline TwiML: no webhook to host, so the call path has no dependency on
    # our own deployment being up — which is the situation it exists for.
    twiml = f"<Response><Say voice=\"alice\">{_spoken(text)}</Say></Response>"
    return _post(
        f"https://api.twilio.com/2010-04-01/Accounts/{TWILIO_SID}/Calls.json",
        {"From": TWILIO_FROM, "To": HUMAN_PHONE, "Twiml": twiml},
        _twilio_auth(),
    )


def telnyx_call(text: str) -> tuple[int, str]:
    # Telnyx TeXML fetches instructions from a URL rather than accepting them
    # inline, so this points at the deployment's own /texml endpoint. That is a
    # real dependency, which is exactly why Twilio is tried first for voice.
    base = os.environ.get("TEXML_BASE", "https://sre0.trustedrouter.com").rstrip("/")
    url = f"{base}/texml?text=" + urllib.parse.quote(text[:300])
    # NOT the number's connection id and NOT the TeXML application id: Telnyx
    # wants the ORGANIZATION id here, which /v2/whoami reports.
    account = os.environ.get("TELNYX_ACCOUNT_ID", "").strip()
    # A TeXML application supplies the outbound voice profile that authorizes
    # origination. Without it the API answers 422 Missing ApplicationSid, and
    # with an app that has no profile attached, 403 D38.
    application = os.environ.get("TELNYX_TEXML_APP_ID", "").strip()
    if not account or not application:
        return 0, "TELNYX_ACCOUNT_ID and TELNYX_TEXML_APP_ID are both required for Telnyx voice"
    return _post(
        f"https://api.telnyx.com/v2/texml/Accounts/{account}/Calls",
        {
            "From": TELNYX_FROM,
            "To": HUMAN_PHONE,
            "Url": url,
            "ApplicationSid": application,
        },
        {"Authorization": f"Bearer {TELNYX_API_KEY}"},
    )


# ----------------------------------------------------------------- channels

BRAND = "Trusted Router"


def branded(text: str) -> str:
    """Every SMS and call opens by naming who is calling.

    An unrecognized number reading an unattributed sentence at 3am is
    indistinguishable from a scam, and gets hung up on — the page the agent
    escalated is the one that gets ignored. Idempotent, so text that already
    carries the brand is not branded twice.
    """
    body = (text or "").strip()
    if body.lower().startswith(BRAND.lower()):
        return body
    return f"{BRAND}: {body}"


def _try_carriers(kind: str, text: str) -> tuple[bool, str]:
    """Try each configured carrier in order; report which one delivered."""
    # Branded here, at the one path both channels and every caller pass
    # through, so no carrier method or future channel can skip it.
    text = branded(text)

    if kind == "sms":
        chain = [("telnyx", telnyx_available, telnyx_sms), ("twilio", twilio_available, twilio_sms)]
    else:
        # Voice: Twilio first — its inline TwiML needs nothing of ours running.
        chain = [("twilio", twilio_available, twilio_call), ("telnyx", telnyx_available, telnyx_call)]

    attempts = []
    for name, available, send in chain:
        if not available():
            attempts.append(f"{name}=unconfigured")
            continue
        status, body = send(text)
        if 200 <= status < 300:
            return True, f"delivered via {name} (after: {', '.join(attempts)})" if attempts else f"delivered via {name}"
        attempts.append(f"{name}={status} {body[:80]}")

    return False, "; ".join(attempts) or "no carrier configured"


def _escalate(channel: str, reason: str, send) -> str:
    """Apply the leash, then send. Returns a line for the chat transcript."""
    reason = (reason or "").strip()
    if not reason:
        return "escalation refused: say what is wrong — a page with no reason cannot be acted on"

    ok, why_not = allowed(channel, reason)
    if not ok:
        # Deliberately NOT an error. The agent should carry on handling the
        # incident; being told "you already paged about this" is information,
        # not a failure.
        return f"{channel} suppressed ({why_not}). The human has already been told, or will be shortly."

    delivered, detail = send(reason)
    if delivered:
        record(channel, reason)
        return f"{channel} sent: {detail}"
    return f"{channel} FAILED: {detail}"


def push_notify_human(reason: str) -> str:
    """Quietest escalation: a banner on the phone. Use for things worth knowing
    but not worth waking someone for."""
    def send(text):
        try:
            import sre_agent
        except ImportError:
            return False, "agent module unavailable"
        devices = sre_agent.owner_devices()
        if not devices:
            return False, "no registered device (open SREChat once to register it)"
        import apns
        if not apns.enabled():
            return False, "APNs not configured on this host"
        results = []
        for token, meta in devices.items():
            status, body = apns.push(token, "SREChat", text, env=(meta or {}).get("env"))
            results.append(f"{token[:8]}…={status}")
            if status == 200:
                return True, f"apns ({', '.join(results)})"
        return False, f"apns ({', '.join(results)})"

    return _escalate("push", reason, send)


def sms_human(reason: str) -> str:
    """Middle escalation: a text message, through Telnyx or Twilio."""
    # No prefix here: _try_carriers brands every channel identically, and a
    # second prefix would read "Trusted Router: SREChat: ...".
    return _escalate("sms", reason, lambda text: _try_carriers("sms", text))


def call_human(reason: str) -> str:
    """Loudest escalation: the phone rings and a voice reads the reason.

    For things that are genuinely urgent or genuinely dangerous to get wrong —
    not for a region that flapped once.
    """
    return _escalate("call", reason, lambda text: _try_carriers("call", text))


TR_BASE_URL = os.environ.get("TR_BASE_URL", "https://api.trustedrouter.com/v1")
TR_API_KEY = os.environ.get("TR_API_KEY", "")


def tr_notify_available() -> bool:
    return bool(TR_API_KEY)


def tr_notify(channel: str, subject: str, body: str) -> tuple[int, str]:
    """Reach the owner through TrustedRouter's own notify API.

    TR resolves the destination from the api key to the workspace owner, so
    this agent never holds the address it is writing to — and never holds an
    email credential either. The reply says whether it was DELIVERED, which is
    the fact worth logging; "accepted" has misled us on this project before.
    """
    payload = json.dumps({"channel": channel, "subject": subject[:120], "body": body}).encode()
    req = urllib.request.Request(
        f"{TR_BASE_URL.rstrip('/')}/notify",
        data=payload,
        method="POST",
        headers={"Authorization": f"Bearer {TR_API_KEY}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            answer = json.loads(resp.read().decode() or "{}")
        delivered = bool(answer.get("delivered"))
        detail = f"{answer.get('carrier') or channel}: {answer.get('detail') or ''}".strip()
        return (200 if delivered else 502), detail
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode()[:200]
        # A refusal is the caller's to fix (verify a phone, attach an email);
        # say which, rather than reporting a bare status nobody can act on.
        return exc.code, raw
    except Exception as exc:  # noqa: BLE001
        return 0, f"{type(exc).__name__}: {exc}"


def tr_notify_email(subject: str, body: str) -> tuple[int, str]:
    return tr_notify("email", subject, body)


def email_human(text: str, attachments: str = "") -> str:
    """Quiet, detailed, and for the record — an after-action report.

    Not an escalation: nothing about this interrupts anyone. It exists so that
    what an agent DID is recoverable later, in full, rather than compressed
    into a chat line. First line is the subject, the rest is the body.
    """
    text = (text or "").strip()
    if not text:
        return "email refused: nothing to say"

    lines = text.splitlines()
    subject = lines[0][:200]
    body = "\n".join(lines[1:]).strip() or lines[0]

    if attachments:
        body = f"{body}\n\n{'=' * 60}\nFULL LOG\n{'=' * 60}\n{attachments}"

    ok, why_not = allowed("email", text)
    if not ok:
        return f"email suppressed ({why_not})"

    attempts = []
    for name, available, send in (
        # TrustedRouter first. It sends through SES from the alert identity
        # using credentials that live in TR, so no email secret has to sit on
        # these VMs at all — and a credential nobody has to place is a
        # credential nobody has to remember to rotate or delete.
        ("trustedrouter", tr_notify_available, tr_notify_email),
        ("sendgrid", sendgrid_available, sendgrid_email),
        ("smtp", smtp_available, smtp_email),
    ):
        if not available():
            attempts.append(f"{name}=unconfigured")
            continue
        status_code, detail = send(f"[SREChat] {subject}", body)
        if 200 <= status_code < 300:
            record("email", text)
            return f"email sent via {name}"
        attempts.append(f"{name}={status_code} {detail[:80]}")

    return "email FAILED: " + ("; ".join(attempts) or "no provider configured")


def status() -> str:
    """What can actually reach the human right now."""
    lines = [
        f"human phone: {'set' if HUMAN_PHONE else 'NOT SET'}",
        f"telnyx: {'ready' if telnyx_available() else 'unconfigured'}",
        f"twilio: {'ready' if twilio_available() else 'unconfigured'}",
    ]
    now = _now()
    state = _load_state()
    for channel, (limit, window, _gap) in LIMITS.items():
        used = len([t for t in state.get(channel, []) if now - t < window])
        lines.append(f"{channel}: {used}/{limit} used in the last {window // 60}min")
    return "\n".join(lines)
