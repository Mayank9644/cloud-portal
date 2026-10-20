"""C3 regression test for scripts/tunnel_watchdog.sh probe_status_code.

The audit bug: a failed curl produced "000000" (curl's own 000 plus
`|| echo 000`), which the watchdog then treated as healthy.
These tests source the watchdog with WATCHDOG_SOURCE_ONLY=1 (so the main
loop does not run) and call the real probe function from bash.
"""
import http.server
import os
import subprocess
import threading
import unittest

REPO = os.path.dirname(os.path.abspath(__file__))
WATCHDOG = os.path.join(REPO, "scripts", "tunnel_watchdog.sh")


def probe(url):
    env = dict(os.environ)
    env["WATCHDOG_SOURCE_ONLY"] = "1"
    script = f'source "{WATCHDOG}" >/dev/null 2>&1; probe_status_code "{url}"'
    out = subprocess.run(
        ["bash", "-c", script], capture_output=True, text=True, timeout=30, env=env
    )
    return out.stdout.strip()


class StatusHandler(http.server.BaseHTTPRequestHandler):
    code = 200

    def do_GET(self):
        self.send_response(self.code)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *args):
        pass


class TestWatchdogProbe(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.servers = {}
        for name, code in (("ok", 200), ("err", 500)):
            handler = type(f"H{code}", (StatusHandler,), {"code": code})
            srv = http.server.HTTPServer(("127.0.0.1", 0), handler)
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            cls.servers[name] = srv

    @classmethod
    def tearDownClass(cls):
        for srv in cls.servers.values():
            srv.shutdown()
            srv.server_close()

    def test_dead_port_is_exactly_000(self):
        # A port nothing listens on: curl fails outright.
        code = probe("http://127.0.0.1:9/")  # port 9 discard, closed in practice
        if code != "000":
            # Fallback dead port: bind then close to get a free port number.
            import socket
            s = socket.socket()
            s.bind(("127.0.0.1", 0))
            dead = s.getsockname()[1]
            s.close()
            code = probe(f"http://127.0.0.1:{dead}/")
        self.assertEqual(code, "000")  # NOT "000000" (the C3 bug)

    def test_http_200(self):
        port = self.servers["ok"].server_address[1]
        self.assertEqual(probe(f"http://127.0.0.1:{port}/"), "200")

    def test_http_500(self):
        port = self.servers["err"].server_address[1]
        self.assertEqual(probe(f"http://127.0.0.1:{port}/"), "500")


if __name__ == "__main__":
    unittest.main()
