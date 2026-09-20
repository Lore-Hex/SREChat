"""One incident, two emails: "it broke", then "how it ended".

The email policy swung between two failures, and both were the same mistake —
deciding per MESSAGE instead of per INCIDENT.

  * Emailing every finding sent 29 emails in two hours: historical log lines,
    stale Sentry issues, and a model that wrote "NONE — already recovered" where
    an exact match wanted "NONE".
  * Emailing only after a mutating tool call then sent ZERO emails for sixteen
    days, across 50 investigations a day, including real ones. A region could
    have gone down and the only trace would have been a chat line.

A human wants to hear about an incident exactly twice: when it starts, and how
it ends. This module is the ledger that makes that true. It is persisted,
because the things that multiply emails — crash loops, flapping, a re-run
investigation — all involve the agent restarting or re-entering the same code
with a fresh memory.

Nothing here decides WHAT is an incident. Callers do that, from deterministic
checks where they can. This only decides whether a given incident has already
been said.
"""

from __future__ import annotations

import json
import os
import time
from typing import Callable

STATE_PATH = os.environ.get(
    "SRE_INCIDENT_STATE", os.path.expanduser("~/.srechat_incidents.json")
)

# An incident that is still open is worth a reminder, but rarely. Daily is often
# enough to stop it being forgotten and rare enough not to be muted.
REMIND_SECONDS = float(os.environ.get("SRE_INCIDENT_REMIND_SECONDS", str(24 * 3600)))

# The ceiling under everything else. Whatever a bug upstream decides is an
# incident, this agent cannot send more than this many incident emails an hour.
# The flood that prompted this module peaked at ~10/hour per region; a real bad
# day is an opening and an outcome for two or three incidents.
MAX_PER_HOUR = int(os.environ.get("SRE_INCIDENT_MAX_EMAILS_PER_HOUR", "6"))

Sender = Callable[[str], str]


def _load() -> dict:
    try:
        with open(STATE_PATH) as fh:
            state = json.load(fh)
        if isinstance(state, dict):
            state.setdefault("incidents", {})
            state.setdefault("sent", [])
            return state
    except (OSError, ValueError):
        pass
    return {"incidents": {}, "sent": []}


def _save(state: dict) -> None:
    try:
        tmp = f"{STATE_PATH}.tmp"
        with open(tmp, "w") as fh:
            json.dump(state, fh)
        os.replace(tmp, STATE_PATH)
    except OSError:
        pass  # a ledger that cannot persist must not stop the email going out


def _ceiling_hit(state: dict, now: float) -> bool:
    state["sent"] = [t for t in state.get("sent", []) if now - t < 3600]
    return len(state["sent"]) >= MAX_PER_HOUR


def _deliver(state: dict, send: Sender, text: str, now: float) -> tuple[bool, str]:
    """Send, and count it only if it actually went.

    A failed or suppressed send must not consume the incident: the next call for
    the same incident should try again, or a provider blip at the wrong moment
    turns a real outage into permanent silence.
    """
    if _ceiling_hit(state, now):
        return False, f"suppressed: {MAX_PER_HOUR} incident emails already sent this hour"
    try:
        result = str(send(text))
    except Exception as exc:  # noqa: BLE001 — the ledger must never raise into the watchdog
        return False, f"email FAILED: {exc}"
    if result.startswith("email sent"):
        state["sent"].append(now)
        return True, result
    return False, result


def opened(key: str, text: str, send: Sender, *, now: float | None = None) -> str:
    """Say that something broke — once per incident.

    `text` is the whole email: first line subject, rest body.
    """
    now = time.time() if now is None else now
    state = _load()
    entry = state["incidents"].get(key)

    if entry and entry.get("status") == "open":
        told = entry.get("emailed_at")
        if told is not None and now - told < REMIND_SECONDS:
            return f"suppressed: already reported {int(now - told)}s ago"
        # Open but never successfully emailed, or a reminder is due: try again.
    else:
        entry = {"status": "open", "opened_at": now, "emailed_at": None,
                 "unresolved_emailed_at": None}

    ok, result = _deliver(state, send, text, now)
    if ok:
        entry["emailed_at"] = now
    state["incidents"][key] = entry
    _save(state)
    return result


def outcome(key: str, text: str, send: Sender, *, resolved: bool,
            now: float | None = None) -> str:
    """Say how it ended.

    A RESOLVED outcome closes the incident, and is only emailed if the opening
    was — "recovered" about something nobody was told broke is noise, and it is
    what a suppressed opening during a storm would otherwise produce.

    An UNRESOLVED outcome is emailed once and leaves the incident open, so an
    agent that re-investigates the same unfixable outage every few minutes says
    "I could not fix this" one time, not every time.
    """
    now = time.time() if now is None else now
    state = _load()
    entry = state["incidents"].get(key)
    if not entry or entry.get("status") != "open":
        return "suppressed: no open incident"

    if resolved:
        told = entry.get("emailed_at")
        entry["status"] = "resolved"
        entry["closed_at"] = now
        if told is None:
            state["incidents"][key] = entry
            _save(state)
            return "suppressed: the opening was never emailed"
        ok, result = _deliver(state, send, text, now)
        state["incidents"][key] = entry
        _save(state)
        return result

    last = entry.get("unresolved_emailed_at")
    if last is not None and now - last < REMIND_SECONDS:
        return f"suppressed: already said unresolved {int(now - last)}s ago"
    ok, result = _deliver(state, send, text, now)
    if ok:
        entry["unresolved_emailed_at"] = now
    state["incidents"][key] = entry
    _save(state)
    return result


def report(key: str, text: str, send: Sender, *, remind_seconds: float | None = None,
           now: float | None = None) -> str:
    """A one-shot finding: opening and outcome in a single email.

    For things found already finished, or fixed in the same breath — a sweep
    finding with its diagnosis attached. Emailed at most once per `key` per
    reminder window, so a chronic source reports once and then stays quiet.
    """
    now = time.time() if now is None else now
    window = REMIND_SECONDS if remind_seconds is None else remind_seconds
    state = _load()
    entry = state["incidents"].get(key) or {}
    told = entry.get("emailed_at")
    if told is not None and now - told < window:
        return f"suppressed: already reported {int(now - told)}s ago"

    ok, result = _deliver(state, send, text, now)
    if ok:
        state["incidents"][key] = {"status": "resolved", "opened_at": now,
                                   "emailed_at": now, "closed_at": now,
                                   "unresolved_emailed_at": None}
    _save(state)
    return result


def is_open(key: str) -> bool:
    return (_load()["incidents"].get(key) or {}).get("status") == "open"


def prune(max_age_seconds: float = 14 * 24 * 3600, *, now: float | None = None) -> int:
    """Forget resolved incidents older than two weeks. Returns how many."""
    now = time.time() if now is None else now
    state = _load()
    before = len(state["incidents"])
    state["incidents"] = {
        k: v for k, v in state["incidents"].items()
        if v.get("status") == "open" or now - (v.get("closed_at") or v.get("opened_at") or now) < max_age_seconds
    }
    _save(state)
    return before - len(state["incidents"])
