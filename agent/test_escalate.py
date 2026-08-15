#!/usr/bin/env python3
"""Tests for human escalation.

    cd agent && python3 -m unittest test_escalate -v

The point of these is the LEASH. These are the only tools an agent has that can
wake someone at 3am, and every failure mode is silent from the agent's side: a
carrier returns a status code and a sleeping human either is or is not woken.
So the limits, the dedupe, and the carrier fallback are asserted here rather
than discovered at 3am.
"""

from __future__ import annotations

import importlib
import json
import os
import tempfile
import unittest


def load_escalate(**env):
    for key in ("HUMAN_PHONE", "TELNYX_API_KEY", "TELNYX_FROM", "TWILIO_ACCOUNT_SID",
                "TWILIO_AUTH_TOKEN", "TWILIO_FROM", "ESCALATE_STATE", "TELNYX_ACCOUNT_ID"):
        os.environ.pop(key, None)
    os.environ.update(env)
    import escalate as module
    return importlib.reload(module)


class LeashTest(unittest.TestCase):
    def setUp(self):
        self.state = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        self.state.close()
        os.unlink(self.state.name)
        self.esc = load_escalate(
            ESCALATE_STATE=self.state.name,
            HUMAN_PHONE="+15550000000",
            TWILIO_ACCOUNT_SID="AC_test", TWILIO_AUTH_TOKEN="tok", TWILIO_FROM="+15551111111",
        )
        self.sent = []
        self.esc._post = lambda url, data, headers, timeout=20: (
            self.sent.append((url, data)) or (201, '{"sid":"SM_fake"}'))
        self.esc._post_json = lambda url, payload, headers, timeout=20: (
            self.sent.append((url, payload)) or (200, '{"data":{}}'))

    def tearDown(self):
        try:
            os.unlink(self.state.name)
        except OSError:
            pass

    def test_a_call_goes_through_once(self):
        out = self.esc.call_human("region 0 is down and I cannot restart it")
        self.assertIn("call sent", out)
        self.assertEqual(len(self.sent), 1)
        self.assertIn("/Calls.json", self.sent[0][0])

    def test_the_same_reason_does_not_page_twice(self):
        # Flapping is the normal failure mode and is what turns a pager into
        # noise the reader learns to ignore.
        reason = "region 0 is down"
        self.assertIn("sent", self.esc.sms_human(reason))
        second = self.esc.sms_human(reason)
        self.assertIn("suppressed", second)
        self.assertIn("duplicate", second)
        self.assertEqual(len(self.sent), 1)

    def test_calls_are_hard_capped_per_hour(self):
        # Two distinct urgent reasons are allowed; the third is not, no matter
        # how distressed the agent is.
        self.esc.LIMITS["call"] = (2, 3600, 0)
        self.assertIn("sent", self.esc.call_human("first distinct emergency"))
        self.assertIn("sent", self.esc.call_human("second distinct emergency"))
        third = self.esc.call_human("third distinct emergency")
        self.assertIn("suppressed", third)
        self.assertIn("rate limited", third)
        self.assertEqual(len(self.sent), 2)

    def test_minimum_gap_between_calls(self):
        self.esc.LIMITS["call"] = (10, 3600, 900)
        self.assertIn("sent", self.esc.call_human("alpha incident"))
        blocked = self.esc.call_human("beta incident")
        self.assertIn("too soon", blocked)

    def test_the_limit_survives_a_restart(self):
        # An agent in a crash loop restarts with fresh memory. Without on-disk
        # state it would phone a sleeping human once per restart, forever.
        self.esc.LIMITS["call"] = (1, 3600, 0)
        self.assertIn("sent", self.esc.call_human("the one call"))

        restarted = load_escalate(
            ESCALATE_STATE=self.state.name,
            HUMAN_PHONE="+15550000000",
            TWILIO_ACCOUNT_SID="AC_test", TWILIO_AUTH_TOKEN="tok", TWILIO_FROM="+15551111111",
        )
        restarted.LIMITS["call"] = (1, 3600, 0)
        restarted._post = lambda *a, **k: (201, "{}")
        self.assertIn("suppressed", restarted.call_human("another call after restart"))

    def test_a_reasonless_page_is_refused(self):
        self.assertIn("refused", self.esc.call_human("   "))
        self.assertEqual(self.sent, [])

    def test_suppression_is_not_reported_as_failure(self):
        # The agent should keep working on the incident, so being told "already
        # paged" must read as information, not an error it might retry around.
        reason = "same thing"
        self.esc.sms_human(reason)
        out = self.esc.sms_human(reason)
        self.assertNotIn("FAILED", out)


class CarrierFailoverTest(unittest.TestCase):
    """A pager with one vendor is one vendor outage away from silence."""

    def setUp(self):
        self.state = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        self.state.close()
        os.unlink(self.state.name)
        self.esc = load_escalate(
            ESCALATE_STATE=self.state.name,
            HUMAN_PHONE="+15550000000",
            TELNYX_API_KEY="tel_key", TELNYX_FROM="+15552222222",
            TWILIO_ACCOUNT_SID="AC_test", TWILIO_AUTH_TOKEN="tok", TWILIO_FROM="+15551111111",
        )

    def tearDown(self):
        try:
            os.unlink(self.state.name)
        except OSError:
            pass

    def test_sms_prefers_telnyx_and_says_so(self):
        self.esc.telnyx_sms = lambda text: (200, "ok")
        self.esc.twilio_sms = lambda text: self.fail("twilio should not be reached")
        self.assertIn("delivered via telnyx", self.esc.sms_human("primary works"))

    def test_sms_falls_over_to_twilio_when_telnyx_fails(self):
        self.esc.telnyx_sms = lambda text: (500, "telnyx exploded")
        self.esc.twilio_sms = lambda text: (201, "ok")
        out = self.esc.sms_human("primary is down")
        self.assertIn("delivered via twilio", out)
        # And the failure of the primary is visible, not swallowed.
        self.assertIn("telnyx=500", out)

    def test_both_carriers_down_is_reported_as_a_failure(self):
        self.esc.telnyx_sms = lambda text: (500, "down")
        self.esc.twilio_sms = lambda text: (0, "ConnectionError")
        out = self.esc.sms_human("nothing works")
        self.assertIn("FAILED", out)
        self.assertIn("telnyx=500", out)
        self.assertIn("twilio=0", out)

    def test_a_failed_send_does_not_consume_the_budget(self):
        # Otherwise a carrier outage would burn the call budget and the human
        # would never be reached even once the carrier recovered.
        self.esc.telnyx_sms = lambda text: (500, "down")
        self.esc.twilio_sms = lambda text: (500, "down")
        self.esc.sms_human("attempt one")
        ok, _why = self.esc.allowed("sms", "attempt two")
        self.assertTrue(ok)

    def test_voice_prefers_twilio(self):
        # Twilio's inline TwiML needs nothing of ours running, which is the
        # situation a voice call exists for.
        order = []
        self.esc.twilio_call = lambda text: (order.append("twilio"), (201, "ok"))[1]
        self.esc.telnyx_call = lambda text: (order.append("telnyx"), (200, "ok"))[1]
        self.esc.call_human("urgent")
        self.assertEqual(order, ["twilio"])

    def test_unconfigured_carrier_is_skipped_not_failed(self):
        bare = load_escalate(ESCALATE_STATE=self.state.name, HUMAN_PHONE="+15550000000")
        out = bare.sms_human("no carriers at all")
        self.assertIn("FAILED", out)
        self.assertIn("unconfigured", out)


class SpokenTest(unittest.TestCase):
    def setUp(self):
        self.esc = load_escalate()

    def test_the_message_is_repeated(self):
        # A ringing phone is answered mid-sentence; the first pass is half heard.
        spoken = self.esc._spoken("disk full on region two")
        self.assertEqual(spoken.count("disk full on region two"), 2)

    def test_xml_metacharacters_cannot_break_the_twiml(self):
        spoken = self.esc._spoken("a < b & c > d")
        for bad in ("<", ">", "&"):
            self.assertNotIn(bad, spoken)


if __name__ == "__main__":
    unittest.main()


# ---------------------------------------------------------------- branding

def test_sms_and_calls_open_with_the_brand(monkeypatch):
    """An unrecognized number reading an unattributed sentence gets hung up on."""
    import escalate

    sent = []
    monkeypatch.setattr(escalate, "telnyx_available", lambda: True)
    monkeypatch.setattr(escalate, "twilio_available", lambda: False)
    monkeypatch.setattr(escalate, "telnyx_sms", lambda text: (sent.append(text), (200, "ok"))[1])
    monkeypatch.setattr(escalate, "telnyx_call", lambda text: (sent.append(text), (200, "ok"))[1])

    escalate._try_carriers("sms", "disk full")
    escalate._try_carriers("voice", "disk full")

    assert sent, "nothing was sent"
    for text in sent:
        assert text.startswith("Trusted Router: "), text
    # _try_carriers is below the leash, so this one needs no isolated state —
    # but anything calling sms_human/call_human does.


def test_branding_is_not_applied_twice():
    import escalate

    assert escalate.branded("Trusted Router: disk full").lower().count("trusted router") == 1


def test_the_brand_is_spoken_as_a_sentence_not_a_colon():
    """"Trusted Router colon disk full" is what a naive prefix would say."""
    import escalate

    spoken = escalate._spoken(escalate.branded("disk full"))

    assert spoken.startswith("Trusted Router notification.")
    assert ":" not in spoken
    assert spoken.count("disk full") == 2


def test_sms_human_does_not_stack_a_second_prefix(monkeypatch, tmp_path):
    """It used to prefix "SREChat: " itself, which now reads as
    "Trusted Router: SREChat: ..." once branding moved to the choke point.

    Runs against an isolated leash state. Using the real one made this pass on a
    clean machine and fail on the second run, because the dedupe correctly
    suppressed a reason the previous run had already sent — a test that depends
    on machine state reports on the machine, not the code.
    """
    escalate = load_escalate(ESCALATE_STATE=str(tmp_path / "leash.json"))

    sent = []
    monkeypatch.setattr(escalate, "telnyx_available", lambda: True)
    monkeypatch.setattr(escalate, "twilio_available", lambda: False)
    monkeypatch.setattr(escalate, "telnyx_sms", lambda text: (sent.append(text), (200, "ok"))[1])

    escalate.sms_human("disk full")

    assert sent, "nothing was sent"
    assert sent[0].startswith("Trusted Router: ")
    assert "SREChat:" not in sent[0]
