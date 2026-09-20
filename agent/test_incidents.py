"""One incident, two emails.

The email policy failed in both directions — 29 emails in two hours, then zero
for sixteen days — because it decided per message instead of per incident. These
tests pin the ledger: what gets said once, what is never said, and that none of
it depends on the agent remembering anything across a restart.
"""

from __future__ import annotations

import importlib

import pytest


@pytest.fixture
def ledger(tmp_path, monkeypatch):
    monkeypatch.setenv("SRE_INCIDENT_STATE", str(tmp_path / "incidents.json"))
    monkeypatch.setenv("SRE_INCIDENT_MAX_EMAILS_PER_HOUR", "6")
    import incidents
    return importlib.reload(incidents)


class Outbox:
    def __init__(self, result="email sent via test"):
        self.sent: list[str] = []
        self.result = result

    def __call__(self, text: str) -> str:
        self.sent.append(text)
        return self.result


class TestOpening:
    def test_an_incident_is_announced_once(self, ledger):
        out = Outbox()
        assert ledger.opened("region-2", "down", out, now=1000).startswith("email sent")
        assert ledger.opened("region-2", "down", out, now=1060).startswith("suppressed")
        assert ledger.opened("region-2", "down", out, now=5000).startswith("suppressed")
        assert len(out.sent) == 1

    def test_a_different_incident_is_not_suppressed(self, ledger):
        out = Outbox()
        ledger.opened("region-2", "down", out, now=1000)
        ledger.opened("disk:1", "disk full", out, now=1001)
        assert len(out.sent) == 2

    def test_a_long_open_incident_reminds_daily_not_hourly(self, ledger):
        out = Outbox()
        ledger.opened("region-2", "down", out, now=0)
        ledger.opened("region-2", "still down", out, now=3600)
        assert len(out.sent) == 1
        ledger.opened("region-2", "still down", out, now=ledger.REMIND_SECONDS + 1)
        assert len(out.sent) == 2

    def test_it_survives_a_restart(self, ledger):
        # A crash-looping agent re-enters with fresh memory; the ledger is what
        # stops each restart announcing the same outage again.
        out = Outbox()
        ledger.opened("region-2", "down", out, now=1000)
        fresh = importlib.reload(ledger)
        assert fresh.opened("region-2", "down", out, now=1100).startswith("suppressed")
        assert len(out.sent) == 1

    def test_a_failed_send_does_not_consume_the_incident(self, ledger):
        # Otherwise a provider blip at the wrong second turns a real outage into
        # permanent silence.
        broken = Outbox(result="email FAILED: provider down")
        assert "FAILED" in ledger.opened("region-2", "down", broken, now=1000)
        working = Outbox()
        assert ledger.opened("region-2", "down", working, now=1030).startswith("email sent")
        assert len(working.sent) == 1

    def test_a_raising_sender_never_propagates(self, ledger):
        def boom(_text):
            raise RuntimeError("socket closed")
        assert "FAILED" in ledger.opened("region-2", "down", boom, now=1000)


class TestOutcome:
    def test_resolved_closes_and_is_emailed(self, ledger):
        out = Outbox()
        ledger.opened("self:2", "working on it", out, now=1000)
        assert ledger.outcome("self:2", "fixed", out, resolved=True, now=1200).startswith("email sent")
        assert len(out.sent) == 2
        assert not ledger.is_open("self:2")

    def test_recovered_is_silent_if_nobody_was_told_it_broke(self, ledger):
        # "RECOVERED" about something never reported is noise — exactly what a
        # storm-suppressed opening would otherwise produce.
        quiet = Outbox(result="email suppressed (rate limited)")
        ledger.opened("region-1", "down", quiet, now=1000)
        out = Outbox()
        assert ledger.outcome("region-1", "recovered", out, resolved=True, now=1100).startswith("suppressed")
        assert out.sent == []

    def test_an_outcome_with_no_incident_is_silent(self, ledger):
        out = Outbox()
        assert ledger.outcome("never-opened", "recovered", out, resolved=True, now=1).startswith("suppressed")
        assert out.sent == []

    def test_unresolved_is_said_once_and_stays_open(self, ledger):
        # An agent that re-investigates the same unfixable outage every few
        # minutes says "I could not fix this" one time, not every time.
        out = Outbox()
        ledger.opened("self:1", "working", out, now=0)
        ledger.outcome("self:1", "could not fix", out, resolved=False, now=100)
        ledger.outcome("self:1", "could not fix", out, resolved=False, now=700)
        ledger.outcome("self:1", "could not fix", out, resolved=False, now=1300)
        assert len(out.sent) == 2
        assert ledger.is_open("self:1")

    def test_unresolved_then_resolved_tells_the_whole_story(self, ledger):
        out = Outbox()
        ledger.opened("self:1", "working", out, now=0)
        ledger.outcome("self:1", "could not fix", out, resolved=False, now=100)
        ledger.outcome("self:1", "fixed after all", out, resolved=True, now=900)
        assert [t for t in out.sent] == ["working", "could not fix", "fixed after all"]

    def test_the_same_key_can_break_again_later(self, ledger):
        out = Outbox()
        ledger.opened("region-2", "down", out, now=0)
        ledger.outcome("region-2", "recovered", out, resolved=True, now=300)
        assert ledger.opened("region-2", "down again", out, now=4000).startswith("email sent")
        assert len(out.sent) == 3


class TestReport:
    def test_a_one_shot_finding_emails_once_per_window(self, ledger):
        out = Outbox()
        ledger.report("sweep:app", "found+fixed", out, remind_seconds=3600, now=0)
        ledger.report("sweep:app", "found again", out, remind_seconds=3600, now=600)
        assert len(out.sent) == 1
        ledger.report("sweep:app", "found later", out, remind_seconds=3600, now=3700)
        assert len(out.sent) == 2


class TestCeiling:
    def test_no_bug_upstream_can_send_more_than_the_ceiling(self, ledger):
        # Whatever decides something is an incident, the inbox is bounded.
        out = Outbox()
        for i in range(40):
            ledger.opened(f"incident-{i}", f"thing {i} broke", out, now=1000 + i)
        assert len(out.sent) == ledger.MAX_PER_HOUR

    def test_the_ceiling_is_per_hour_not_forever(self, ledger):
        out = Outbox()
        for i in range(10):
            ledger.opened(f"a-{i}", "x", out, now=0 + i)
        assert len(out.sent) == ledger.MAX_PER_HOUR
        ledger.opened("later", "y", out, now=3700)
        assert len(out.sent) == ledger.MAX_PER_HOUR + 1

    def test_a_ceiling_suppressed_opening_is_retried_not_lost(self, ledger):
        out = Outbox()
        for i in range(ledger.MAX_PER_HOUR):
            ledger.opened(f"a-{i}", "x", out, now=i)
        assert ledger.opened("real-outage", "down", out, now=100).startswith("suppressed")
        # Still open, never emailed — so the next report of it, once the hour
        # has rolled, goes out rather than being treated as already told.
        assert ledger.opened("real-outage", "down", out, now=3700).startswith("email sent")


class TestPrune:
    def test_old_resolved_incidents_are_forgotten_open_ones_are_not(self, ledger):
        out = Outbox()
        ledger.opened("old", "x", out, now=0)
        ledger.outcome("old", "fixed", out, resolved=True, now=10)
        ledger.opened("still-open", "y", out, now=20)
        assert ledger.prune(max_age_seconds=1000, now=5000) == 1
        assert ledger.is_open("still-open")
