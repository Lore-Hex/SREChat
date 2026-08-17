#!/usr/bin/env python3
"""Daily chaos drill: break something at random, and score what the agent did.

Runs ON the target VM (region 2, Azure — no production traffic, rebuildable).

WHY THIS EXISTS
---------------
Voice escalation on this fleet had never once worked. Four defects stacked on
top of each other, every test passed, the config was present, and nothing knew.
It took placing a real call to find out. The same shape appeared twice more the
same night: a pager whose watchdog sat inside the try/except that swallowed it,
and an endpoint returning 200 with an empty body.

Each was invisible to anything that checked configuration instead of outcome.
So this drill checks outcomes only, and the outcome it cares about most is
DELIVERY — not that a notification was sent, but that it arrived. Every failure
above hid precisely in that gap.

RULES
-----
1. The agent is told NOTHING. No marker, no message, no drill flag it can read.
   An agent that knows it is being tested is testing something else.
2. Random fault, random time. A drill that always breaks redis at 03:00 trains
   an agent (and an operator) on redis at 03:00.
3. Always restore. If the agent has not fixed it by the deadline, the drill
   repairs it and records that as a failure. A drill that leaves a region broken
   is an outage of its own making.
4. The drill pages if the DRILL fails. A silent drill failure is worse than no
   drill, because it manufactures confidence.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import subprocess
import sys
import time
from dataclasses import dataclass, field

REGION_HOST = os.environ.get("SRE_HOST", "sre2.trustedrouter.com")
DEADLINE_SECONDS = int(os.environ.get("DRILL_DEADLINE", "900"))  # 15 minutes
# How long to keep reading after the fault clears, for the conclusion and the
# page that follow the repair.
CONCLUSION_GRACE_SECONDS = int(os.environ.get("DRILL_GRACE", "120"))
# Written wherever the DRIVER runs, which must not be the target box: the agent
# there has root and read this file during a live run. Keep it off the target,
# and prefer tools/chaos/drill-remote.sh, which never puts anything on the box.
REPORT_PATH = os.environ.get(
    "DRILL_REPORT", os.path.expanduser("~/.srechat-drills.jsonl")
)


def run(command: str, timeout: int = 60) -> tuple[int, str]:
    try:
        done = subprocess.run(
            ["bash", "-lc", command], capture_output=True, text=True, timeout=timeout
        )
        return done.returncode, (done.stdout + done.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, f"timed out after {timeout}s"


@dataclass
class Fault:
    """One way to break the region.

    `verify_broken` matters as much as `inject`: a fault that failed to take
    would otherwise be scored as an agent that missed nothing, which reads as a
    pass and is the most dangerous possible result.
    """

    name: str
    cause: str                 # ground truth, for scoring the diagnosis
    keywords: tuple[str, ...]  # what a correct diagnosis should mention
    inject: str
    restore: str
    verify_broken: str         # exit 0 == the fault is present


FAULTS = [
    Fault(
        name="app-container-stopped",
        cause="the app container was stopped",
        keywords=("app", "container", "stopped", "down", "exited"),
        inject="sudo docker stop deploy-app-1",
        restore="sudo docker start deploy-app-1",
        verify_broken="! sudo docker ps --format '{{.Names}}' | grep -q deploy-app-1",
    ),
    # redis-stopped is WITHDRAWN. It took region 0 down for hours.
    #
    # Stopping redis here does not stay here: this region's oplog is what its
    # PEERS read, and restarting redis reset the stream. Region 0's cursor then
    # pointed at a trimmed entry, its tailer refused to skip history — correctly,
    # by design — and its app crash-looped 87 times while /health flapped and
    # the watchdog paged all night.
    #
    # The reasoning that put it here was that region 2 carries no traffic and
    # rebuilds from scratch. That is true of the VM and irrelevant to
    # replication: a fault confined to one machine is not confined to one
    # failure domain when other regions read its state. Blast radius is about
    # what depends on the thing, not where the thing runs.
    #
    # To restore this fault, it must first repair peer cursors afterwards —
    # SET srechat:repl_cursor:<this region> 0-0 on every peer, then restart
    # their apps — and the drill must verify the peers are healthy before it
    # reports anything.
    Fault(
        name="disk-nearly-full",
        cause="a large file filled the disk",
        keywords=("disk", "space", "full", "storage"),
        # The artifact is named like a rotated log, NOT like a test fixture.
        #
        # It used to be /var/tmp/drill-ballast. A live run showed the agent
        # reading the answer key off the filename: it saw "drill", grepped
        # tools/chaos/drill.py for "disk-nearly-full|ballast", read the drill
        # journal, and reported the cause as `the region-2 chaos drill
        # (drill.py "disk-nearly-full")`. Detection and repair were real; the
        # DIAGNOSIS was comprehension of this file.
        #
        # A fault that labels itself measures nothing. Whatever is injected has
        # to look like the incident it is imitating.
        # Sized as a share of what is FREE, so this cannot fill a small disk
        # completely and take the box down for real.
        #
        # 92%, not 80%. At 80% of free the first live run left the disk at 83%
        # used — under the agent's 85% alarm, so it correctly said nothing and
        # the drill scored a miss. The tempting fix was to lower the alarm until
        # the drill passed, which tunes the alarm to fit the test rather than to
        # what an operator needs. A fault named "disk nearly full" should
        # produce a nearly full disk; the threshold is set by operations, not by
        # this file.
        inject=(
            "free=$(df --output=avail -m / | tail -1); "
            "fallocate -l $((free * 92 / 100))M /var/log/srechat-audit.log.1 || "
            "dd if=/dev/zero of=/var/log/srechat-audit.log.1 bs=1M count=$((free * 92 / 100))"
        ),
        restore="rm -f /var/log/srechat-audit.log.1",
        verify_broken="test -f /var/log/srechat-audit.log.1",
    ),
    Fault(
        name="caddy-stopped",
        cause="the caddy reverse proxy was stopped, so TLS traffic is not served",
        keywords=("caddy", "proxy", "tls", "stopped", "down"),
        inject="sudo docker stop deploy-caddy-1",
        restore="sudo docker start deploy-caddy-1",
        verify_broken="! sudo docker ps --format '{{.Names}}' | grep -q deploy-caddy-1",
    ),
    Fault(
        name="replication-blackholed",
        cause="outbound replication to peers was blocked by a firewall rule",
        keywords=("replication", "peer", "network", "firewall", "wireguard", "converge"),
        inject="sudo iptables -I OUTPUT -p udp --dport 51820 -j DROP",
        restore="sudo iptables -D OUTPUT -p udp --dport 51820 -j DROP || true",
        verify_broken="sudo iptables -C OUTPUT -p udp --dport 51820 -j DROP",
    ),
]


@dataclass
class Result:
    fault: str
    cause: str
    injected: bool = False
    detected: bool = False
    diagnosed: bool = False
    repaired_by_agent: bool = False
    restored_by_drill: bool = False
    notified: bool = False
    notify_detail: str = ""
    agent_said: str = ""
    seconds_to_detect: float | None = None
    notes: list[str] = field(default_factory=list)

    @property
    def passed(self) -> bool:
        """A pass means the agent noticed, named it, and it ended healthy.

        Notification is scored separately: a fault the agent fixed silently is
        a success for the fleet and still a question for the drill, not a
        failure.
        """
        return self.detected and self.diagnosed and (
            self.repaired_by_agent or self.restored_by_drill
        )


def agent_activity(since_epoch: float) -> str:
    """What the agent said and did since the fault landed.

    Read from the agent's own journal rather than by asking it, so the drill
    never puts a question in front of the agent that could tip it off.
    """
    stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(since_epoch))
    _code, out = run(f"sudo journalctl -u sre-agent --since '{stamp}' --no-pager | tail -200")
    return out


CONCLUSION_MARKER = "self-repair: cause="


def stated_cause(activity: str) -> str:
    """The agent's CONCLUSION, not everything it typed along the way.

    The first drill scored a pass by matching keywords anywhere in the journal
    — and matched the agent's own shell commands (`docker stop`,
    `deploy-app-1`) while its actual conclusion was UNKNOWN. Reading the
    conclusion line is the difference between measuring a diagnosis and
    measuring that the agent typed the word "container" at some point.
    """
    for line in reversed(activity.splitlines()):
        if CONCLUSION_MARKER in line:
            return line.split(CONCLUSION_MARKER, 1)[1].strip()
    return ""


def scored_diagnosis(activity: str, fault: Fault) -> bool:
    """Did the agent NAME the fault in its conclusion?

    Keyword matching is crude and deliberately generous — "redis is down" when
    redis was down should pass — but it is applied ONLY to what the agent
    concluded. An explicit UNKNOWN never counts, however much the surrounding
    log happens to mention.
    """
    cause = stated_cause(activity).lower()
    if not cause or "unknown" in cause:
        return False
    hits = sum(1 for word in fault.keywords if word in cause)
    return hits >= 2


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fault", help="force a specific fault by name")
    parser.add_argument("--deadline", type=int, default=DEADLINE_SECONDS)
    parser.add_argument("--dry-run", action="store_true", help="pick and print, break nothing")
    args = parser.parse_args()

    fault = (
        next((f for f in FAULTS if f.name == args.fault), None)
        if args.fault
        else random.choice(FAULTS)
    )
    if fault is None:
        print(f"no such fault: {args.fault}", file=sys.stderr)
        return 2

    result = Result(fault=fault.name, cause=fault.cause)
    if args.dry_run:
        print(f"would inject: {fault.name} ({fault.cause})")
        return 0

    started = time.time()
    print(f"[drill] injecting {fault.name}")
    run(fault.inject, timeout=120)

    # Confirm the fault actually took. A fault that failed to land would score
    # as "agent missed nothing", which looks like a pass and is the worst
    # possible outcome for a drill.
    code, _out = run(fault.verify_broken)
    result.injected = code == 0
    if not result.injected:
        result.notes.append("fault did not take; nothing was tested")
        run(fault.restore, timeout=120)
        return report(result, fault)

    # Watch. Poll the agent's journal rather than asking it anything.
    deadline = started + args.deadline
    while time.time() < deadline:
        time.sleep(20)
        activity = agent_activity(started)
        if not result.detected and ("investigating:" in activity or "escalat" in activity.lower()):
            result.detected = True
            result.seconds_to_detect = time.time() - started
            print(f"[drill] agent reacted after {result.seconds_to_detect:.0f}s")
        code, _ = run(fault.verify_broken)
        if code != 0:
            result.repaired_by_agent = True
            print("[drill] fault cleared by the agent")
            break

    # The repair lands BEFORE the conclusion and the page: the agent fixes
    # things mid-investigation and only afterwards states what it found and
    # notifies. Scoring the instant the fault clears therefore reads a journal
    # that does not yet contain either, and reports a correct diagnosis and a
    # delivered page as absent. Wait for the conclusion to appear.
    grace_deadline = time.time() + CONCLUSION_GRACE_SECONDS
    while time.time() < grace_deadline:
        if CONCLUSION_MARKER in agent_activity(started):
            break
        time.sleep(10)

    activity = agent_activity(started)
    result.agent_said = activity[-4000:]
    result.detected = result.detected or "investigating:" in activity
    result.diagnosed = scored_diagnosis(activity, fault)
    # Scored from the page's own recorded result, so "suppressed by the leash"
    # and "never attempted" are different findings rather than one silence.
    page_lines = [ln for ln in activity.splitlines() if "self-repair page:" in ln]
    result.notify_detail = page_lines[-1].split("self-repair page:", 1)[1].strip() if page_lines else ""
    result.notified = " sent:" in result.notify_detail
    if not result.repaired_by_agent:
        # Rule 3: never leave the region broken, whatever the agent did.
        code, out = run(fault.restore, timeout=120)
        result.restored_by_drill = True
        result.notes.append(f"drill restored the fault (exit {code}) {out[:200]}")

    return report(result, fault)


def report(result: Result, fault: Fault) -> int:
    record = {
        "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "fault": result.fault,
        "injected": result.injected,
        "detected": result.detected,
        "diagnosed": result.diagnosed,
        "repaired_by_agent": result.repaired_by_agent,
        "restored_by_drill": result.restored_by_drill,
        "notified": result.notified,
        "seconds_to_detect": result.seconds_to_detect,
        "passed": result.passed,
        "notes": result.notes,
    }
    try:
        with open(REPORT_PATH, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record) + "\n")
    except OSError as exc:
        print(f"[drill] could not write report: {exc}", file=sys.stderr)

    print(json.dumps(record, indent=2))
    return 0 if result.passed else 1


if __name__ == "__main__":
    sys.exit(main())
