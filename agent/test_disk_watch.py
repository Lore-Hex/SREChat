"""Disk space, which nothing was watching.

A chaos drill filled the disk and every signal the watchdog had stayed green:
containers keep running and /health keeps answering 200 right up until a write
fails. The region was minutes from being unable to accept a message and looked
perfectly well — the third blind spot of exactly this shape, after redis and
the crash loop.
"""

from __future__ import annotations

import importlib
import os
import sys
from types import SimpleNamespace

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


@pytest.fixture
def agent():
    os.environ["SRE_HOST"] = "sre2.trustedrouter.com"
    sys.modules.pop("sre_agent", None)
    module = importlib.import_module("sre_agent")
    yield module
    sys.modules.pop("sre_agent", None)


class TestDiskReading:
    def test_it_reports_a_plausible_percentage(self, agent) -> None:
        used = agent._disk_percent_used("/")
        assert 0 <= used <= 100

    def test_a_full_disk_reads_as_full(self, agent, monkeypatch) -> None:
        monkeypatch.setattr(
            agent.os, "statvfs",
            lambda _p: SimpleNamespace(f_blocks=1000, f_bavail=0, f_bfree=0),
        )
        assert agent._disk_percent_used("/") == 100

    def test_an_empty_disk_reads_as_empty(self, agent, monkeypatch) -> None:
        monkeypatch.setattr(
            agent.os, "statvfs",
            lambda _p: SimpleNamespace(f_blocks=1000, f_bavail=1000, f_bfree=1000),
        )
        assert agent._disk_percent_used("/") == 0

    def test_it_counts_reserved_blocks_as_used(self, agent, monkeypatch) -> None:
        # f_bfree includes root-reserved blocks that we cannot spend. Counting
        # them as free reports headroom nobody has, which is the difference
        # between "fine" and "out of space" on a filesystem with a 5% reserve.
        monkeypatch.setattr(
            agent.os, "statvfs",
            lambda _p: SimpleNamespace(f_blocks=100, f_bavail=0, f_bfree=5),
        )

        assert agent._disk_percent_used("/") == 100

    def test_a_zero_sized_filesystem_does_not_divide_by_zero(self, agent, monkeypatch) -> None:
        monkeypatch.setattr(
            agent.os, "statvfs",
            lambda _p: SimpleNamespace(f_blocks=0, f_bavail=0, f_bfree=0),
        )
        assert agent._disk_percent_used("/") == 0


class TestThreshold:
    def test_the_default_leaves_room_to_act(self, agent) -> None:
        # High enough not to cry wolf, low enough that a human still has time
        # to do something before writes start failing.
        assert 70 <= agent.DISK_ALERT_PERCENT <= 90

    def test_it_is_configurable(self) -> None:
        os.environ["SRE_DISK_ALERT_PERCENT"] = "60"
        os.environ["SRE_HOST"] = "sre2.trustedrouter.com"
        sys.modules.pop("sre_agent", None)
        try:
            module = importlib.import_module("sre_agent")
            assert module.DISK_ALERT_PERCENT == 60
        finally:
            os.environ.pop("SRE_DISK_ALERT_PERCENT", None)
            sys.modules.pop("sre_agent", None)
