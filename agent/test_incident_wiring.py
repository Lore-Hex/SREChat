"""The monitor must EMAIL when something breaks and again when it ends.

For sixteen days it did neither: `alert()` reached chat and a phone banner but
never an inbox, container and disk checks ran only on the full-power region, and
the sweep emailed only after a mutating tool call. These tests drive the real
paths — alert(), watch_once(), sweep_cloud_errors() — with only the network and
the model stubbed, and assert on what lands in the outbox.
"""

from __future__ import annotations

import importlib
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

_ENV = ("SRE_REGION_INDEX", "SRE_ALLOW_ACTIONS", "SRE_ACTIONABLE_REGIONS",
        "SRE_FULL_POWER_REGIONS", "SRE_HOST", "SRE_INCIDENT_STATE",
        "SRE_LOCAL_FAILS_TO_ACT")


def _load(tmp_path, **env):
    saved = {k: os.environ.get(k) for k in _ENV}
    for k in _ENV:
        os.environ.pop(k, None)
    os.environ["SRE_INCIDENT_STATE"] = str(tmp_path / "incidents.json")
    os.environ.update(env)
    try:
        for name in ("sre_agent", "incidents"):
            sys.modules.pop(name, None)
        return importlib.import_module("sre_agent")
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


class Wired:
    """An agent with the outside world replaced by lists."""

    def __init__(self, agent, monkeypatch):
        self.agent = agent
        self.emails: list[str] = []
        self.chat: list[str] = []
        self.pushes: list[str] = []
        monkeypatch.setattr(agent.escalate, "email_human",
                            lambda text, *a, **k: self.emails.append(text) or "email sent via test")
        monkeypatch.setattr(agent, "send", lambda who, text: self.chat.append(text))
        monkeypatch.setattr(agent, "push_alert", lambda text: self.pushes.append(text))
        monkeypatch.setattr(agent.escalate, "push_notify_human",
                            lambda text, *a, **k: self.pushes.append(text) or "push sent")

    @property
    def subjects(self) -> list[str]:
        return [e.splitlines()[0] for e in self.emails]


@pytest.fixture
def azure(tmp_path, monkeypatch):
    agent = _load(tmp_path, SRE_REGION_INDEX="2", SRE_ALLOW_ACTIONS="true",
                  SRE_ACTIONABLE_REGIONS="0", SRE_FULL_POWER_REGIONS="2",
                  SRE_HOST="sre2.trustedrouter.com")
    return Wired(agent, monkeypatch)


@pytest.fixture
def aws(tmp_path, monkeypatch):
    agent = _load(tmp_path, SRE_REGION_INDEX="1", SRE_ALLOW_ACTIONS="true",
                  SRE_ACTIONABLE_REGIONS="0", SRE_FULL_POWER_REGIONS="2",
                  SRE_HOST="sre1.trustedrouter.com")
    return Wired(agent, monkeypatch)


class TestAlertEmails:
    def test_a_hard_failure_reaches_the_inbox(self, azure):
        azure.agent.alert("NODE DOWN: region 0 has failed 3 straight health checks",
                          key="region-0")
        assert len(azure.emails) == 1, "alert() reached chat and push but never email"
        assert azure.subjects[0].startswith("🔴")
        assert "NODE DOWN" in azure.subjects[0]
        assert len(azure.chat) == 1 and len(azure.pushes) == 1

    def test_the_same_incident_is_said_once(self, azure):
        for _ in range(5):
            azure.agent.alert("NODE DOWN: region 0", key="region-0")
        assert len(azure.emails) == 1
        assert len(azure.chat) == 5, "chat is a log; only the inbox is rationed"

    def test_recovery_closes_it_with_a_second_email(self, azure):
        azure.agent.alert("NODE DOWN: region 0", key="region-0")
        azure.agent.alert("RECOVERED: region 0 is serving again", key="region-0", recovered=True)
        assert [s[0] for s in azure.subjects] == ["🔴", "✅"]

    def test_recovered_with_nothing_open_is_silent(self, azure):
        azure.agent.alert("RECOVERED: region 0 is serving again", key="region-0", recovered=True)
        assert azure.emails == []

    def test_a_clean_recovery_ends_a_flapping_incident(self, azure):
        azure.agent.alert("FLAPPING: region-0 changed state 3 times", key="flap:region-0")
        azure.agent.alert("RECOVERED: region 0", key="region-0", recovered=True)
        assert len(azure.emails) == 2

    def test_an_email_failure_never_stops_the_page(self, azure, monkeypatch):
        def boom(*_a, **_k):
            raise RuntimeError("provider down")
        monkeypatch.setattr(azure.agent.escalate, "email_human", boom)
        azure.agent.alert("NODE DOWN: region 0", key="region-0")
        assert len(azure.chat) == 1 and len(azure.pushes) == 1

    def test_the_transition_helper_names_the_incident(self, azure):
        a = azure.agent
        a._watch_state["region-0"] = "up"
        a._transition("region-0", False, "RECOVERED: r0", "NODE DOWN: r0")
        a._transition("region-0", True, "RECOVERED: r0", "NODE DOWN: r0")
        assert [s[0] for s in azure.subjects] == ["🔴", "✅"]


def _quiet_fleet(w, monkeypatch, *, containers="deploy-app-1 deploy-redis-1 deploy-caddy-1",
                 disk=20):
    a = w.agent
    monkeypatch.setattr(a, "probe_region", lambda r: True)
    monkeypatch.setattr(a, "tool_local_containers", lambda arg="": containers)
    monkeypatch.setattr(a, "_disk_percent_used", lambda *p: disk)
    monkeypatch.setattr(a, "_run", lambda cmd: "0")
    # Peers are alive, so nothing about THEM is news.
    import time as _t
    for i in range(3):
        a._agent_seen[f"sre-agent-{i}"] = _t.time()


class _Finding:
    def __init__(self, conclusion, tools):
        self.conclusion = conclusion
        self.trigger = "t"
        self.evidence = "$ containers\ndeploy-redis-1 deploy-caddy-1"
        self.tools_used = tools
        self.steps = [type("S", (), {"tool": t, "output": "restarted"})() for t in tools]
        self.exhausted = False


class TestLocalWatch:
    def test_one_missed_look_is_a_deploy_not_an_incident(self, aws, monkeypatch):
        # A deploy bounces the container for seconds. The agent used to "repair"
        # every deploy and email about it.
        _quiet_fleet(aws, monkeypatch, containers="deploy-redis-1 deploy-caddy-1")
        called = []
        monkeypatch.setattr(aws.agent, "investigate_anomaly",
                            lambda *a, **k: called.append(1) or _Finding("CAUSE: x", []))
        aws.agent.watch_once()
        assert called == [] and aws.emails == []

    def test_a_MONITOR_region_now_notices_its_own_dead_container(self, aws, monkeypatch):
        # This check used to sit under `if FULL_POWER:` — regions 0 and 1 never
        # looked at their own containers at all.
        _quiet_fleet(aws, monkeypatch, containers="deploy-redis-1 deploy-caddy-1")
        seen_tools = {}

        def fake(trigger, *, tools=None):
            seen_tools.update(tools or {})
            return _Finding("CAUSE: the app container was stopped\nEVIDENCE: containers\n"
                            "ACTION: NONE\nRESOLVED: no\nIMPACT: outage", ["containers", "logs"])
        monkeypatch.setattr(aws.agent, "investigate_anomaly", fake)
        monkeypatch.setattr(aws.agent, "note_awaiting_ack", lambda *a, **k: None)

        aws.agent.watch_once()
        aws.agent.watch_once()          # the second consecutive look makes it real

        assert len(aws.emails) == 2, f"want opening + outcome, got {aws.subjects}"
        assert aws.subjects[0].startswith("🔴") and "deploy-app-1" in aws.subjects[0]
        assert "MONITOR" in aws.emails[0], "the opening must say this agent cannot repair"
        assert aws.subjects[1].startswith("⚠️") and "NOT fixed" in aws.subjects[1]
        assert not (set(seen_tools) & {"shell", "restart", "tr_rollback"}), \
            "a monitor region was handed a tool that changes things"

    def test_a_full_power_region_repairs_and_reports_both_ends(self, azure, monkeypatch):
        _quiet_fleet(azure, monkeypatch, containers="deploy-redis-1 deploy-caddy-1")
        monkeypatch.setattr(azure.agent, "investigate_anomaly", lambda t, *, tools=None: _Finding(
            "CAUSE: the app container was stopped\nEVIDENCE: containers\n"
            "ACTION: started deploy-app-1\nRESOLVED: yes\nIMPACT: outage", ["containers", "shell"]))
        azure.agent.watch_once()
        azure.agent.watch_once()
        assert [s[0] for s in azure.subjects] == ["🔴", "✅"]
        assert "fixed" in azure.subjects[1]

    def test_the_same_outage_is_not_re_announced_every_cycle(self, azure, monkeypatch):
        _quiet_fleet(azure, monkeypatch, containers="deploy-redis-1 deploy-caddy-1")
        monkeypatch.setattr(azure.agent, "note_awaiting_ack", lambda *a, **k: None)
        monkeypatch.setattr(azure.agent, "investigate_anomaly", lambda t, *, tools=None: _Finding(
            "CAUSE: cannot start\nACTION: NONE\nRESOLVED: no\nIMPACT: outage", ["containers"]))
        for _ in range(8):
            azure.agent.watch_once()
        assert len(azure.emails) == 2, f"an unfixable outage was announced {len(azure.emails)}x"

    def test_a_full_disk_is_an_incident_on_every_region(self, aws, monkeypatch):
        _quiet_fleet(aws, monkeypatch, disk=97)
        monkeypatch.setattr(aws.agent, "note_awaiting_ack", lambda *a, **k: None)
        monkeypatch.setattr(aws.agent, "investigate_anomaly", lambda t, *, tools=None: _Finding(
            "CAUSE: disk full\nACTION: NONE\nRESOLVED: no\nIMPACT: outage", ["system_errors"]))
        aws.agent.watch_once()
        aws.agent.watch_once()
        assert any("disk is 97% full" in e for e in aws.emails)

    def test_a_local_outage_never_gets_product_tools(self, azure):
        tools = azure.agent._local_repair_tools()
        assert not (set(tools) & set(azure.agent._PRODUCT_TOOLS))
        assert "shell" in tools, "the full-power region must keep its real repair tool"


class TestSweepEmails:
    @staticmethod
    def _sweep(w, monkeypatch, conclusion, tools, label_out="ERROR db connection refused"):
        a = w.agent
        a._signal_seen.clear()
        monkeypatch.setattr(a, "_sweep_container_log", lambda which: label_out if which == "app" else "(no output)")
        for t in ("system_errors", "tr_errors", "sentry"):
            if t in a.TOOLS:
                monkeypatch.setitem(a.TOOLS, t, (lambda arg="": "(no output)", "d"))
        monkeypatch.setattr(a, "investigate_anomaly", lambda t, *, tools=None: _Finding(conclusion, tools_list))
        tools_list = tools
        a.sweep_cloud_errors()

    def test_a_live_outage_the_agent_could_not_fix_IS_emailed(self, aws, monkeypatch):
        # The rule that produced sixteen silent days: email only after a
        # mutating tool call. A monitor region can never make one.
        self._sweep(aws, monkeypatch,
                    "CAUSE: redis refusing connections\nACTION: NONE\nRESOLVED: no\nIMPACT: outage",
                    ["logs", "containers"])
        assert len(aws.emails) == 1

    def test_noise_stays_out_of_the_inbox(self, aws, monkeypatch):
        self._sweep(aws, monkeypatch,
                    "CAUSE: internet background scanning\nACTION: NONE\nRESOLVED: yes\nIMPACT: none",
                    ["system_errors"])
        assert aws.emails == [] and len(aws.chat) == 1

    def test_an_unstated_impact_is_not_an_email(self, aws, monkeypatch):
        # Missing is not "outage". Hard failures do not depend on this field.
        self._sweep(aws, monkeypatch, "CAUSE: something\nACTION: NONE\nRESOLVED: no", ["logs"])
        assert aws.emails == []

    def test_a_chronic_finding_emails_once_per_window(self, aws, monkeypatch):
        for i in range(4):
            self._sweep(aws, monkeypatch,
                        "CAUSE: upstream erroring\nACTION: NONE\nRESOLVED: no\nIMPACT: degraded",
                        ["logs"], label_out=f"ERROR upstream 50{i} variant {i}")
        assert len(aws.emails) == 1, "a chronic source nagged instead of reporting once"

    def test_every_repair_is_written_down(self, azure, monkeypatch):
        for i in range(2):
            self._sweep(azure, monkeypatch,
                        "CAUSE: app wedged\nACTION: restarted deploy-app-1\nRESOLVED: yes\nIMPACT: outage",
                        ["shell"], label_out=f"ERROR wedged {i} abc{i}")
            import time as _t
            _t.sleep(1.1)   # the repair key is per-second
        assert len(azure.emails) == 2


class TestSshNoise:
    def test_internet_scanners_are_not_host_errors(self, aws, monkeypatch):
        journal = ("Sep 19 10:00:01 host sshd[4111]: error: kex_exchange_identification: read: Connection reset\n"
                   "Sep 19 10:00:02 host sshd-session[4112]: error: maximum authentication attempts exceeded\n"
                   "Sep 19 10:00:03 host sshd[4113]: pam_unix(sshd:auth): authentication failure")
        monkeypatch.setattr(aws.agent, "_run", lambda cmd: journal if "-p" in cmd else "")
        assert aws.agent.tool_system_errors("30m") == "(no output)"

    def test_a_real_host_error_survives_the_filter(self, aws, monkeypatch):
        journal = ("Sep 19 10:00:01 host sshd[4111]: error: kex_exchange_identification\n"
                   "Sep 19 10:00:05 host systemd[1]: docker.service: Failed with result 'exit-code'.")
        monkeypatch.setattr(aws.agent, "_run", lambda cmd: journal if "-p" in cmd else "")
        out = aws.agent.tool_system_errors("30m")
        assert "docker.service" in out and "sshd" not in out

    def test_an_oom_kill_is_never_filtered(self, aws, monkeypatch):
        monkeypatch.setattr(aws.agent, "_run", lambda cmd: (
            "" if "-p" in cmd else "kernel: Out of memory: Killed process 1913 (beam.smp)"))
        assert "Out of memory" in aws.agent.tool_system_errors("30m")


class TestWhoEmailsAboutAPeer:
    """One outage, one pair of emails — the owner's, unless the owner is gone."""

    @staticmethod
    def _region0_down(w, monkeypatch, *, owner_alive: bool):
        import time as _t
        a = w.agent
        monkeypatch.setattr(a, "probe_region", lambda r: r["index"] != 0)
        monkeypatch.setattr(a, "tool_local_containers",
                            lambda arg="": "deploy-app-1 deploy-redis-1 deploy-caddy-1")
        monkeypatch.setattr(a, "_disk_percent_used", lambda *p: 10)
        monkeypatch.setattr(a, "_run", lambda cmd: "0")
        a._agent_seen["sre-agent-2"] = _t.time()
        if owner_alive:
            a._agent_seen["sre-agent-0"] = _t.time()
        else:
            a._agent_seen["sre-agent-0"] = _t.time() - 10 * a.AGENT_STALE_SECONDS
        a._watch_state["region-0"] = "up"

    def test_a_peer_holds_its_email_while_the_owner_is_alive(self, aws, monkeypatch):
        # Region 1 is region 0's primary reporter. Agent 0 is alive and will send
        # the opening and the diagnosis itself; a second pair from here is noise.
        self._region0_down(aws, monkeypatch, owner_alive=True)
        for _ in range(5):
            aws.agent.watch_once()
        assert any("NODE DOWN" in c for c in aws.chat), "chat and push must still fire"
        assert aws.emails == []

    def test_a_dead_owner_means_the_peer_emails_immediately(self, aws, monkeypatch):
        # A silent agent is what a dead VM looks like. Nobody else can report it.
        self._region0_down(aws, monkeypatch, owner_alive=False)
        for _ in range(5):
            aws.agent.watch_once()
        assert len(aws.emails) == 1 and "NODE DOWN" in aws.subjects[0]

    def test_an_outage_the_owner_cannot_see_is_still_reported(self, aws, monkeypatch):
        # The owner probes from inside; the world connects from outside. If the
        # owner never opens an incident, the peer's deference must run out.
        self._region0_down(aws, monkeypatch, owner_alive=True)
        monkeypatch.setattr(aws.agent, "OWNER_GRACE_SECONDS", 0.0)
        for _ in range(5):
            aws.agent.watch_once()
        assert len(aws.emails) == 1, f"got {aws.subjects}"
        assert "Still down" in aws.emails[0]

    def test_recovery_is_silent_when_the_peer_never_emailed(self, aws, monkeypatch):
        self._region0_down(aws, monkeypatch, owner_alive=True)
        for _ in range(4):
            aws.agent.watch_once()
        monkeypatch.setattr(aws.agent, "probe_region", lambda r: True)
        aws.agent.watch_once()
        assert any("RECOVERED" in c for c in aws.chat)
        assert aws.emails == []

    def test_recovery_closes_what_the_peer_did_email(self, aws, monkeypatch):
        self._region0_down(aws, monkeypatch, owner_alive=False)
        for _ in range(4):
            aws.agent.watch_once()
        monkeypatch.setattr(aws.agent, "probe_region", lambda r: True)
        aws.agent.watch_once()
        assert [s[0] for s in aws.subjects] == ["🔴", "✅"]


class TestLivenessOffTheChatPath:
    """Heartbeats as chat cost 750 MB; as transient chat they delivered nothing."""

    def test_sightings_use_the_SERVERS_clock_for_age(self, azure, monkeypatch):
        import time as _t
        a = azure.agent
        a._agent_seen.clear()
        # The server's clock is an hour off ours. Age is what matters, not epoch.
        skewed_now = _t.time() + 3600
        monkeypatch.setattr(a, "api", lambda m, p, *r, **k: {"data": {
            "now": skewed_now,
            "seen": {"sre-agent-0": skewed_now - 5, "sre-agent-1": skewed_now - 900,
                     "joseph": skewed_now - 1}}})
        a.refresh_agent_liveness()
        assert a._agent_alive(0), "5s old on the server's clock must read as alive"
        assert not a._agent_alive(1), "15 minutes old must read as stale"
        assert "joseph" not in a._agent_seen, "only agents are tracked"

    def test_a_failed_read_changes_nothing(self, azure, monkeypatch):
        import time as _t
        a = azure.agent
        a._agent_seen["sre-agent-0"] = _t.time()
        def boom(*_a, **_k):
            raise OSError("all regions unreachable")
        monkeypatch.setattr(a, "api", boom)
        a.refresh_agent_liveness()
        assert a._agent_alive(0)

    def test_a_stored_legacy_heartbeat_does_not_vouch_for_anyone(self, azure):
        # During a failover read these were stamped "seen now", went stale three
        # minutes later, and raised AGENT DOWN for two agents that were fine.
        import inspect
        src = inspect.getsource(azure.agent.main)
        block = src[src.index("if text.startswith(HEARTBEAT_PREFIX):"):][:700]
        assert "_agent_seen[" not in block.split("continue")[0]

    def test_it_beats_against_every_region_and_one_failure_stops_nothing(self, azure, monkeypatch):
        a = azure.agent
        hit = []
        def beat(host):
            hit.append(host)
            if "sre1" in host:
                raise OSError("region 1 is down")
        monkeypatch.setattr(a, "_beat", beat)
        a.heartbeat()
        assert hit == [r["host"] for r in a.REGIONS]

    def test_never_hearing_from_a_peer_is_eventually_a_finding(self, azure, monkeypatch):
        # "No baseline yet" was an unbounded excuse: with liveness broken, every
        # agent waited forever for a first heartbeat and reported nothing.
        import time as _t
        a = azure.agent
        _quiet_fleet(azure, monkeypatch)
        a._agent_seen.clear()
        monkeypatch.setattr(a, "refresh_agent_liveness", lambda: None)
        monkeypatch.setattr(a, "_STARTED_AT", _t.time() - 2 * a.LIVENESS_GRACE_SECONDS)
        a.watch_once()
        assert any("AGENT DOWN" in c for c in azure.chat), \
            "two silent peers, long past the grace, and nothing was said"

    def test_but_not_during_startup(self, azure, monkeypatch):
        a = azure.agent
        _quiet_fleet(azure, monkeypatch)
        a._agent_seen.clear()
        monkeypatch.setattr(a, "refresh_agent_liveness", lambda: None)
        a.watch_once()
        assert not any("AGENT DOWN" in c for c in azure.chat)


class TestRepairMeansRepair:
    def test_a_region_that_can_repair_is_told_to_restore_service(self, azure, monkeypatch):
        # A live drill diagnosed a stopped container perfectly and then left
        # production down because the stop "was not a failure or crash".
        _quiet_fleet(azure, monkeypatch, containers="deploy-redis-1 deploy-caddy-1")
        prompts = []
        monkeypatch.setattr(azure.agent, "investigate_anomaly", lambda t, *, tools=None: (
            prompts.append(t) or _Finding("CAUSE: x\nACTION: started it\nRESOLVED: yes", ["shell"])))
        azure.agent.watch_once(); azure.agent.watch_once()
        assert "RESTORE SERVICE" in prompts[0]
        assert "even" in prompts[0] and "operator" in prompts[0]

    def test_the_directive_stays_out_of_the_email_subject(self, azure, monkeypatch):
        _quiet_fleet(azure, monkeypatch, containers="deploy-redis-1 deploy-caddy-1")
        monkeypatch.setattr(azure.agent, "investigate_anomaly", lambda t, *, tools=None:
                            _Finding("CAUSE: x\nACTION: started it\nRESOLVED: yes", ["shell"]))
        azure.agent.watch_once(); azure.agent.watch_once()
        assert "RESTORE SERVICE" not in azure.emails[0]

    def test_a_monitor_is_told_to_diagnose_not_to_repair(self, aws, monkeypatch):
        _quiet_fleet(aws, monkeypatch, containers="deploy-redis-1 deploy-caddy-1")
        monkeypatch.setattr(aws.agent, "note_awaiting_ack", lambda *a, **k: None)
        prompts = []
        monkeypatch.setattr(aws.agent, "investigate_anomaly", lambda t, *, tools=None: (
            prompts.append(t) or _Finding("CAUSE: x\nACTION: NONE\nRESOLVED: no", ["logs"])))
        aws.agent.watch_once(); aws.agent.watch_once()
        assert "RESTORE SERVICE" not in prompts[0]
        assert "what a human must do" in prompts[0]


class TestBeatThread:
    """The sweep runs inline for minutes; the beat must not wait for it."""

    def test_it_beats_while_the_loop_makes_progress(self, azure, monkeypatch):
        a = azure.agent
        beats = []
        monkeypatch.setattr(a, "heartbeat", lambda: beats.append(1))
        a._mark_progress()
        assert a.beat_if_alive() is True and beats == [1]

    def test_a_wedged_main_loop_stops_vouching_for_itself(self, azure, monkeypatch):
        # A thread that beats unconditionally reports a hung process as healthy,
        # which is the one state a liveness signal exists to expose.
        import time as _t
        a = azure.agent
        beats = []
        monkeypatch.setattr(a, "heartbeat", lambda: beats.append(1))
        monkeypatch.setattr(a, "_last_progress", _t.time() - 2 * a.PROGRESS_STALE_SECONDS)
        assert a.beat_if_alive() is False and beats == []

    def test_a_log_line_is_progress(self, azure, monkeypatch):
        # A long investigation logs every tool call, so it stays alive; a hung
        # one logs nothing and goes quiet.
        import time as _t
        a = azure.agent
        monkeypatch.setattr(a, "_last_progress", _t.time() - 2 * a.PROGRESS_STALE_SECONDS)
        assert not a._making_progress()
        a.log("investigate: containers() -> 76 chars")
        assert a._making_progress()

    def test_the_beat_is_no_longer_inline_in_the_main_loop(self, azure):
        import inspect
        src = inspect.getsource(azure.agent.main)
        loop = src[src.index("while True:"):]
        assert "heartbeat()" not in loop, "an inline beat waits behind every sweep"
        assert "_beat_forever" in src
