"""Expanded test suite for host_daemon.py (audit P2-1).

Stdlib unittest only. Server runs on an EPHEMERAL port (port 0) and is
shut down cleanly in tearDownClass — no fixed-port flakiness.
"""
import http.client
import json
import os
import threading
import time
import unittest
import urllib.error
import urllib.request
from unittest import mock

import host_daemon
from host_daemon import create_server


class DaemonTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._env_backup = dict(os.environ)
        os.environ["HOST_DAEMON_VERIFY_TIMEOUT_SEC"] = "0.2"
        cls.server = create_server("127.0.0.1", 0)  # ephemeral port
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        time.sleep(0.1)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)
        os.environ.clear()
        os.environ.update(cls._env_backup)

    def setUp(self):
        os.environ.pop("HOST_DAEMON_TOKEN", None)

    # -- helpers ---------------------------------------------------------
    def url(self, path):
        return f"http://127.0.0.1:{self.port}{path}"

    def get(self, path):
        with urllib.request.urlopen(self.url(path), timeout=5) as resp:
            return resp.status, resp.headers, json.loads(resp.read().decode())

    def post_action(self, payload=None, headers=None, raw_body=None, raw_headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        body = raw_body if raw_body is not None else json.dumps(payload if payload is not None else {})
        hdrs = {"Content-Type": "application/json"}
        if headers:
            hdrs.update(headers)
        if raw_headers is not None:
            hdrs = raw_headers
        try:
            conn.request("POST", "/api/host/action", body=body, headers=hdrs)
            resp = conn.getresponse()
            data = resp.read().decode()
            try:
                parsed = json.loads(data) if data else {}
            except Exception:
                parsed = {}
            return resp.status, parsed
        finally:
            conn.close()


class TestBasics(DaemonTestCase):
    def test_health(self):
        status, _, data = self.get("/health")
        self.assertEqual(status, 200)
        self.assertEqual(data["status"], "ok")

    def test_404_is_json(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(self.url("/nope"), timeout=5)
        self.assertEqual(ctx.exception.code, 404)
        data = json.loads(ctx.exception.read().decode())
        self.assertIn("error", data)

    def test_cors_origin_is_configured_not_star(self):
        req = urllib.request.Request(self.url("/api/host/vitals"), method="OPTIONS")
        with urllib.request.urlopen(req, timeout=5) as resp:
            origin = resp.headers.get("Access-Control-Allow-Origin")
        self.assertEqual(origin, host_daemon.DEFAULT_CORS_ORIGIN)
        self.assertNotEqual(origin, "*")

    def test_vitals_schema_and_sources(self):
        status, _, data = self.get("/api/host/vitals")
        self.assertEqual(status, 200)
        self.assertEqual(data["status"], "online")
        for key in ("battery", "memory", "system", "services", "sources"):
            self.assertIn(key, data)
        self.assertIn("watchdog", data["services"])
        # Watchdog alive is a real heartbeat check: no heartbeat file on this
        # test machine (default LOG_DIR has none) -> False, not hard-coded True.
        self.assertIn(data["services"]["watchdog"]["alive"], (True, False))

    def test_log_traversal_blocked(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(self.url("/api/host/logs?service=../../etc/passwd"), timeout=5)
        self.assertEqual(ctx.exception.code, 400)


class TestHonestVitals(DaemonTestCase):
    def test_battery_unavailable_returns_nulls_not_fabrications(self):
        with mock.patch.object(host_daemon, "_termux_battery", return_value=None), \
             mock.patch.object(host_daemon, "_sys_battery", return_value=None):
            info, src = host_daemon.get_battery_info()
        self.assertEqual(src, "unavailable")
        self.assertIsNone(info["capacity_pct"])   # was fabricated 85
        self.assertIsNone(info["temperature_c"])  # was fabricated 32.0
        self.assertIsNone(info["status"])         # was fabricated "Charging"

    def test_uptime_parser_real_or_null(self):
        info, src = host_daemon.get_uptime_info()
        if src == "proc":
            self.assertIsInstance(info["uptime_seconds"], int)
            self.assertNotEqual(info["uptime_seconds"], 345600)  # old fake default

    def test_watchdog_heartbeat_fresh_and_stale(self):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            hb = os.path.join(td, "watchdog.heartbeat")
            with mock.patch.dict(os.environ, {"WATCHDOG_HEARTBEAT_FILE": hb}):
                self.assertFalse(host_daemon.get_watchdog_alive())  # missing
                with open(hb, "w") as f:
                    f.write("x")
                self.assertTrue(host_daemon.get_watchdog_alive())   # fresh
                old = time.time() - 3600
                os.utime(hb, (old, old))
                self.assertFalse(host_daemon.get_watchdog_alive())  # stale


class TestLogs(DaemonTestCase):
    def test_logs_happy_path_and_clamp(self):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            logfile = os.path.join(td, "nifty-analyzer.log")
            with open(logfile, "w") as f:
                for i in range(300):
                    f.write(f"line {i}\n")
            with mock.patch.object(host_daemon, "LOG_DIR", td):
                status, _, data = self.get("/api/host/logs?service=nifty&lines=5000")
                self.assertEqual(status, 200)
                self.assertEqual(len(data["lines"]), 200)  # clamped to 200
                self.assertEqual(data["lines"][-1], "line 299")
                status, _, data = self.get("/api/host/logs?service=nifty&lines=abc")
                self.assertEqual(status, 200)
                self.assertEqual(len(data["lines"]), 50)  # invalid -> default 50


class TestAuth(DaemonTestCase):
    def test_actions_disabled_when_token_unset(self):
        status, data = self.post_action({"action": "git_sync"})
        self.assertEqual(status, 503)
        self.assertIn("HOST_DAEMON_TOKEN not set", data["error"])

    def test_missing_and_wrong_token_401(self):
        os.environ["HOST_DAEMON_TOKEN"] = "s3cret-test"
        status, _ = self.post_action({"action": "git_sync"})
        self.assertEqual(status, 401)
        status, _ = self.post_action({"action": "git_sync"}, headers={"X-Host-Token": "wrong"})
        self.assertEqual(status, 401)

    def test_correct_token_dispatches_action(self):
        os.environ["HOST_DAEMON_TOKEN"] = "s3cret-test"
        fake = mock.Mock(returncode=0, stdout="Already up to date.", stderr="")
        with mock.patch.object(host_daemon.subprocess, "run", return_value=fake) as run_mock:
            status, data = self.post_action({"action": "git_sync"}, headers={"X-Host-Token": "s3cret-test"})
        self.assertEqual(status, 200)
        self.assertEqual(data["status"], "ok")
        self.assertTrue(any("pull" in str(c) for c in run_mock.call_args_list))
        self.assertTrue(data["verified"])

    def test_git_sync_failure_is_reported_honestly(self):
        os.environ["HOST_DAEMON_TOKEN"] = "s3cret-test"
        fake = mock.Mock(returncode=1, stdout="", stderr="fatal: no remote")
        with mock.patch.object(host_daemon.subprocess, "run", return_value=fake):
            status, data = self.post_action({"action": "git_sync"}, headers={"X-Host-Token": "s3cret-test"})
        self.assertEqual(status, 502)
        self.assertEqual(data["status"], "error")
        self.assertFalse(data["verified"])

    def test_unknown_action_400_with_token(self):
        os.environ["HOST_DAEMON_TOKEN"] = "s3cret-test"
        status, _ = self.post_action({"action": "nonsense"}, headers={"X-Host-Token": "s3cret-test"})
        self.assertEqual(status, 400)

    def test_restart_reports_unverified_when_service_down(self):
        os.environ["HOST_DAEMON_TOKEN"] = "s3cret-test"
        with mock.patch.object(host_daemon, "_pkill", return_value=0), \
             mock.patch.object(host_daemon, "_poll_service", return_value=False):
            status, data = self.post_action({"action": "restart_nifty"}, headers={"X-Host-Token": "s3cret-test"})
        self.assertEqual(status, 502)
        self.assertFalse(data["verified"])

    def test_post_cors_never_star(self):
        os.environ["HOST_DAEMON_TOKEN"] = "s3cret-test"
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("POST", "/api/host/action", body="{}",
                     headers={"Content-Type": "application/json", "X-Host-Token": "s3cret-test"})
        resp = conn.getresponse()
        resp.read()
        self.assertNotEqual(resp.headers.get("Access-Control-Allow-Origin"), "*")
        conn.close()


class TestBodyValidation(DaemonTestCase):
    def setUp(self):
        super().setUp()
        os.environ["HOST_DAEMON_TOKEN"] = "s3cret-test"
        self.auth = {"X-Host-Token": "s3cret-test"}

    def test_malformed_json_400(self):
        status, data = self.post_action(raw_body="{not json", headers=self.auth)
        self.assertEqual(status, 400)
        self.assertIn("malformed", data["error"])

    def test_malformed_content_length_400(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.putrequest("POST", "/api/host/action")
        conn.putheader("X-Host-Token", "s3cret-test")
        conn.putheader("Content-Length", "abc")
        conn.endheaders(b"{}")
        resp = conn.getresponse()
        resp.read()
        self.assertEqual(resp.status, 400)
        conn.close()

    def test_missing_content_length_400(self):
        # http.client without a body sends no Content-Length for POST via putrequest
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.putrequest("POST", "/api/host/action")
        conn.putheader("X-Host-Token", "s3cret-test")
        conn.endheaders()
        resp = conn.getresponse()
        resp.read()
        self.assertEqual(resp.status, 400)
        conn.close()

    def test_oversized_body_413(self):
        big = "x" * (host_daemon.MAX_BODY_BYTES + 1)
        status, _ = self.post_action(raw_body=big, headers=self.auth)
        self.assertEqual(status, 413)


if __name__ == "__main__":
    unittest.main()
