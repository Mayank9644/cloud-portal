import unittest
import json
import urllib.request
import urllib.error
import threading
import time
from host_daemon import run_server, ALLOWED_LOGS

class TestHostDaemon(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server_thread = threading.Thread(target=run_server, args=("127.0.0.1", 8999), daemon=True)
        cls.server_thread.start()
        time.sleep(0.3)

    def test_vitals_schema(self):
        req = urllib.request.urlopen("http://127.0.0.1:8999/api/host/vitals")
        self.assertEqual(req.status, 200)
        data = json.loads(req.read().decode())
        self.assertEqual(data.get("status"), "online")
        self.assertIn("battery", data)
        self.assertIn("capacity_pct", data["battery"])
        self.assertIn("memory", data)
        self.assertIn("total_mb", data["memory"])
        self.assertIn("system", data)
        self.assertIn("uptime_display", data["system"])

    def test_cors_headers_present(self):
        req = urllib.request.Request("http://127.0.0.1:8999/api/host/vitals", method="OPTIONS")
        with urllib.request.urlopen(req) as resp:
            self.assertEqual(resp.status, 200)
            self.assertEqual(resp.headers.get("Access-Control-Allow-Origin"), "*")
            self.assertIn("GET", resp.headers.get("Access-Control-Allow-Methods", ""))

    def test_log_traversal_blocked(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen("http://127.0.0.1:8999/api/host/logs?service=../../etc/passwd")
        self.assertEqual(ctx.exception.code, 400)

if __name__ == "__main__":
    unittest.main()
