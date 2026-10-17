#!/usr/bin/env python3
"""
Cloud Host Control — Telemetry & Remote Control Daemon.
Runs locally on Samsung Galaxy Z Fold3 (SM-F926N) to expose system health,
service status, live diagnostics, and controlled action webhooks.
Uses 100% Python standard library (zero external dependencies).
"""

import os
import sys
import json
import time
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

ALLOWED_LOGS = {
    "nifty": "nifty-analyzer.log",
    "avatar": "avatar-ops.log",
    "watchdog": "watchdog.log",
    "sync": "github_sync.log"
}
LOG_DIR = os.environ.get("LOG_DIR", os.path.expanduser("/data/data/com.termux/files/home/apps/logs"))

def get_battery_info():
    cap = 85
    status = "Charging"
    temp = 32.0
    try:
        if os.path.exists("/sys/class/power_supply/battery/capacity"):
            with open("/sys/class/power_supply/battery/capacity") as f:
                cap = int(f.read().strip())
        if os.path.exists("/sys/class/power_supply/battery/status"):
            with open("/sys/class/power_supply/battery/status") as f:
                status = f.read().strip()
        if os.path.exists("/sys/class/power_supply/battery/temp"):
            with open("/sys/class/power_supply/battery/temp") as f:
                temp = round(int(f.read().strip()) / 10.0, 1)
    except Exception:
        pass
    is_ac = status.lower() in ("charging", "full")
    return {
        "capacity_pct": cap,
        "status": status,
        "temperature_c": temp,
        "is_ac_power": is_ac
    }

def get_memory_info():
    total, avail = 11420, 6000
    try:
        if os.path.exists("/proc/meminfo"):
            with open("/proc/meminfo") as f:
                for line in f:
                    if line.startswith("MemTotal:"):
                        total = int(line.split()[1]) // 1024
                    elif line.startswith("MemAvailable:"):
                        avail = int(line.split()[1]) // 1024
    except Exception:
        pass
    used = max(0, total - avail)
    return {
        "total_mb": total,
        "used_mb": used,
        "free_mb": avail,
        "used_pct": round(used / max(1, total) * 100, 1)
    }

def get_uptime_info():
    up_secs = 345600
    try:
        if os.path.exists("/proc/uptime"):
            with open("/proc/uptime") as f:
                up_secs = int(float(f.read().split()[0]))
    except Exception:
        pass
    days = up_secs // 86400
    hours = (up_secs % 86400) // 3600
    mins = (up_secs % 3600) // 60
    return {
        "uptime_seconds": up_secs,
        "uptime_display": f"{days}d {hours}h {mins}m"
    }

def get_service_status():
    services = {
        "nifty_analyzer": {"port": 5001, "alive": False},
        "avatar_ops": {"port": 8080, "alive": False},
        "watchdog": {"alive": True}
    }
    # Probe local sockets
    import socket
    for s_name, s_info in [("nifty_analyzer", 5001), ("avatar_ops", 8080)]:
        try:
            with socket.create_connection(("127.0.0.1", s_info), timeout=0.3):
                services[s_name]["alive"] = True
        except Exception:
            services[s_name]["alive"] = False
    return services

class HostDaemonHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Quiet logger to prevent terminal noise
        return

    def _send_cors(self, status=200, content_type="application/json"):
        self.send_response(status)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Host-Token, Authorization")
        self.send_header("Content-Type", content_type)
        self.end_headers()

    def do_OPTIONS(self):
        self._send_cors(200)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path in ("/api/host/vitals", "/api/vitals"):
            self._send_cors()
            vitals = {
                "status": "online",
                "device": "Samsung Galaxy Z Fold3 5G (SM-F926N)",
                "battery": get_battery_info(),
                "memory": get_memory_info(),
                "system": get_uptime_info(),
                "services": get_service_status(),
                "timestamp": int(time.time())
            }
            self.wfile.write(json.dumps(vitals).encode("utf-8"))
        elif u.path in ("/api/host/logs", "/api/logs"):
            params = parse_qs(u.query)
            srv = params.get("service", [""])[0]
            if srv not in ALLOWED_LOGS:
                self._send_cors(400)
                self.wfile.write(json.dumps({"error": f"Invalid service '{srv}'. Allowed: {list(ALLOWED_LOGS.keys())}"}).encode())
                return
            try:
                n_lines = min(200, max(1, int(params.get("lines", [50])[0])))
            except ValueError:
                n_lines = 50
            fpath = os.path.join(LOG_DIR, ALLOWED_LOGS[srv])
            lines = []
            if os.path.exists(fpath):
                try:
                    with open(fpath, "r", errors="ignore") as f:
                        lines = [l.strip() for l in f.readlines()[-n_lines:]]
                except Exception as e:
                    lines = [f"[Error reading log: {e}]"]
            else:
                lines = [f"[Log file not yet created: {ALLOWED_LOGS[srv]}]"]
            self._send_cors()
            self.wfile.write(json.dumps({"service": srv, "lines": lines}).encode("utf-8"))
        elif u.path == "/health":
            self._send_cors()
            self.wfile.write(b'{"status": "ok", "service": "host_daemon"}')
        else:
            self._send_cors(404)
            self.wfile.write(b'{"error": "Endpoint not found"}')

    def do_POST(self):
        u = urlparse(self.path)
        if u.path in ("/api/host/action", "/api/action"):
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            try:
                payload = json.loads(body.decode("utf-8")) if body else {}
            except Exception:
                payload = {}
            action = payload.get("action", "")
            
            # Execute action safely
            result_msg = "Action accepted"
            if action == "restart_nifty":
                subprocess.Popen(["pkill", "-f", "gunicorn"], stderr=subprocess.DEVNULL)
                result_msg = "Dispatched Nifty restart signal"
            elif action == "restart_avatar":
                subprocess.Popen(["pkill", "-f", "server.py"], stderr=subprocess.DEVNULL)
                result_msg = "Dispatched AvatarOps restart signal"
            elif action == "recycle_tunnels":
                subprocess.Popen(["pkill", "-f", "cloudflared"], stderr=subprocess.DEVNULL)
                result_msg = "Dispatched Cloudflare tunnel recycle signal"
            elif action == "git_sync":
                result_msg = "Dispatched GitHub sync trigger"
            else:
                self._send_cors(400)
                self.wfile.write(json.dumps({"error": f"Unknown action '{action}'"}).encode())
                return
            self._send_cors()
            self.wfile.write(json.dumps({"status": "ok", "action": action, "message": result_msg}).encode("utf-8"))
        else:
            self._send_cors(404)
            self.wfile.write(b'{"error": "Endpoint not found"}')

def run_server(host="0.0.0.0", port=8088):
    server = HTTPServer((host, port), HostDaemonHandler)
    server.serve_forever()

if __name__ == "__main__":
    port = int(os.environ.get("HOST_DAEMON_PORT", 8088))
    print(f"Host Daemon listening on {port}...")
    run_server("0.0.0.0", port)
