"""The ladder: a note when it starts, a report when it ends, a call if ignored.

An unanswered page is an unhandled incident. The agent cannot tell "seen, being
handled" from "asleep" except by asking louder, so silence has to escalate on a
clock rather than being assumed to mean everything is fine.
"""

from __future__ import annotations

import importlib
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


@pytest.fixture
def agent():
    os.environ["SRE_HOST"] = "sre2.trustedrouter.com"
    sys.modules.pop("sre_agent", None)
    module = importlib.import_module("sre_agent")
    module._awaiting_ack.clear()
    yield module
    sys.modules.pop("sre_agent", None)


@pytest.fixture
def calls(agent, monkeypatch):
    placed: list[str] = []
    monkeypatch.setattr(
        agent.escalate, "call_human",
        lambda reason: (placed.append(reason), "call sent")[1],
    )
    return placed


class TestOpeningNote:
    def test_it_says_what_triggered_it_and_that_work_is_starting(self, agent) -> None:
        # An agent quietly acting on production with no trace until it finishes
        # is the thing that makes an autonomous agent hard to trust.
        note = agent.opening_email("redis container not running")

        assert "investigating" in note.splitlines()[0]
        assert "redis container not running" in note
        assert agent.AGENT_UID in note

    def test_it_links_to_the_chat_so_a_reply_is_one_click_away(self, agent) -> None:
        # The reply is what stops the phone ringing, so the way to reply has to
        # be in the message that starts the clock.
        assert "/app/" in agent.opening_email("anything")

    def test_it_promises_the_report_that_follows(self, agent) -> None:
        assert "report" in agent.opening_email("anything").lower()


class TestUnacknowledgedEscalation:
    def test_silence_becomes_a_phone_call(self, agent, calls) -> None:
        agent.note_awaiting_ack("region-2", "Region 2: redis down, not resolved.")
        agent._awaiting_ack["region-2"]["at"] -= agent.ACK_TIMEOUT_SECONDS + 1

        agent.escalate_unacknowledged()

        assert calls, "nobody was called for an unanswered incident"
        assert "redis down" in calls[0]
        assert "No reply in chat" in calls[0]

    def test_it_waits_before_ringing(self, agent, calls) -> None:
        # Calling instantly would make the chat message pointless.
        agent.note_awaiting_ack("region-2", "something")

        agent.escalate_unacknowledged()

        assert calls == []

    def test_a_reply_from_the_owner_stops_the_call(self, agent, calls) -> None:
        agent.note_awaiting_ack("region-2", "something")
        agent._awaiting_ack["region-2"]["at"] -= agent.ACK_TIMEOUT_SECONDS + 1

        agent.acknowledge_all(agent.OWNER_UID)
        agent.escalate_unacknowledged()

        assert calls == []

    def test_any_message_counts_as_an_answer(self, agent, calls) -> None:
        # Requiring a keyword would ring the phone of someone already typing.
        agent.note_awaiting_ack("region-2", "something")
        agent.acknowledge_all(agent.OWNER_UID)

        assert agent._awaiting_ack == {}

    def test_a_stranger_talking_does_not_acknowledge(self, agent, calls) -> None:
        agent.note_awaiting_ack("region-2", "something")

        agent.acknowledge_all("sre-agent-1")

        assert "region-2" in agent._awaiting_ack

    def test_it_calls_once_and_stops(self, agent, calls) -> None:
        # The leash dedupes, but the agent should not be relying on it to avoid
        # calling every 30 seconds for the length of an outage.
        agent.note_awaiting_ack("region-2", "something")
        agent._awaiting_ack["region-2"]["at"] -= agent.ACK_TIMEOUT_SECONDS + 1

        agent.escalate_unacknowledged()
        agent.escalate_unacknowledged()

        assert len(calls) == 1

    def test_a_failing_carrier_does_not_kill_the_watch(self, agent, monkeypatch) -> None:
        def boom(_reason):
            raise RuntimeError("both carriers down")

        monkeypatch.setattr(agent.escalate, "call_human", boom)
        agent.note_awaiting_ack("region-2", "something")
        agent._awaiting_ack["region-2"]["at"] -= agent.ACK_TIMEOUT_SECONDS + 1

        agent.escalate_unacknowledged()  # must not raise
