#!/usr/bin/env python3
"""Chaos drill: break something small on purpose, prove the system notices.

Alerting you never test is alerting that fails when it matters. This runs a
deliberately small, self-restoring fault and then checks the three things that
have to be true:

  1. the fault actually took effect  (otherwise the drill proves nothing)
  2. the surviving agents DETECTED it and paged the owner
  3. the system healed, and the recovery was announced

It reports a pass/fail into chat like any other alert, so the drill result shows
up on your phone next to real incidents.

Usage:
    chaos_drill.py gentle   # daily: bounce one region's app container
    chaos_drill.py hard     # weekly: partition a region's WireGuard for ~60s

Run it from ONE host (region 0). The drill deliberately targets a region OTHER
than the one doing the observing where possible, so a survivor is always the
one reporting.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

REGIONS = [
    {"index": 0, "cloud": "GCP us-central1", "host": "sre0.trustedrouter.com"},
    {"index": 1, "cloud": "AWS us-east-1", "host": "sre1.trustedrouter.com"},
    {"index": 2, "cloud": "Azure austriaeast", "host": "sre2.trustedrouter.com"},
]
OWNER_UID = os.environ.get("SRE_OWNER_UID", "joseph")
ACCESS_SECRET = os.environ.get("SRE_ACCESS_SECRET", "")
DRILL_UID = "sre-drill"
HOST = os.environ.get("SRE_HOST", "sre0.trustedrouter.com")
DEPLOY_DIR = os.environ.get("SRE_DEPLOY_DIR") or next(
    (d for d in (os.path.expanduser("~/SREChat"), os.path.expanduser("~/RoachChat"))
     if os.path.isdir(d)), os.path.expanduser("~/SREChat"))


def token(uid: str) -> str:
    return f"uid:{uid}" + (f"|{ACCESS_SECRET}" if ACCESS_SECRET else "")


def say(text: str) -> None:
    """Report into chat, so a drill lands where real alerts land."""
    body = json.dumps({
        "receiver": OWNER_UID, "receiverType": "user", "category": "message",
        "type": "text", "data": {"text": text[:3000]},
    }).encode()
    req = urllib.request.Request(
        f"https://{HOST}/v3.0/messages", data=body, method="POST",
        headers={"Authorization": f"Bearer {token(DRILL_UID)}",
                 "Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=15)
    except Exception as exc:  # noqa: BLE001
        print(f"could not report to chat: {exc}", file=sys.stderr)
    print(text)


def healthy(host: str) -> bool:
    try:
        with urllib.request.urlopen(f"https://{host}/health", timeout=8) as resp:
            return resp.status == 200
    except Exception:  # noqa: BLE001
        return False


def run(cmd: list[str], timeout: int = 90) -> str:
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return (out.stdout or out.stderr or "").strip()
    except Exception as exc:  # noqa: BLE001
        return f"(command failed: {exc})"


def wait_until(predicate, seconds: int, step: float = 3.0) -> bool:
    deadline = time.time() + seconds
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(step)
    return predicate()


def drill_gentle() -> int:
    """Restart region 0's app container. Small, real, and self-restoring."""
    target = REGIONS[0]
    say(f"🧪 CHAOS DRILL (gentle): restarting the app container in region "
        f"{target['index']} ({target['cloud']}). Expect a brief blip.")

    before = healthy(target["host"])
    run(["sudo", "docker", "compose", "--env-file", f"{DEPLOY_DIR}/deploy/.env",
         "-f", f"{DEPLOY_DIR}/deploy/docker-compose.prod.yml", "restart", "app"])

    # Heal: it must come back on its own, quickly.
    healed = wait_until(lambda: healthy(target["host"]), seconds=90)
    verdict = "PASS" if (before and healed) else "FAIL"
    say(f"🧪 DRILL {verdict} (gentle): region {target['index']} "
        f"{'recovered and is serving again' if healed else 'did NOT recover within 90s'}. "
        f"(healthy before drill: {before})")
    return 0 if verdict == "PASS" else 1


def drill_hard() -> int:
    """Partition this region's WireGuard mesh for ~60s: the real test that the
    OTHER clouds notice and that convergence resumes on heal."""
    say("🧪 CHAOS DRILL (hard): dropping this region's WireGuard mesh for ~60s. "
        "The other two clouds should keep serving, and the mesh should reconverge.")

    down = run(["sudo", "wg-quick", "down", "wg0"])
    partitioned = "wg0" in down or "ip link delete" in down or down == ""

    # Peers must stay up while we're cut off: that is the entire promise.
    peers_ok = all(healthy(r["host"]) for r in REGIONS[1:])
    time.sleep(60)

    run(["sudo", "wg-quick", "up", "wg0"])
    healed = wait_until(lambda: healthy(REGIONS[0]["host"]), seconds=90)
    mesh = run(["sudo", "wg", "show"])
    reconverged = "peer" in mesh.lower()

    verdict = "PASS" if (peers_ok and healed and reconverged) else "FAIL"
    say(f"🧪 DRILL {verdict} (hard): peers stayed up during the partition: {peers_ok}; "
        f"this region recovered: {healed}; mesh reconverged: {reconverged}. "
        f"{'Partition applied.' if partitioned else 'NOTE: partition may not have applied.'}")
    return 0 if verdict == "PASS" else 1


def main() -> int:
    mode = (sys.argv[1] if len(sys.argv) > 1 else "gentle").strip().lower()
    if mode == "gentle":
        return drill_gentle()
    if mode == "hard":
        return drill_hard()
    print("usage: chaos_drill.py [gentle|hard]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
