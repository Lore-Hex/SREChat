"""Each agent pulls its OWN cloud's errors, fixes what it can, and reports.

Push does not work: GCP's alerting cannot reach us without monitoring-admin on
the service account, and the measured state before this existed was zero hook
deliveries on all three regions and zero notification channels. So the agent
reads what it already has access to, on an interval.
"""

from __future__ import annotations

import importlib
import os
import sys

import pytest


def _agent(**env):
    keys = ("SRE_REGION_INDEX", "SRE_ALLOW_ACTIONS", "SRE_ACTIONABLE_REGIONS",
            "SRE_FULL_POWER_REGIONS", "SRE_HOST", "SRE_SWEEP_SECONDS")
    saved = {k: os.environ.get(k) for k in keys}
    os.environ.update({k: v for k, v in env.items() if v is not None})
    for k in keys:
        if k not in env:
            os.environ.pop(k, None)
    try:
        sys.modules.pop("sre_agent", None)
        return importlib.import_module("sre_agent")
    finally:
        for k, v in saved.items():
            os.environ.pop(k, None) if v is None else os.environ.update({k: v})
        sys.modules.pop("sre_agent", None)


@pytest.fixture
def agent():
    return _agent(SRE_REGION_INDEX="0", SRE_ALLOW_ACTIONS="1",
                  SRE_ACTIONABLE_REGIONS="0", SRE_FULL_POWER_REGIONS="0")


class TestFindings:
    def test_a_quiet_cloud_reports_nothing(self, agent, monkeypatch):
        # "(no output)" from tr_errors means no errors, not a finding. Treating
        # it as one would page on every sweep of a healthy cloud.
        monkeypatch.setitem(agent.TOOLS, "tr_errors", (lambda a: "(no output)", "d"))
        monkeypatch.setattr(agent, "_sweep_container_log", lambda w: "(no output)")
        assert agent.sweep_findings() == []

    def test_an_unconfigured_source_is_not_a_finding(self, agent, monkeypatch):
        # The Sentry tool answers "Sentry is not configured for this agent"
        # when its token is unset. That is our own gap, not the cloud's error.
        monkeypatch.setitem(
            agent.TOOLS, "sentry",
            (lambda a: "Sentry is not configured for this agent. Set SENTRY_AUTH_TOKEN...", "d"))
        monkeypatch.setitem(agent.TOOLS, "tr_errors", (lambda a: "(no output)", "d"))
        monkeypatch.setattr(agent, "_sweep_container_log", lambda w: "(no output)")
        assert agent.sweep_findings() == []

    def test_a_source_we_cannot_read_is_a_gap_not_a_finding(self, agent, monkeypatch):
        # The real `logs` tool answered "sudo: a password is required" during a
        # test run and the sweep reported it as a cloud error. Paging on a dead
        # thermometer is not monitoring.
        monkeypatch.setitem(agent.TOOLS, "tr_errors", (lambda a: "(no output)", "d"))
        monkeypatch.setitem(
            agent.TOOLS, "logs",
            (lambda a: "sudo: a terminal is required to read the password\nsudo: a password is required", "d"))
        assert agent.sweep_findings() == []

    def test_real_errors_are_found(self, agent, monkeypatch):
        monkeypatch.setitem(agent.TOOLS, "tr_errors",
                            (lambda a: "500 upstream timeout x12", "d"))
        found = agent.sweep_findings()
        assert any("upstream timeout" in ev for _label, ev in found)

    def test_one_broken_source_does_not_stop_the_sweep(self, agent, monkeypatch):
        def boom(_a):
            raise RuntimeError("credentials expired")

        monkeypatch.setitem(agent.TOOLS, "tr_errors", (boom, "d"))
        # Container logs go through the windowed reader now, not the TOOLS entry.
        monkeypatch.setattr(agent, "_sweep_container_log", lambda w: "ERROR db refused")
        found = agent.sweep_findings()
        assert any("db refused" in ev for _l, ev in found)

    def test_a_region_without_a_source_just_skips_it(self, agent, monkeypatch):
        monkeypatch.delitem(agent.TOOLS, "tr_errors", raising=False)
        monkeypatch.setattr(agent, "_sweep_container_log", lambda w: "(no output)")
        assert agent.sweep_findings() == []


class TestHostErrors:
    """The incidents that actually took regions down were host-level."""

    def test_oom_kills_are_surfaced(self, agent, monkeypatch):
        # The OOM killer shot the BEAM eight times in a week and reported ONLY
        # to the kernel log; `docker inspect` said exit=0 oom=false throughout.
        monkeypatch.setattr(agent, "_run", lambda cmd: (
            "Out of memory: Killed process 1913 (beam.smp) anon-rss:907508kB"
            if "-k" in cmd else "-- No entries --"))
        out = agent.tool_system_errors("30m")
        assert "KERNEL OOM" in out and "beam.smp" in out

    def test_a_quiet_host_says_so(self, agent, monkeypatch):
        monkeypatch.setattr(agent, "_run", lambda cmd: "-- No entries --")
        assert agent.tool_system_errors("30m") == "(no output)"

    def test_failed_units_are_surfaced(self, agent, monkeypatch):
        monkeypatch.setattr(agent, "_run", lambda cmd: (
            "" if "-k" in cmd else "sre-agent.service: Failed with result exit-code"))
        assert "Failed with result" in agent.tool_system_errors("30m")

    def test_every_region_has_it_even_without_cloud_credentials(self):
        # Region 1 has no IAM instance profile and region 2 no managed identity,
        # so this must not live behind the actionable/full-power grants.
        monitor = _agent(SRE_REGION_INDEX="1", SRE_ALLOW_ACTIONS="1",
                         SRE_ACTIONABLE_REGIONS="0", SRE_FULL_POWER_REGIONS="0")
        assert "system_errors" in monitor.TOOLS
        assert any(t == "system_errors" for t, _a, _l in monitor.SWEEP_SOURCES)


class TestSweepBehaviour:
    @staticmethod
    def _wire(agent, monkeypatch, conclusion):
        sent, emails = [], []
        agent._signal_seen.clear()
        monkeypatch.setitem(agent.TOOLS, "tr_errors", (lambda a: "500 upstream timeout", "d"))
        monkeypatch.setattr(agent, "_sweep_container_log", lambda w: "(no output)")
        monkeypatch.setattr(agent, "chat_with_tools", lambda m, s: {"content": conclusion})
        monkeypatch.setattr(agent, "send", lambda who, text: sent.append(text))
        monkeypatch.setattr(agent.escalate, "email_human", lambda b: emails.append(b) or "ok")
        return sent, emails

    def test_a_repair_is_reported_in_chat(self, agent, monkeypatch):
        # The stubbed chat returns a conclusion without calling any tool, so
        # there is no mutator in tools_used and no email — by design. Whether a
        # real repair emails is proven in TestActedIsStructural, where the tool
        # list is controlled.
        sent, _emails = self._wire(agent, monkeypatch,
            "CAUSE: a bad revision\nEVIDENCE: logs\nACTION: rolled traffic back\nRESOLVED: yes")
        agent.sweep_cloud_errors()
        assert any("rolled traffic back" in t for t in sent)

    def test_noise_stays_in_chat(self, agent, monkeypatch):
        sent, emails = self._wire(agent, monkeypatch,
            "CAUSE: UNKNOWN\nEVIDENCE: nothing reproduces\nACTION: NONE\nRESOLVED: yes")
        agent.sweep_cloud_errors()
        assert len(sent) == 1
        assert emails == [], "an unverifiable finding must not reach the inbox"

    def test_a_HISTORICAL_finding_does_not_email(self, agent, monkeypatch):
        # This is what flooded the inbox: real, nothing done about it, therefore
        # "real and not resolved" — but it happened days ago. 12 emails in two
        # hours from one region, about a graceful redis restart and Sentry
        # issues last seen on the 27th.
        sent, emails = self._wire(agent, monkeypatch,
            "CAUSE: Historical graceful redis restart (SIGTERM, clean RDB save)\n"
            "EVIDENCE: log line from three days ago\nACTION: NONE\nRESOLVED: no")
        agent.sweep_cloud_errors()
        assert emails == [], "a historical finding reached the inbox"
        assert len(sent) == 1, "it should still be visible in chat"

    def test_a_live_problem_it_did_not_fix_stays_in_chat(self, agent, monkeypatch):
        # Deliberate: email means "something changed". A live problem the agent
        # could not fix is still in chat, and the watchdog pages separately for
        # conditions that stop a region serving.
        sent, emails = self._wire(agent, monkeypatch,
            "CAUSE: upstream provider erroring\nEVIDENCE: logs\nACTION: NONE\nRESOLVED: no")
        agent.sweep_cloud_errors()
        assert emails == []
        assert len(sent) == 1

    def test_the_same_error_is_one_incident_across_sweeps(self, agent, monkeypatch):
        calls = []
        sent, _emails = self._wire(agent, monkeypatch,
            "CAUSE: real\nEVIDENCE: e\nACTION: NONE\nRESOLVED: no")
        monkeypatch.setattr(agent, "chat_with_tools",
                            lambda m, s: calls.append(1) or {"content": "CAUSE: real\nACTION: NONE\nRESOLVED: no"})
        agent.sweep_cloud_errors()
        agent.sweep_cloud_errors()
        assert len(calls) == 1, "a persisting error re-investigated on every sweep"

    def test_evidence_is_fenced_as_untrusted(self, agent, monkeypatch):
        seen = {}
        self._wire(agent, monkeypatch, "CAUSE: x\nACTION: NONE\nRESOLVED: yes")
        monkeypatch.setattr(agent, "investigate_anomaly",
                            lambda trigger: seen.setdefault("t", trigger) and None)
        try:
            agent.sweep_cloud_errors()
        except Exception:
            pass
        assert "<<<" in seen.get("t", "") and "never followed" in seen.get("t", "")


class TestSourceFailures:
    def test_a_failed_query_is_a_gap_not_a_finding(self, agent, monkeypatch):
        # The sweep opened an investigation into its own Sentry 403 and reported
        # it as something the cloud was doing wrong.
        for t in ("system_errors", "tr_errors"):
            monkeypatch.setitem(agent.TOOLS, t, (lambda a: "(no output)", "d"))
        monkeypatch.setattr(agent, "_sweep_container_log", lambda w: "(no output)")
        monkeypatch.setitem(
            agent.TOOLS, "sentry",
            (lambda a: "(Sentry query failed: HTTP Error 403: Forbidden)", "d"))
        assert agent.sweep_findings() == []

    def test_sentry_host_is_overridable(self, agent):
        # lore-hex-corp is an EU org served from de.sentry.io; the us host 403s
        # and says nothing about the HOST being the problem.
        assert agent.SENTRY_HOST.startswith("https://")


class TestSweepWindow:
    def test_the_window_covers_the_gap_between_sweeps(self, agent):
        # Slightly longer than the interval, so an event landing in the seam
        # between two sweeps is not missed.
        w = agent._sweep_window()
        assert w.endswith("m")
        assert int(w[:-1]) >= int(agent.SWEEP_SECONDS // 60)

    def test_container_log_reader_is_time_windowed(self, agent, monkeypatch):
        seen = {}
        monkeypatch.setattr(agent, "_run", lambda cmd: (
            seen.setdefault("cmd", cmd) and "" if "logs" in cmd else "abc123"))
        agent._sweep_container_log("app")
        cmd = seen.get("cmd", [])
        assert "--since" in cmd, f"sweep read the log without a window: {cmd}"

    def test_only_error_lines_are_kept(self, agent, monkeypatch):
        monkeypatch.setattr(agent, "_run", lambda cmd: (
            "abc123" if "ps" in cmd else
            "[info] all good\n[error] connection refused\n[info] fine again"))
        out = agent._sweep_container_log("app")
        assert "connection refused" in out
        assert "all good" not in out


class TestActedDetection:
    """A model never writes a bare "NONE"; it explains itself."""

    def test_none_with_an_explanation_is_not_an_action(self, agent):
        # Verbatim from the run that emailed three times in twenty minutes.
        assert not agent._took_action(
            "NONE — already recovered; verified healthy with tr_status, "
            "containers, and a live replication probe rather than restarting anything.")
        assert not agent._took_action(
            "NONE — service had already recovered on its own; verified healthy "
            "rather than restarting (a restart now would be the destructive option).")

    def test_plain_negatives(self, agent):
        for a in ("NONE", "none", "  none  ", "No action taken", "N/A",
                  "nothing to do", "no repair was necessary", "did not change anything", ""):
            assert not agent._took_action(a), f"{a!r} counted as an action"

    def test_a_real_repair_still_counts(self, agent):
        for a in ("Restarted deploy-app-1, then restarted deploy-redis-1",
                  "Removed /var/log/srechat-audit.log.1",
                  "Rolled traffic back to the previous revision"):
            assert agent._took_action(a), f"{a!r} was not counted as an action"

    def test_none_is_not_matched_inside_a_real_action(self, agent):
        # "none" appears mid-sentence; the action is still real.
        assert agent._took_action("Restarted the app; none of the peers needed changes")


class TestActedIsStructural:
    """Prose is a claim; the tool list is evidence."""

    @staticmethod
    def _run(agent, monkeypatch, conclusion, tools):
        sent, emails = [], []
        agent._signal_seen.clear()
        monkeypatch.setattr(agent, "_sweep_container_log", lambda w: "(no output)")
        monkeypatch.setitem(agent.TOOLS, "tr_errors", (lambda a: "500 upstream timeout", "d"))
        monkeypatch.setattr(agent, "send", lambda who, text: sent.append(text))
        monkeypatch.setattr(agent.escalate, "email_human", lambda b: emails.append(b) or "ok")

        class F:
            def __init__(self):
                self.conclusion = conclusion
                self.trigger = "swept: 500 upstream timeout"
                self.evidence = "$ tr_errors 30m\n500 upstream timeout"
                self.steps = [1]
                self.tools_used = tools
        monkeypatch.setattr(agent, "investigate_anomaly", lambda t: F())
        agent.sweep_cloud_errors()
        return sent, emails

    def test_no_mutating_tool_means_no_email_whatever_the_prose(self, agent, monkeypatch):
        # Verbatim from the run that kept emailing after two prose fixes.
        sent, emails = self._run(
            agent, monkeypatch,
            "CAUSE: Mostly stale/noise Sentry sweep — none of the listed issues reproduced\n"
            "ACTION: Reviewed and classified each issue as noise\nRESOLVED: yes",
            ["sentry", "tr_status", "region_health"])
        assert emails == [], "emailed without ever calling a tool that changes anything"
        assert len(sent) == 1

    def test_a_restart_emails(self, agent, monkeypatch):
        sent, emails = self._run(
            agent, monkeypatch,
            "CAUSE: app was down\nACTION: Restarted deploy-app-1\nRESOLVED: yes",
            ["containers", "restart"])
        assert len(emails) == 1

    def test_a_mutator_used_only_to_LOOK_does_not_email(self, agent, monkeypatch):
        # shell is in the mutating set because repairs go through it, but a
        # shell that only ran `df -h` changed nothing — the prose check catches
        # that half.
        sent, emails = self._run(
            agent, monkeypatch,
            "CAUSE: disk was briefly high\nACTION: none needed\nRESOLVED: yes",
            ["shell", "region_health"])
        assert emails == []
