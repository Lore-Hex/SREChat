"""Flapping is one incident, not a stream of good news.

Region 0 crash-looped 12 times in 40 minutes and sent six RECOVERED alerts and
zero NODE DOWN. Each restart was too brief to trip the failure debounce, while
recovery had none at all — so the only thing reported about an outage in
progress was, repeatedly, that it was over.
"""

from __future__ import annotations

import importlib
import os
import sys

import pytest


@pytest.fixture
def agent():
    os.environ["SRE_HOST"] = "sre0.trustedrouter.com"
    sys.modules.pop("sre_agent", None)
    module = importlib.import_module("sre_agent")
    module._watch_state.clear()
    module._flaps.clear()
    yield module
    sys.modules.pop("sre_agent", None)


@pytest.fixture
def sent(agent, monkeypatch):
    messages: list[str] = []
    monkeypatch.setattr(agent, "alert", messages.append)
    return messages


def _cycle(agent, key="region-0", times=1):
    for _ in range(times):
        agent._transition(key, False, "up again", "gone down")
        agent._transition(key, True, "up again", "gone down")


class TestNormalTransitions:
    def test_the_first_observation_is_not_news(self, agent, sent) -> None:
        agent._transition("region-0", True, "up again", "gone down")
        assert sent == []

    def test_a_single_outage_reports_down_then_up(self, agent, sent) -> None:
        agent._transition("region-0", True, "up again", "gone down")  # baseline
        agent._transition("region-0", False, "up again", "gone down")
        agent._transition("region-0", True, "up again", "gone down")

        assert sent == ["gone down", "up again"]

    def test_a_steady_state_says_nothing(self, agent, sent) -> None:
        for _ in range(5):
            agent._transition("region-0", True, "up again", "gone down")
        assert sent == []


class TestFlapping:
    def test_repeated_cycling_reports_flapping_instead(self, agent, sent) -> None:
        agent._transition("region-0", True, "up again", "gone down")  # baseline
        _cycle(agent, times=3)

        flaps = [m for m in sent if m.startswith("FLAPPING")]
        assert flaps, f"no flapping report in {sent}"
        assert "changed state" in flaps[0]

    def test_it_stops_repeating_the_individual_transitions(self, agent, sent) -> None:
        # The actual complaint: six RECOVERED messages for one crash loop.
        agent._transition("region-0", True, "up again", "gone down")
        _cycle(agent, times=6)

        assert sent.count("up again") <= 1, sent
        assert sent.count("gone down") <= 1, sent

    def test_the_flap_report_says_which_state_it_is_in_now(self, agent, sent) -> None:
        # "Flapping" without the current state leaves the reader unable to tell
        # whether anything is serving right now.
        agent._transition("region-0", True, "up again", "gone down")
        _cycle(agent, times=3)
        agent._transition("region-0", False, "up again", "gone down")

        flaps = [m for m in sent if m.startswith("FLAPPING")]
        assert any("currently down" in m for m in flaps), flaps

    def test_it_points_at_restarts_rather_than_waiting_for_a_clean_failure(
        self, agent, sent
    ) -> None:
        # A crash loop never fails cleanly, so "wait for it to go down" is the
        # wrong instinct and the message says so.
        agent._transition("region-0", True, "up again", "gone down")
        _cycle(agent, times=3)

        flaps = [m for m in sent if m.startswith("FLAPPING")]
        assert "restart" in flaps[0].lower()

    def test_flapping_is_tracked_per_key(self, agent, sent) -> None:
        # One region cycling must not make another region's single outage look
        # like a flap.
        agent._transition("region-0", True, "up again", "gone down")
        agent._transition("region-1", True, "up again", "gone down")
        _cycle(agent, key="region-0", times=3)

        agent._transition("region-1", False, "up again", "gone down")

        assert "gone down" in sent

    def test_a_region_that_settles_reports_normally_again(self, agent, sent) -> None:
        # The window is rolling, so a region that flapped an hour ago and fails
        # once today gets a plain NODE DOWN rather than a flap report.
        agent._transition("region-0", True, "up again", "gone down")
        _cycle(agent, times=3)
        agent._flaps["region-0"] = []          # window expired
        sent.clear()

        agent._transition("region-0", False, "up again", "gone down")

        assert sent == ["gone down"]
