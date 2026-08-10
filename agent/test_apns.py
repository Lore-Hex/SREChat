#!/usr/bin/env python3
"""Tests for the APNs sender.

    cd agent && python3 -m unittest test_apns -v

Stdlib only, matching the agent itself. The point of these is that every
failure mode of a push is invisible from the agent's side — Apple answers with
a status code and the phone simply stays quiet — so the request has to be
asserted here rather than confirmed by watching a phone.
"""

from __future__ import annotations

import base64
import importlib
import json
import os
import subprocess
import tempfile
import types
import unittest


def load_apns(**env):
    """(Re)import apns with a controlled environment; it reads config at import."""
    for key in ("APNS_KEY_PATH", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_BUNDLE_ID", "APNS_ENV"):
        os.environ.pop(key, None)
    os.environ.update(env)
    import apns as module

    module = importlib.reload(module)
    module._cached = None
    return module


class SigningTest(unittest.TestCase):
    """ES256 is where a wrong byte costs you a 403 that reads like a bad key."""

    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.TemporaryDirectory()
        cls.key = os.path.join(cls.dir.name, "AuthKey_TEST123456.p8")
        cls.pub = os.path.join(cls.dir.name, "test.pub")
        subprocess.run(
            ["openssl", "genpkey", "-algorithm", "EC",
             "-pkeyopt", "ec_paramgen_curve:P-256", "-out", cls.key],
            check=True, capture_output=True)
        subprocess.run(["openssl", "pkey", "-in", cls.key, "-pubout", "-out", cls.pub],
                       check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.dir.cleanup()

    def setUp(self):
        self.apns = load_apns(
            APNS_KEY_PATH=self.key, APNS_KEY_ID="ABCDE12345", APNS_TEAM_ID="HXN23BFRR2")

    @staticmethod
    def _unpad(segment: str) -> bytes:
        return base64.urlsafe_b64decode(segment + "=" * (-len(segment) % 4))

    def test_jwt_header_and_claims(self):
        header, claims, _ = self.apns.provider_token().split(".")
        self.assertEqual(json.loads(self._unpad(header)),
                         {"alg": "ES256", "kid": "ABCDE12345"})
        self.assertEqual(json.loads(self._unpad(claims))["iss"], "HXN23BFRR2")

    def test_signature_is_raw_64_bytes_and_verifies(self):
        header, claims, sig = self.apns.provider_token().split(".")
        raw = self._unpad(sig)
        # JWS ES256 is raw r||s, never DER. A DER signature here is ~70 bytes
        # and Apple rejects it as InvalidProviderToken.
        self.assertEqual(len(raw), 64)

        def der_int(b: bytes) -> bytes:
            b = b.lstrip(b"\x00") or b"\x00"
            if b[0] & 0x80:
                b = b"\x00" + b
            return bytes([0x02, len(b)]) + b

        body = der_int(raw[:32]) + der_int(raw[32:])
        with tempfile.TemporaryDirectory() as tmp:
            der_path = os.path.join(tmp, "sig.der")
            msg_path = os.path.join(tmp, "input.bin")
            with open(der_path, "wb") as fh:
                fh.write(bytes([0x30, len(body)]) + body)
            with open(msg_path, "wb") as fh:
                fh.write(f"{header}.{claims}".encode())
            proc = subprocess.run(
                ["openssl", "dgst", "-sha256", "-verify", self.pub,
                 "-signature", der_path, msg_path],
                capture_output=True)
        self.assertIn(b"Verified OK", proc.stdout)

    def test_token_is_reused_then_reminted(self):
        # Apple rejects a token older than an hour, and also rejects minting
        # more often than every 20 minutes — so both halves matter.
        first = self.apns.provider_token()
        self.assertEqual(self.apns.provider_token(), first)
        self.assertNotEqual(self.apns.provider_token(self.apns.time.time() + 41 * 60), first)

    def test_der_parser_pads_short_integers(self):
        # A leading zero byte in r or s is dropped by DER; without left-padding
        # the halves land misaligned and every push fails 403.
        short = bytes([0x30, 0x08, 0x02, 0x01, 0x05, 0x02, 0x03, 0x01, 0x02, 0x03])
        raw = self.apns._der_to_raw(short)
        self.assertEqual(len(raw), 64)
        self.assertEqual(raw[:32], b"\x00" * 31 + b"\x05")
        self.assertEqual(raw[32:], b"\x00" * 29 + b"\x01\x02\x03")

    def test_malformed_der_raises(self):
        with self.assertRaises(ValueError):
            self.apns._der_to_raw(b"\x99\x02\x01\x01")


class SendTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.TemporaryDirectory()
        cls.key = os.path.join(cls.dir.name, "AuthKey_TEST123456.p8")
        subprocess.run(
            ["openssl", "genpkey", "-algorithm", "EC",
             "-pkeyopt", "ec_paramgen_curve:P-256", "-out", cls.key],
            check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.dir.cleanup()

    def setUp(self):
        self.apns = load_apns(
            APNS_KEY_PATH=self.key, APNS_KEY_ID="ABCDE12345", APNS_TEAM_ID="HXN23BFRR2")
        self.calls = []

    def fake_curl(self, stdout=b"\n200", returncode=0, stderr=b""):
        """Swap the module's whole `subprocess` reference, not its `.run`.

        `apns.subprocess` is the real, shared subprocess module — assigning to
        `apns.subprocess.run` patches it process-wide and breaks the openssl
        calls in every other test. Rebinding the name on the apns module keeps
        the stub local to it.
        """
        def run(args, **kwargs):
            self.calls.append(args)
            if args and args[0] == "openssl":          # let real signing through
                return subprocess.run(args, **kwargs)
            return subprocess.CompletedProcess(args, returncode, stdout, stderr)

        self.apns.subprocess = types.SimpleNamespace(
            run=run,
            TimeoutExpired=subprocess.TimeoutExpired,
            CompletedProcess=subprocess.CompletedProcess,
        )
        return run

    def test_request_shape(self):
        self.fake_curl()
        status, _ = self.apns.push("DEADBEEF", "SREChat", "node down", collapse_id="abc")
        self.assertEqual(status, 200)

        argv = self.calls[-1]
        joined = " ".join(argv)
        self.assertEqual(argv[0], "curl")
        self.assertIn("--http2", argv)             # APNs is HTTP/2 only
        self.assertIn("apns-topic: co.lorehex.srechat", joined)
        self.assertIn("apns-push-type: alert", joined)
        self.assertIn("apns-priority: 10", joined)
        self.assertIn("apns-collapse-id: abc", joined)
        self.assertTrue(argv[-1].endswith("/3/device/DEADBEEF"))

        payload = json.loads(argv[argv.index("-d") + 1])["aps"]
        self.assertEqual(payload["alert"], {"title": "SREChat", "body": "node down"})
        # Without this a page is suppressed by Focus, which defeats the point.
        self.assertEqual(payload["interruption-level"], "time-sensitive")

    def test_environment_selects_apple_host(self):
        self.fake_curl()
        self.apns.push("T", "t", "b", env="development")
        self.assertIn("api.sandbox.push.apple.com", self.calls[-1][-1])
        self.apns.push("T", "t", "b", env="production")
        self.assertIn("api.push.apple.com", self.calls[-1][-1])
        # An unset per-device env must fall back, not crash.
        self.apns.push("T", "t", "b", env=None)
        self.assertIn("api.sandbox.push.apple.com", self.calls[-1][-1])

    def test_no_collapse_header_when_not_asked(self):
        self.fake_curl()
        self.apns.push("T", "t", "b")
        self.assertNotIn("apns-collapse-id", " ".join(self.calls[-1]))

    def test_410_is_surfaced_so_the_caller_can_unregister(self):
        body = '{"reason":"Unregistered"}'
        self.fake_curl(stdout=(body + "\n410").encode())
        status, text = self.apns.push("T", "t", "b")
        self.assertEqual(status, 410)
        self.assertEqual(text, body)

    def test_curl_failure_is_not_mistaken_for_success(self):
        self.fake_curl(stdout=b"", returncode=6, stderr=b"could not resolve host")
        status, text = self.apns.push("T", "t", "b")
        self.assertEqual(status, 0)
        self.assertIn("could not resolve", text)

    def test_timeout_is_not_mistaken_for_success(self):
        self.fake_curl()                       # sign for real, then time out on curl
        real_run = self.apns.subprocess.run

        def boom(args, **kwargs):
            if args and args[0] == "openssl":
                return real_run(args, **kwargs)
            raise subprocess.TimeoutExpired(args, 25)
        self.apns.subprocess.run = boom
        self.assertEqual(self.apns.push("T", "t", "b")[0], 0)

    def test_unconfigured_is_a_silent_no_op(self):
        # A deployment with no APNs key must keep running, and must not shell
        # out to curl at all.
        unconfigured = load_apns()
        self.fake_curl()
        unconfigured.subprocess = self.apns.subprocess
        self.assertFalse(unconfigured.enabled())
        self.assertEqual(unconfigured.push("T", "t", "b"), (0, "apns not configured"))
        self.assertEqual(self.calls, [])

    def test_missing_key_file_is_not_enabled(self):
        self.assertFalse(load_apns(
            APNS_KEY_PATH="/nonexistent/AuthKey.p8",
            APNS_KEY_ID="ABCDE12345", APNS_TEAM_ID="HXN23BFRR2").enabled())


if __name__ == "__main__":
    unittest.main()
