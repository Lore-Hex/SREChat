#!/usr/bin/env python3
"""Three-region partition chaos test — the test that earns the name.

Topology: three FULL SREChat regions as separate OS processes, each
with its own redis-server, all multi-master. Replication links run through
kill-able TCP proxies:

    region 0 (api :4610, redis :6391)
    region 1 (api :4611, redis :6392)
    region 2 (api :4612, redis :6393)
    proxy 7XY0: region X's tailer -> region Y's redis

Phases:
  1. baseline   — a message sent in region 0 appears in all three regions
  2. partition  — region 2 is cut off (its 4 links die). BOTH sides keep
                  accepting sends and serving reads: the majority side
                  (0,1) converges without 2; the minority side (2) works
                  alone. That is the entire point of the design.
  3. heal       — links restored; every region converges to the identical
                  message set, including membership changed mid-partition.

Run: python3 tools/chaos/chaos.py  (needs redis-server + elixir on PATH)
Exit 0 = converged; anything else = a real defect or a dead environment.
"""

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REGIONS = [0, 1, 2]
API = {0: 4610, 1: 4611, 2: 4612}
REDIS = {0: 6391, 1: 6392, 2: 6393}
PREFIX = "chaos"
LOG_DIR = os.path.join(tempfile.gettempdir(), "roach-chaos")

procs = {}
proxies = {}


def log(msg):
    print(f"[chaos] {msg}", flush=True)


def proxy_port(region, peer):
    return 7000 + region * 100 + peer * 10


def start_redis(region):
    return subprocess.Popen(
        ["redis-server", "--port", str(REDIS[region]), "--save", "", "--appendonly", "no"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def start_proxy(region, peer):
    p = subprocess.Popen(
        [sys.executable, os.path.join(ROOT, "tools/chaos/proxy.py"),
         str(proxy_port(region, peer)), str(REDIS[peer])],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    proxies[(region, peer)] = p
    return p


def start_region(region):
    peers = ",".join(
        f"{peer}=redis://localhost:{proxy_port(region, peer)}"
        for peer in REGIONS
        if peer != region
    )

    env = dict(
        os.environ,
        PORT=str(API[region]),
        PUBLIC_HOST="localhost",
        MEDIA_STORAGE="local",
        ACCEPT_UID_TOKENS="true",
        REDIS_URL=f"redis://localhost:{REDIS[region]}",
        REDIS_KEY_PREFIX=PREFIX,
        ID_ALLOCATOR="region",
        REGION_INDEX=str(region),
        REPLICATION_MODE="multi_master",
        PEER_REGIONS=peers,
        WEBSOCKET_HEARTBEAT_MS="25000",
    )

    logfile = open(os.path.join(LOG_DIR, f"chaos-region-{region}.log"), "w")
    return subprocess.Popen(
        ["mix", "run", "--no-halt"],
        cwd=ROOT,
        env=env,
        stdout=logfile,
        stderr=subprocess.STDOUT,
    )


def api(region, method, path, body=None, token="uid:ops-a", admin=False):
    url = f"http://localhost:{API[region]}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if admin:
        req.add_header("apikey", "local-api-key")
    else:
        req.add_header("Authorization", f"Bearer {token}")
    if data:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read().decode() or "{}")


def wait_for(what, fun, timeout=60):
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            if fun():
                return
        except (urllib.error.URLError, OSError, KeyError, json.JSONDecodeError) as e:
            last_error = e
        time.sleep(0.4)
    raise SystemExit(f"[chaos] FAIL: timed out waiting for {what} (last error: {last_error})")


def healthy(region):
    with urllib.request.urlopen(f"http://localhost:{API[region]}/health", timeout=3) as resp:
        return resp.read() == b"ok"


def send(region, text, sender="ops-a", receiver="ops-b"):
    return api(
        region,
        "POST",
        "/v3.0/messages",
        {
            "receiver": receiver,
            "receiverType": "user",
            "category": "message",
            "type": "text",
            "data": {"text": text},
        },
        token=f"uid:{sender}",
    )


def texts(region, me="ops-b", peer="ops-a"):
    payload = api(region, "GET", f"/v3.0/users/{peer}/messages?limit=100", token=f"uid:{me}")
    rows = payload.get("data", [])
    return sorted(
        row.get("data", {}).get("text")
        for row in rows
        if row.get("category") == "message" and not row.get("deletedAt")
    )


def sees(region, text):
    return text in texts(region)


def group_members(region, guid="war-room"):
    payload = api(region, "GET", f"/v3.0/groups/{guid}/members", token="uid:ops-a")
    return sorted(row["uid"] for row in payload.get("data", []))


def cut_region_2():
    for link in [(2, 0), (2, 1), (0, 2), (1, 2)]:
        proxies[link].send_signal(signal.SIGKILL)
        proxies[link].wait()
    log("region 2 partitioned (4 links down)")


def heal_region_2():
    for link in [(2, 0), (2, 1), (0, 2), (1, 2)]:
        start_proxy(*link)
    log("region 2 links restored")


def cleanup():
    for p in list(proxies.values()) + list(procs.values()):
        if p.poll() is None:
            p.send_signal(signal.SIGKILL)


def main():
    if not shutil.which("redis-server"):
        raise SystemExit("[chaos] redis-server not on PATH")

    os.makedirs(LOG_DIR, exist_ok=True)
    log(f"region logs: {LOG_DIR}")

    try:
        for r in REGIONS:
            procs[f"redis-{r}"] = start_redis(r)
        for r in REGIONS:
            for peer in REGIONS:
                if peer != r:
                    start_proxy(r, peer)
        for r in REGIONS:
            procs[f"region-{r}"] = start_region(r)

        for r in REGIONS:
            wait_for(f"region {r} health", lambda r=r: healthy(r), timeout=120)
        log("all three regions healthy")

        # ---- Phase 1: baseline convergence --------------------------------
        send(0, "m1: baseline from region 0")
        for r in REGIONS:
            wait_for(f"m1 in region {r}", lambda r=r: sees(r, "m1: baseline from region 0"))
        log("baseline: message replicated to all three regions")

        api(0, "POST", "/v3/groups", {"guid": "war-room", "type": "public"}, admin=True)
        api(0, "POST", "/v3.0/groups/war-room/members", {}, token="uid:ops-a")
        wait_for("war-room in region 1", lambda: group_members(1) == ["ops-a"])
        wait_for("war-room in region 2", lambda: group_members(2) == ["ops-a"])

        # ---- Phase 2: partition region 2 ----------------------------------
        cut_region_2()

        send(0, "m2: majority side during partition")
        send(2, "m3: minority side during partition")

        wait_for("m2 in region 1", lambda: sees(1, "m2: majority side during partition"))

        assert sees(2, "m3: minority side during partition"), "region 2 must accept writes alone"
        assert not sees(2, "m2: majority side during partition"), "partition leaked m2 into region 2"
        assert not sees(0, "m3: minority side during partition"), "partition leaked m3 into region 0"
        log("partition: BOTH sides kept accepting and serving writes")

        # Membership changes on the majority side while 2 is dark.
        api(1, "POST", "/v3.0/groups/war-room/members", {}, token="uid:ops-b")
        wait_for("ops-b joined on region 0", lambda: group_members(0) == ["ops-a", "ops-b"])
        assert group_members(2) == ["ops-a"], "region 2 should not see mid-partition join yet"

        # ---- Phase 3: heal ------------------------------------------------
        heal_region_2()

        expected = sorted([
            "m1: baseline from region 0",
            "m2: majority side during partition",
            "m3: minority side during partition",
        ])

        for r in REGIONS:
            wait_for(f"full convergence in region {r}", lambda r=r: texts(r) == expected)

        for r in REGIONS:
            wait_for(
                f"membership convergence in region {r}",
                lambda r=r: group_members(r) == ["ops-a", "ops-b"],
            )

        log("heal: all three regions converged to the identical message set")
        log("PASS")
        return 0
    finally:
        cleanup()


if __name__ == "__main__":
    sys.exit(main())
