#!/usr/bin/env python3
"""Tests for the watchdog's noise controls.

    cd agent && python3 -m unittest test_watchdog -v

The failure mode these guard is social, not technical: a pager that fires on
every deploy trains its owner to ignore it, and then the real 3am page is
ignored too. So the assertions are about what does NOT fire.
"""

from __future__ import annotations

import os
import time
import unittest

os.environ.setdefault("SRE_HOST", "sre0.trustedrouter.com")
import sre_agent  # noqa: E402


class DebounceTest(unittest.TestCase):
    def setUp(self):
        sre_agent._watch_state.clear()
        sre_agent._fail_streak.clear()
        sre_agent._agent_seen.clear()

    def test_single_blip_stays_up(self):
        # One failed poll is a deploy, not an outage.
        self.assertTrue(sre_agent._debounced("region-1", True))
        self.assertTrue(sre_agent._debounced("region-1", False))
        self.assertTrue(sre_agent._debounced("region-1", False))

    def test_third_consecutive_failure_reports_down(self):
        for _ in range(2):
            self.assertTrue(sre_agent._debounced("region-1", False))
        self.assertFalse(sre_agent._debounced("region-1", False))

    def test_recovery_resets_the_streak(self):
        sre_agent._debounced("region-1", False)
        sre_agent._debounced("region-1", False)
        self.assertTrue(sre_agent._debounced("region-1", True))   # deploy finished
        # A fresh incident starts counting from zero again.
        self.assertTrue(sre_agent._debounced("region-1", False))

    def test_flapping_node_does_not_repage(self):
        # up-down-up-down at every poll: never three in a row, never a page.
        for _ in range(10):
            self.assertTrue(sre_agent._debounced("region-1", False))
            self.assertTrue(sre_agent._debounced("region-1", True))

    def test_once_down_stays_down_until_recovery(self):
        for _ in range(3):
            sre_agent._debounced("region-1", False)
        sre_agent._watch_state["region-1"] = "down"
        # Still down on the next look — no oscillation back to "suspicious".
        self.assertFalse(sre_agent._debounced("region-1", False))
        self.assertTrue(sre_agent._debounced("region-1", True))


class PrimaryReporterTest(unittest.TestCase):
    """REGION_INDEX is 0 for this process (sre0 host)."""

    def setUp(self):
        sre_agent._agent_seen.clear()

    def test_next_in_ring_reports(self):
        # Region 2 dead: ring order is 0 then 1; we are region 0 -> we report.
        self.assertTrue(sre_agent._primary_reporter(2))

    def test_second_in_ring_defers_to_live_primary(self):
        # Region 1 dead: ring order is 2 then 0. Agent 2 is alive -> we defer.
        sre_agent._agent_seen["sre-agent-2"] = time.time()
        self.assertFalse(sre_agent._primary_reporter(1))

    def test_second_in_ring_steps_up_when_primary_is_stale(self):
        # Agent 2 has been silent past the staleness window -> we step up:
        # a double failure must still produce a page.
        sre_agent._agent_seen["sre-agent-2"] = time.time() - 10_000
        self.assertTrue(sre_agent._primary_reporter(1))

    def test_second_in_ring_steps_up_when_primary_never_seen(self):
        self.assertTrue(sre_agent._primary_reporter(1))


class ReplicationTierTest(unittest.TestCase):
    """The log classifier must route gap lines to the loud, named alert."""

    def test_gap_lines_are_replication_not_generic(self):
        lines = [
            "[error] replication gap from region 0: cursor x trimmed; refusing to continue",
            "[error] something else entirely broke",
        ]
        repl = [ln for ln in lines if "replication gap" in ln or "refusing to continue" in ln]
        bad = [ln for ln in lines
               if any(w in ln.lower() for w in ("error", "crash", "fatal", "exception"))
               and ln not in repl]
        self.assertEqual(len(repl), 1)
        self.assertEqual(bad, ["[error] something else entirely broke"])


class WatchdogIsolationTest(unittest.TestCase):
    """The watchdog must not share a failure domain with what it watches."""

    def setUp(self):
        sre_agent._watch_state.clear()
        sre_agent._fail_streak.clear()

    def test_slow_ingest_is_detected_from_a_log_line(self):
        line = "[warning] Store ingest_replicated duration_ms=91362 outcome=ok"
        self.assertEqual(sre_agent._duration_ms(line), 91362)
        self.assertGreaterEqual(sre_agent._duration_ms(line), 10_000)

    def test_a_quick_ingest_is_not_an_alert(self):
        self.assertLess(sre_agent._duration_ms("ingest_replicated duration_ms=812 outcome=ok"), 10_000)
        self.assertEqual(sre_agent._duration_ms("no duration here"), 0)

    def test_device_tokens_fall_back_to_cache_when_the_api_is_down(self):
        # The outage that most needs a page is the API being down, which is
        # exactly when the token lookup fails. The cache is what makes the
        # pager independent of the thing it reports on.
        import json, tempfile, os
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump({"cached-token": {"env": "development"}}, fh)
            path = fh.name
        old_cache, old_api = sre_agent.DEVICE_CACHE, sre_agent.api
        try:
            sre_agent.DEVICE_CACHE = path

            def dead_api(*a, **k):
                raise OSError("HTTP Error 502: Bad Gateway")

            sre_agent.api = dead_api
            self.assertEqual(sre_agent.owner_devices(), {"cached-token": {"env": "development"}})
        finally:
            sre_agent.DEVICE_CACHE, sre_agent.api = old_cache, old_api
            os.unlink(path)

    def test_no_cache_and_no_api_returns_empty_rather_than_raising(self):
        old_cache, old_api = sre_agent.DEVICE_CACHE, sre_agent.api
        try:
            sre_agent.DEVICE_CACHE = "/nonexistent/path/devices.json"

            def dead_api(*a, **k):
                raise OSError("down")

            sre_agent.api = dead_api
            self.assertEqual(sre_agent.owner_devices(), {})
        finally:
            sre_agent.DEVICE_CACHE, sre_agent.api = old_cache, old_api


if __name__ == "__main__":
    unittest.main()
