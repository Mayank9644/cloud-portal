#!/usr/bin/env python3
"""
Cloud Host Control — Telemetry & Remote Control Daemon.
Runs locally on Samsung Galaxy Z Fold3 (SM-F926N) to expose system health,
service status, live diagnostics, and controlled action webhooks.
Uses 100% Python standard library (zero external dependencies).

Security / honesty model (audit C1, H-4, H-5, H-7):
- POST /api/host/action requires header X-Host-Token matching the
  HOST_DAEMON_TOKEN environment variable (constant-time compare).
  FAIL CLOSED: if HOST_DAEMON_TOKEN is unset, actions return 503 and
  nothing is executed. GET endpoints keep working.
- Binds to HOST_DAEMON_BIND (default 127.0.0.1), never 0.0.0.0 by default.
- CORS origin is HOST_DAEMON_CORS_ORIGIN (default the GitHub Pages origin),
  never "*".
- Telemetry is honest: an unreadable source yields nulls plus a `sources`
  map ("real"/"unavailable"), never fabricated fallback numbers.
"""

import hmac
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ALLOWED_LOGS = {
    "nifty": "nifty-analyzer.log",
    "avatar": "avatar-ops.log",
    "watchdog": "watchdog.log",
    "sync": "github_sync.log",
}
LOG_DIR = os.environ.get(
    "LOG_DIR",
    os.path.expanduser(
        "/data/data/com.termux/files/home/apps/logs"
        if os.path.isdir("/data/data/com.termux/files/home")
        else "~/apps/logs"
    ),
)
MAX_BODY_BYTES = 16384
DEFAULT_CORS_ORIGIN = "https://mayank9644.github.io"


def cors_origin():
    return os.environ.get("HOST_DAEMON_CORS_ORIGIN", DEFAULT_CORS_ORIGIN)


def _termux_battery():
    """Battery via Termux:API `termux-battery-status` (JSON). None if absent."""
    try:
        proc = subprocess.run(
            ["termux-battery-status"], capture_output=True, text=True, timeout=3
        )
        if proc.returncode != 0 or not proc.stdout.strip():
            return None
        data = json.loads(proc.stdout)
        temp = data.get("temperature")
        return {
            "capacity_pct": data.get("percentage"),
            "status": data.get("status"),
            "temperature_c": float(temp) if temp is not None else None,
            "is_ac_power": str(data.get("plugged", "")).upper() not in ("", "UNPLUGGED")
            or str(data.get("status", "")).lower() in ("charging", "full"),
        }
    except Exception:
        return None


def _sys_battery():
    """Battery via /sys/class/power_supply. None if nothing readable."""
    base = "/sys/class/power_supply/battery"
    out = {"capacity_pct": None, "status": None, "temperature_c": None, "is_ac_power": None}
    got = False
    try:
        cap = os.path.join(base, "capacity")
        if os.path.exists(cap):
            with open(cap) as f:
                out["capacity_pct"] = int(f.read().strip())
            got = True
        st = os.path.join(base, "status")
        if os.path.exists(st):
            with open(st) as f:
                out["status"] = f.read().strip()
            got = True
        tp = os.path.join(base, "temp")
        if os.path.exists(tp):
            with open(tp) as f:
                out["temperature_c"] = round(int(f.read().strip()) / 10.0, 1)
            got = True
    except Exception:
        return None
    if not got:
        return None
    if out["status"] is not None:
        out["is_ac_power"] = out["status"].lower() in ("charging", "full")
    return out


def get_battery_info():
    """Returns (info_dict, source): 'termux-api' | 'sys' | 'unavailable'."""
    info = _termux_battery()
    if info is not None:
        return info, "termux-api"
    info = _sys_battery()
    if info is not None:
        return info, "sys"
    return {
        "capacity_pct": None,
        "status": None,
        "temperature_c": None,
        "is_ac_power": None,
    }, "unavailable"


def get_memory_info():
    """Returns (info_dict, source). Reads /proc/meminfo only; no fallbacks."""
    total = avail = None
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    total = int(line.split()[1]) // 1024
                elif line.startswith("MemAvailable:"):
                    avail = int(line.split()[1]) // 1024
    except Exception:
        total = avail = None
    if total is None or avail is None:
        return {"total_mb": None, "used_mb": None, "free_mb": None, "used_pct": None}, "unavailable"
    used = max(0, total - avail)
    return {
        "total_mb": total,
        "used_mb": used,
        "free_mb": avail,
        "used_pct": round(used / max(1, total) * 100, 1),
    }, "proc"


def get_uptime_info():
    """Returns (info_dict, source). Reads /proc/uptime only; no fallbacks."""
    try:
        with open("/proc/uptime") as f:
            up_secs = int(float(f.read().split()[0]))
    except Exception:
        return {"uptime_seconds": None, "uptime_display": None}, "unavailable"
    days = up_secs // 86400
    hours = (up_secs % 86400) // 3600
    mins = (up_secs % 3600) // 60
    return {
        "uptime_seconds": up_secs,
        "uptime_display": f"{days}d {hours}h {mins}m",
    }, "proc"


def watchdog_heartbeat_path():
    env = os.environ.get("WATCHDOG_HEARTBEAT_FILE")
    if env:
        return os.path.expanduser(env)
    return os.path.join(LOG_DIR, "watchdog.heartbeat")


def get_watchdog_alive():
    """Real check: heartbeat file touched by tunnel_watchdog.sh, <60s old."""
    try:
        mtime = os.path.getmtime(watchdog_heartbeat_path())
        return (time.time() - mtime) < 60
    except OSError:
        return False


def _http_status(url, timeout=1.5):
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return None


def get_service_status():
    services = {}
    for name, port, path in (
        ("nifty_analyzer", 5001, "/health"),
        ("avatar_ops", 8080, "/"),
    ):
        tcp_alive = False
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                tcp_alive = True
        except Exception:
            tcp_alive = False
        http_status = _http_status(f"http://127.0.0.1:{port}{path}") if tcp_alive else None
        alive = bool(tcp_alive and http_status is not None and http_status < 500)
        services[name] = {
            "port": port,
            "alive": alive,
            "tcp_alive": tcp_alive,
            "http_status": http_status,
        }
    services["watchdog"] = {"alive": get_watchdog_alive()}
    return services


def get_vitals():
    battery, battery_src = get_battery_info()
    memory, memory_src = get_memory_info()
    uptime, uptime_src = get_uptime_info()
    warning = None
    temp = battery.get("temperature_c")
    if temp is not None and temp > 45:
        warning = f"Battery temperature {temp}C exceeds 45C - thermal risk"
    return {
        "status": "online",
        "device": "Samsung Galaxy Z Fold3 5G (SM-F926N)",
        "battery": battery,
        "memory": memory,
        "system": uptime,
        "services": get_service_status(),
        "warning": warning,
        "sources": {
            "battery": "real" if battery_src != "unavailable" else "unavailable",
            "battery_via": battery_src,
            "memory": "real" if memory_src != "unavailable" else "unavailable",
            "uptime": "real" if uptime_src != "unavailable" else "unavailable",
        },
        "timestamp": int(time.time()),
    }


def _pkill(pattern):
    try:
        proc = subprocess.run(
            ["pkill", "-f", pattern], capture_output=True, text=True, timeout=10
        )
        return proc.returncode
    except Exception:
        return -1


def _poll_service(service_key, timeout_sec=None):
    """Poll service health until alive or timeout. Returns bool."""
    if timeout_sec is None:
        try:
            timeout_sec = float(os.environ.get("HOST_DAEMON_VERIFY_TIMEOUT_SEC", "15"))
        except ValueError:
            timeout_sec = 15
    deadline = time.time() + max(0.0, timeout_sec)
    while True:
        try:
            if get_service_status().get(service_key, {}).get("alive"):
                return True
        except Exception:
            pass
        if time.time() >= deadline:
            return False
        time.sleep(0.5)


def do_git_sync():
    """Real git pull --ff-only in the portal repo. Returns (ok, message, output_tail)."""
    repo_dir = os.path.expanduser(os.environ.get("PORTAL_REPO_DIR", "~/apps/cloud-portal"))
    try:
        proc = subprocess.run(
            ["git", "-C", repo_dir, "pull", "--ff-only"],
            capture_output=True, text=True, timeout=30,
        )
        output = ((proc.stdout or "") + (proc.stderr or ""))[-2000:]
        if proc.returncode == 0:
            return True, f"git pull --ff-only succeeded in {repo_dir}", output
        return False, f"git pull --ff-only failed (rc={proc.returncode}) in {repo_dir}", output
    except subprocess.TimeoutExpired:
        return False, "git pull --ff-only timed out after 30s", ""
    except Exception as e:
        return False, f"git pull could not run: {e}", ""


class HostDaemonHandler(BaseHTTPRequestHandler):
    server_version = "HostDaemon/2.0"

    def log_message(self, format, *args):  # noqa: A002 - stdlib signature
        sys.stderr.write(
            "%s - - [%s] %s\n"
            % (self.client_address[0], self.log_date_time_string(), format % args)
        )

    def _send(self, status=200, payload=None, raw=None):
        body = raw if raw is not None else json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Access-Control-Allow-Origin", cors_origin())
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Host-Token, Authorization")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_OPTIONS(self):
        self._send(200, raw=b"")

    def do_GET(self):
        u = urlparse(self.path)
        if u.path in ("/api/host/vitals", "/api/vitals"):
            self._send(200, get_vitals())
        elif u.path in ("/api/host/logs", "/api/logs"):
            params = parse_qs(u.query)
            srv = params.get("service", [""])[0]
            if srv not in ALLOWED_LOGS:
                self._send(400, {"error": f"Invalid service '{srv}'. Allowed: {list(ALLOWED_LOGS.keys())}"})
                return
            try:
                n_lines = min(200, max(1, int(params.get("lines", [50])[0])))
            except (ValueError, TypeError):
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
            self._send(200, {"service": srv, "lines": lines})
        elif u.path == "/health":
            self._send(200, {"status": "ok", "service": "host_daemon"})
        else:
            self._send(404, {"error": "Endpoint not found"})

    def _check_action_auth(self):
        """Returns None if authorised, else (status, payload) to send."""
        expected = os.environ.get("HOST_DAEMON_TOKEN", "")
        if not expected:
            return 503, {"error": "actions disabled: HOST_DAEMON_TOKEN not set", "status": "error"}
        provided = self.headers.get("X-Host-Token", "")
        if not provided or not hmac.compare_digest(provided, expected):
            return 401, {"error": "unauthorized: missing or invalid X-Host-Token", "status": "error"}
        return None

    def do_POST(self):
        u = urlparse(self.path)
        if u.path not in ("/api/host/action", "/api/action"):
            self._send(404, {"error": "Endpoint not found"})
            return
        auth_error = self._check_action_auth()
        if auth_error is not None:
            status, payload = auth_error
            self._send(status, payload)
            return
        raw_len = self.headers.get("Content-Length")
        if raw_len is None:
            self._send(400, {"error": "missing Content-Length", "status": "error"})
            return
        try:
            content_length = int(raw_len)
        except (TypeError, ValueError):
            self._send(400, {"error": "invalid Content-Length", "status": "error"})
            return
        if content_length < 0:
            self._send(400, {"error": "invalid Content-Length", "status": "error"})
            return
        if content_length > MAX_BODY_BYTES:
            self._send(413, {"error": "request body too large", "status": "error"})
            return
        body = self.rfile.read(content_length) if content_length else b""
        try:
            payload = json.loads(body.decode("utf-8")) if body else {}
            if not isinstance(payload, dict):
                raise ValueError("payload must be a JSON object")
        except Exception:
            self._send(400, {"error": "malformed JSON body", "status": "error"})
            return
        action = payload.get("action", "")
        if action == "restart_nifty":
            _pkill("gunicorn")
            verified = _poll_service("nifty_analyzer")
            self._send(200 if verified else 502, {
                "status": "ok" if verified else "error",
                "action": action,
                "message": "Nifty restart signal sent",
                "verified": verified,
            })
        elif action == "restart_avatar":
            _pkill("server.py")
            verified = _poll_service("avatar_ops")
            self._send(200 if verified else 502, {
                "status": "ok" if verified else "error",
                "action": action,
                "message": "AvatarOps restart signal sent",
                "verified": verified,
            })
        elif action == "recycle_tunnels":
            _pkill("cloudflared tunnel")
            self._send(200, {
                "status": "ok",
                "action": action,
                "message": "Cloudflare tunnel recycle signal sent; runner loops will restart them",
                "verified": False,
            })
        elif action == "git_sync":
            ok, message, tail = do_git_sync()
            self._send(200 if ok else 502, {
                "status": "ok" if ok else "error",
                "action": action,
                "message": message,
                "output_tail": tail,
                "verified": ok,
            })
        else:
            self._send(400, {"error": f"Unknown action '{action}'", "status": "error"})
            return


def create_server(host=None, port=None):
    if host is None:
        host = os.environ.get("HOST_DAEMON_BIND", "127.0.0.1")
    if port is None:
        port = int(os.environ.get("HOST_DAEMON_PORT", "8088"))
    server = ThreadingHTTPServer((host, port), HostDaemonHandler)
    server.daemon_threads = True
    return server


def run_server(host=None, port=None):
    server = create_server(host, port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return server


if __name__ == "__main__":
    _port = int(os.environ.get("HOST_DAEMON_PORT", "8088"))
    _host = os.environ.get("HOST_DAEMON_BIND", "127.0.0.1")
    print(f"Host Daemon listening on {_host}:{_port}...", file=sys.stderr)
    run_server(_host, _port)
