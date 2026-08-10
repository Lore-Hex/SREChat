#!/usr/bin/env python3
"""APNs push for SREAgent, using only the standard library.

Why no `pyjwt`/`httpx[http2]`: the agent runs on three different clouds, and a
pip dependency is three chances for the paging path to be the thing that is
broken when a node goes down. `openssl` and `curl` (with HTTP/2) are already on
every host, so signing and sending use those instead and the agent stays
stdlib-only like the rest of it.

APNs requires HTTP/2, which `urllib` cannot speak — hence curl rather than the
`urllib.request` used everywhere else in the agent.

Configuration (all required, or `enabled()` is False and pushing is skipped):

    APNS_KEY_PATH   path to the AuthKey_XXXXXXXXXX.p8 downloaded from Apple
    APNS_KEY_ID     the 10-character key id shown next to that key
    APNS_TEAM_ID    the 10-character developer team id
    APNS_BUNDLE_ID  the app's bundle id (default co.lorehex.srechat)
    APNS_ENV        "development" (Xcode builds) or "production" (TestFlight)

A local notification already fires while SREChat is open; this is what reaches
the phone when the app is closed, which is the case that matters at 3am.
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
import time

BUNDLE_ID = os.environ.get("APNS_BUNDLE_ID", "co.lorehex.srechat")
KEY_PATH = os.environ.get("APNS_KEY_PATH", "")
KEY_ID = os.environ.get("APNS_KEY_ID", "")
TEAM_ID = os.environ.get("APNS_TEAM_ID", "")

# A token minted for one environment is rejected by the other, and the failure
# is a silent 400 BadDeviceToken rather than anything that looks like a
# misconfiguration, so it is worth being explicit about which one we are on.
DEFAULT_ENV = os.environ.get("APNS_ENV", "development").strip().lower()


def host_for(env: str | None = None) -> str:
    env = (env or DEFAULT_ENV).strip().lower()
    return "api.sandbox.push.apple.com" if env.startswith("dev") else "api.push.apple.com"

# Apple rejects tokens older than 1h and also rejects minting a new one more
# than once every 20 minutes, so reuse well inside both bounds.
_TOKEN_TTL = 40 * 60
_cached: tuple[str, float] | None = None


def enabled() -> bool:
    """True when a push could actually be sent. Everything else no-ops on False
    so a deployment without an APNs key still runs, just without push."""
    return bool(KEY_ID and TEAM_ID and KEY_PATH and os.path.exists(KEY_PATH))


def _b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _der_to_raw(der: bytes) -> bytes:
    """ECDSA signatures come out of openssl as DER, but JWS ES256 wants the raw
    64-byte r||s. Without this the JWT is well-formed and Apple answers 403
    InvalidProviderToken, which reads like a wrong key rather than a wrong
    encoding.

        ECDSA-Sig-Value ::= SEQUENCE { r INTEGER, s INTEGER }
    """
    if not der or der[0] != 0x30:
        raise ValueError("not a DER SEQUENCE")
    i = 2
    # Long-form length: P-256 signatures are short-form, but a malformed parse
    # here would produce a subtly wrong signature rather than an error.
    if der[1] & 0x80:
        i = 2 + (der[1] & 0x7F)

    def integer(pos: int) -> tuple[bytes, int]:
        if der[pos] != 0x02:
            raise ValueError("expected DER INTEGER")
        length = der[pos + 1]
        value = der[pos + 2 : pos + 2 + length]
        # DER prepends 0x00 when the high bit is set; strip it, and left-pad
        # short values, so both halves are exactly 32 bytes.
        return value.lstrip(b"\x00").rjust(32, b"\x00"), pos + 2 + length

    r, i = integer(i)
    s, _ = integer(i)
    return r + s


def _sign(signing_input: bytes) -> bytes:
    proc = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", KEY_PATH],
        input=signing_input,
        capture_output=True,
        timeout=15,
    )
    if proc.returncode != 0:
        raise RuntimeError("openssl sign failed: " + proc.stderr.decode()[:200])
    return _der_to_raw(proc.stdout)


def provider_token(now: float | None = None) -> str:
    global _cached
    now = time.time() if now is None else now
    if _cached and now - _cached[1] < _TOKEN_TTL:
        return _cached[0]
    header = _b64(json.dumps({"alg": "ES256", "kid": KEY_ID}, separators=(",", ":")).encode())
    claims = _b64(json.dumps({"iss": TEAM_ID, "iat": int(now)}, separators=(",", ":")).encode())
    signing_input = f"{header}.{claims}".encode()
    token = f"{header}.{claims}.{_b64(_sign(signing_input))}"
    _cached = (token, now)
    return token


def push(
    device_token: str,
    title: str,
    body: str,
    collapse_id: str = "",
    env: str | None = None,
) -> tuple[int, str]:
    """Send one alert push. Returns (status, body); 200 is delivered to Apple.

    410 means the app was uninstalled and the caller should drop the token —
    left in place it is a permanent failure on every future page.

    `env` comes from the device record rather than this process's own setting,
    so one deployment can page a debug build on a phone and a TestFlight build
    on another without either landing on the wrong Apple host.
    """
    if not enabled():
        return (0, "apns not configured")

    payload = {
        "aps": {
            "alert": {"title": title, "body": body},
            "sound": "default",
            # Time-sensitive breaks through Focus/Do Not Disturb, which is the
            # entire point of a page. It requires the Time Sensitive
            # entitlement, which the app already declares for its local alerts.
            "interruption-level": "time-sensitive",
            "badge": 1,
        }
    }
    args = [
        "curl", "--http2", "-s", "-S", "--max-time", "20",
        "-o", "-", "-w", "\n%{http_code}",
        "-X", "POST",
        "-H", f"authorization: bearer {provider_token()}",
        "-H", f"apns-topic: {BUNDLE_ID}",
        "-H", "apns-push-type: alert",
        "-H", "apns-priority: 10",
        "-H", "content-type: application/json",
    ]
    if collapse_id:
        # Collapse repeats of the same alert into one notification instead of a
        # screenful: a flapping node otherwise pages you every poll.
        args += ["-H", f"apns-collapse-id: {collapse_id[:64]}"]
    args += ["-d", json.dumps(payload), f"https://{host_for(env)}/3/device/{device_token}"]

    try:
        proc = subprocess.run(args, capture_output=True, timeout=25)
    except subprocess.TimeoutExpired:
        return (0, "curl timed out")
    out = proc.stdout.decode(errors="replace")
    status_line = out.rsplit("\n", 1)
    if len(status_line) != 2 or not status_line[1].strip().isdigit():
        return (0, (proc.stderr.decode(errors="replace") or out)[:200])
    return (int(status_line[1].strip()), status_line[0].strip())
