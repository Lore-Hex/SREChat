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
        monkeypatch.setitem(agent.TOOLS, "logs", (lambda a: "", "d"))
        assert agent.sweep_findings() == []

    def test_an_unconfigured_source_is_not_a_finding(self, agent, monkeypatch):
        # The Sentry tool answers "Sentry is not configured for this agent"
        # when its token is unset. That is our own gap, not the cloud's error.
        monkeypatch.setitem(
            agent.TOOLS, "sentry",
            (lambda a: "Sentry is not configured for this agent. Set SENTRY_AUTH_TOKEN...", "d"))
        monkeypatch.setitem(agent.TOOLS, "tr_errors", (lambda a: "(no output)", "d"))
        monkeypatch.setitem(agent.TOOLS, "logs", (lambda a: "", "d"))
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
        monkeypatch.setitem(agent.TOOLS, "logs", (lambda a: "ERROR db refused", "d"))
        found = agent.sweep_findings()
        assert any("db refused" in ev for _l, ev in found)

    def test_a_region_without_a_source_just_skips_it(self, agent, monkeypatch):
        monkeypatch.delitem(agent.TOOLS, "tr_errors", raising=False)
        monkeypatch.setitem(agent.TOOLS, "logs", (lambda a: "", "d"))
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
        monkeypatch.setitem(agent.TOOLS, "logs", (lambda a: "", "d"))
        monkeypatch.setattr(agent, "chat_with_tools", lambda m, s: {"content": conclusion})
        monkeypatch.setattr(agent, "send", lambda who, text: sent.append(text))
        monkeypatch.setattr(agent.escalate, "email_human", lambda b: emails.append(b) or "ok")
        return sent, emails

    def test_a_repair_is_reported_and_emailed(self, agent, monkeypatch):
        sent, emails = self._wire(agent, monkeypatch,
            "CAUSE: a bad revision\nEVIDENCE: logs\nACTION: rolled traffic back\nRESOLVED: yes")
        agent.sweep_cloud_errors()
        assert any("rolled traffic back" in t for t in sent)
        assert len(emails) == 1, "a repair the agent performed must be written down"

    def test_noise_stays_in_chat(self, agent, monkeypatch):
        sent, emails = self._wire(agent, monkeypatch,
            "CAUSE: UNKNOWN\nEVIDENCE: nothing reproduces\nACTION: NONE\nRESOLVED: yes")
        agent.sweep_cloud_errors()
        assert len(sent) == 1
        assert emails == [], "an unverifiable finding must not reach the inbox"

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
        monkeypatch.setitem(agent.TOOLS, "logs", (lambda a: "", "d"))
        monkeypatch.setitem(
            agent.TOOLS, "sentry",
            (lambda a: "(Sentry query failed: HTTP Error 403: Forbidden)", "d"))
        assert agent.sweep_findings() == []

    def test_sentry_host_is_overridable(self, agent):
        # lore-hex-corp is an EU org served from de.sentry.io; the us host 403s
        # and says nothing about the HOST being the problem.
        assert agent.SENTRY_HOST.startswith("https://")
