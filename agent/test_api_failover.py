"""The agent must not go blind because its own region is down.

Region 0's agent talked only to region 0. When region 0's app crash-looped, it
could not fetch conversations, lost sight of the heartbeats arriving from AWS
and Azure, and reported two healthy regions as silent. Three masters exist so
that any one of them can serve; the agent was the one component not using that.
"""

from __future__ import annotations

import importlib
import os
import sys
import urllib.error

import pytest


@pytest.fixture
def agent():
    os.environ["SRE_HOST"] = "sre0.trustedrouter.com"
    sys.modules.pop("sre_agent", None)
    module = importlib.import_module("sre_agent")
    yield module
    sys.modules.pop("sre_agent", None)


class _Response:
    def __init__(self, payload: bytes = b'{"ok":true}') -> None:
        self._payload = payload

    def read(self) -> bytes:
        return self._payload

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False


def _urlopen_where(healthy: set[str], seen: list[str]):
    def urlopen(req, timeout=None):
        host = req.full_url.split("/")[2]
        seen.append(host)
        if host in healthy:
            return _Response()
        raise urllib.error.URLError("connection refused")

    return urlopen


class TestHostOrder:
    def test_its_own_region_is_tried_first(self, agent) -> None:
        # Failover is for outages; normal operation must not spray requests
        # across the fleet or spend a peer's capacity for nothing.
        assert agent.api_hosts()[0] == agent.REGION_HOST

    def test_every_peer_is_a_candidate(self, agent) -> None:
        hosts = agent.api_hosts()
        assert len(hosts) == len(agent.REGIONS)
        assert len(set(hosts)) == len(hosts), "a host is listed twice"


class TestFailover:
    def test_it_reaches_a_peer_when_its_own_region_is_down(
        self, agent, monkeypatch
    ) -> None:
        seen: list[str] = []
        monkeypatch.setattr(
            agent.urllib.request, "urlopen",
            _urlopen_where({"sre1.trustedrouter.com"}, seen),
        )

        result = agent.api("GET", "/conversations")

        assert result == {"ok": True}
        assert seen[0] == "sre0.trustedrouter.com", "own region should be tried first"
        assert "sre1.trustedrouter.com" in seen

    def test_a_healthy_region_never_touches_a_peer(self, agent, monkeypatch) -> None:
        seen: list[str] = []
        monkeypatch.setattr(
            agent.urllib.request, "urlopen",
            _urlopen_where({"sre0.trustedrouter.com"}, seen),
        )

        agent.api("GET", "/conversations")

        assert seen == ["sre0.trustedrouter.com"]

    def test_it_raises_only_when_every_master_is_gone(self, agent, monkeypatch) -> None:
        # Total failure must still surface. Silently returning empty would make
        # a dead fleet look like a quiet one — the failure this whole change is
        # about, reintroduced one level down.
        seen: list[str] = []
        monkeypatch.setattr(agent.urllib.request, "urlopen", _urlopen_where(set(), seen))

        with pytest.raises(Exception):
            agent.api("GET", "/conversations")

        assert len(seen) == len(agent.REGIONS), "it gave up before trying every master"

    def test_writes_fail_over_too(self, agent, monkeypatch) -> None:
        # A page written to a peer replicates back, so an agent whose own
        # region is down can still say what it found.
        seen: list[str] = []
        monkeypatch.setattr(
            agent.urllib.request, "urlopen",
            _urlopen_where({"sre2.trustedrouter.com"}, seen),
        )

        agent.api("POST", "/messages", {"receiver": "joseph", "type": "text"})

        assert "sre2.trustedrouter.com" in seen
