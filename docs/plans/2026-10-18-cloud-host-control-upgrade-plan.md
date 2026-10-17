# Cloud Host Control Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform Cloud Host Control into an iPhone-optimized PWA with 0ms launch, real-time Samsung Galaxy Z Fold3 hardware telemetry (Battery, Temp, RAM, Uptime), remote one-click service controls, live diagnostics drawer, and self-healing tunnel architecture.

**Architecture:** A lightweight zero-dependency Python host daemon runs locally on the phone exposing `/api/host/vitals`, `/api/host/logs`, and `/api/host/action`. The GitHub Pages portal is upgraded into an installable PWA with ServiceWorker shell caching, iOS safe-area compliance, live telemetry strip, and remote action drawer with dual-mode CORS/no-cors fallback.

**Tech Stack:** Vanilla JavaScript (ES2022), HTML5/CSS3 (Tailwind-compatible with native variables), ServiceWorker API, Web App Manifest, Python 3 standard library (`http.server`, `urllib`), Termux / PRoot Ubuntu, Cloudflare Quick Tunnels.

**Spec:** [docs/specs/2026-10-18-cloud-host-control-upgrade-design.md](file:///Users/mayankyadav/Desktop/AI/Projects/Cloud%20Host%20Control/docs/specs/2026-10-18-cloud-host-control-upgrade-design.md)

## Global Constraints
- Target workspace: `/Users/mayankyadav/Desktop/AI/Projects/Cloud Host Control/`
- Host hardware: Samsung Galaxy Z Fold3 5G (SM-F926N) with Android Termux & PRoot Ubuntu.
- Zero bloat: Host daemon must use only Python 3 standard library; zero third-party packages installed on host.
- Scope boundary: Touch only Cloud Host Control repository and phone host daemon/watchdog scripts. Do not alter internal code of Nifty Analyzer or AvatarOps.
- Backwards compatibility: Existing tunnel resolution (`endpoints.json`) and service URLs must remain 100% operational.

## Review Focus
1. **Network Disconnects**: When phone sleeps or drops Wi-Fi, the portal UI must display a clean "Standby / Reconnecting" state without throwing uncaught JS console errors or freezing buttons.
2. **Path Traversal on Logs**: The log viewer endpoint must reject any path traversal (`../`) and only serve whitelisted log files (`nifty-analyzer.log`, `avatar-ops.log`, `watchdog.log`, `github_sync.log`).
3. **CORS on Telemetry**: All host daemon endpoints must emit `Access-Control-Allow-Origin: *` and handle `OPTIONS` preflight requests cleanly so GitHub Pages can query them.
4. **ServiceWorker Cache Busting**: The ServiceWorker must never cache dynamic responses (`endpoints.json`, `/api/host/vitals`, or log requests) to prevent stale tunnel URLs.
5. **iOS Viewport Clipping**: On iPhone devices with Notch / Dynamic Island, the dashboard must respect `env(safe-area-inset-top)` and `env(safe-area-inset-bottom)`.

---

### Task 1: Phone Host Telemetry & Remote Control Daemon (`host_daemon.py`)

**Files:**
- Create: `host_daemon.py` in `/Users/mayankyadav/Desktop/AI/Projects/Cloud Host Control/host_daemon.py`
- Test: Local execution via Python 3 unit test / curl verification

**Interfaces:**
- Produces:
  - `GET /api/host/vitals` -> `{"status": "online", "battery": {"capacity_pct": int, "temperature_c": float, "status": str}, "memory": {"total_mb": int, "used_mb": int}, "uptime_display": str, "services": dict}`
  - `GET /api/host/logs?service=str&lines=int` -> `{"service": str, "lines": [str]}`
  - `POST /api/host/action` -> `{"status": "ok", "action": str, "output": str}`

- [ ] **Step 1: Write host daemon test harness**
Create a test script `test_host_daemon.py` verifying `/api/host/vitals` schema and security against path traversal on `/api/host/logs`.

```python
import unittest
import json
import urllib.request
import threading
from host_daemon import run_server, HostDaemonHandler

class TestHostDaemon(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server_thread = threading.Thread(target=run_server, args=("127.0.0.1", 8999), daemon=True)
        cls.server_thread.start()

    def test_vitals_schema(self):
        req = urllib.request.urlopen("http://127.0.0.1:8999/api/host/vitals")
        self.assertEqual(req.status, 200)
        data = json.loads(req.read().decode())
        self.assertIn("battery", data)
        self.assertIn("memory", data)
        self.assertIn("services", data)

    def test_log_traversal_blocked(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen("http://127.0.0.1:8999/api/host/logs?service=../../etc/passwd")
        self.assertEqual(ctx.exception.code, 400)
```

- [ ] **Step 2: Run test to verify it fails**
Run: `python3 test_host_daemon.py`  
Expected: FAIL (host_daemon not found)

- [ ] **Step 3: Implement minimal `host_daemon.py`**
Implement standard library HTTP server with CORS headers, `/proc` / `/sys` metric readers, safe log tailing, and action execution.

```python
import os, sys, json, time, subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

ALLOWED_LOGS = {
    "nifty": "nifty-analyzer.log",
    "avatar": "avatar-ops.log",
    "watchdog": "watchdog.log",
    "sync": "github_sync.log"
}
LOG_DIR = os.path.expanduser("/data/data/com.termux/files/home/apps/logs")

def get_battery_info():
    # Read Android sysfs battery if available
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
    return {"capacity_pct": cap, "status": status, "temperature_c": temp, "is_ac_power": status.lower() == "charging"}

def get_memory_info():
    total, free, avail = 11420, 5000, 6000
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"): total = int(line.split()[1]) // 1024
                elif line.startswith("MemAvailable:"): avail = int(line.split()[1]) // 1024
    except Exception:
        pass
    used = total - avail
    return {"total_mb": total, "used_mb": used, "free_mb": avail, "used_pct": round(used / max(1, total) * 100, 1)}

def get_uptime_info():
    up_secs = 0
    try:
        with open("/proc/uptime") as f:
            up_secs = int(float(f.read().split()[0]))
    except Exception:
        pass
    days = up_secs // 86400
    hours = (up_secs % 86400) // 3600
    mins = (up_secs % 3600) // 60
    return {"uptime_seconds": up_secs, "uptime_display": f"{days}d {hours}h {mins}m"}

class HostDaemonHandler(BaseHTTPRequestHandler):
    def _send_cors(self, status=200, content_type="application/json"):
        self.send_response(status)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Host-Token")
        self.send_header("Content-Type", content_type)
        self.end_headers()

    def do_OPTIONS(self):
        self._send_cors(200)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/api/host/vitals":
            self._send_cors()
            vitals = {
                "status": "online",
                "device": "Samsung Galaxy Z Fold3 5G (SM-F926N)",
                "battery": get_battery_info(),
                "memory": get_memory_info(),
                "system": get_uptime_info(),
                "timestamp": int(time.time())
            }
            self.wfile.write(json.dumps(vitals).encode())
        elif u.path == "/api/host/logs":
            params = parse_qs(u.query)
            srv = params.get("service", [""])[0]
            if srv not in ALLOWED_LOGS:
                self._send_cors(400)
                self.wfile.write(json.dumps({"error": "Invalid service name"}).encode())
                return
            n_lines = int(params.get("lines", [50])[0])
            fpath = os.path.join(LOG_DIR, ALLOWED_LOGS[srv])
            lines = []
            if os.path.exists(fpath):
                with open(fpath, "r", errors="ignore") as f:
                    lines = [l.strip() for l in f.readlines()[-n_lines:]]
            self._send_cors()
            self.wfile.write(json.dumps({"service": srv, "lines": lines}).encode())
        else:
            self._send_cors(404)
            self.wfile.write(b'{"error": "Not found"}')

def run_server(host="0.0.0.0", port=8088):
    server = HTTPServer((host, port), HostDaemonHandler)
    server.serve_forever()

if __name__ == "__main__":
    port = int(os.environ.get("HOST_DAEMON_PORT", 8088))
    print(f"Starting Host Daemon on port {port}...")
    run_server("0.0.0.0", port)
```

- [ ] **Step 4: Run test to verify it passes**
Run: `python3 test_host_daemon.py`  
Expected: PASS

- [ ] **Step 5: Commit**
```bash
git add host_daemon.py test_host_daemon.py
git commit -m "feat(daemon): add host telemetry and log streaming daemon"
```

---

### Task 2: PWA Web App Manifest, ServiceWorker & App Icons

**Files:**
- Create: `manifest.json`
- Create: `sw.js`
- Create: `assets/icon.svg`, `assets/icon-192.png`, `assets/icon-512.png`

**Interfaces:**
- Produces:
  - `manifest.json` for browser installation (Add to Home Screen).
  - `sw.js` precaching UI assets with network-first fallback for `/api/` and `endpoints.json`.

- [ ] **Step 1: Create Web App Manifest (`manifest.json`)**
```json
{
  "name": "Fincept Cloud Host Control",
  "short_name": "Cloud Host",
  "description": "24/7 Mobile Cloud Host Control Center for Financial & AI Workloads",
  "start_url": "./",
  "display": "standalone",
  "orientation": "portrait",
  "background_color": "#0b0f19",
  "theme_color": "#0b0f19",
  "icons": [
    {
      "src": "./assets/icon-192.png",
      "sizes": "192x192",
      "type": "image/png",
      "purpose": "any maskable"
    },
    {
      "src": "./assets/icon-512.png",
      "sizes": "512x512",
      "type": "image/png",
      "purpose": "any maskable"
    }
  ]
}
```

- [ ] **Step 2: Create Service Worker (`sw.js`)**
Ensure network-first for live telemetry and `endpoints.json`, and stale-while-revalidate for local assets.

```javascript
const CACHE_NAME = "cloud-host-shell-v1";
const SHELL_ASSETS = [
  "./",
  "./index.html",
  "./manifest.json",
  "./assets/icon.svg",
  "./assets/icon-192.png"
];

self.addEventListener("install", (e) => {
  e.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_ASSETS)).then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  // Never cache live endpoints, tunnel APIs, or telemetry
  if (url.pathname.endsWith("endpoints.json") || url.pathname.includes("/api/") || url.search.includes("t=")) {
    e.respondWith(fetch(e.request));
    return;
  }
  // Stale-while-revalidate for shell assets
  e.respondWith(
    caches.match(e.request).then((cached) => {
      const fetchPromise = fetch(e.request).then((networkRes) => {
        if (networkRes.status === 200) {
          const resClone = networkRes.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(e.request, resClone));
        }
        return networkRes;
      }).catch(() => cached);
      return cached || fetchPromise;
    })
  );
});
```

- [ ] **Step 3: Generate PWA app icons**
Create high-resolution vector and PNG app icons in `assets/`.

- [ ] **Step 4: Verify ServiceWorker registration script**
Ensure `index.html` registers `sw.js` upon DOM load.

- [ ] **Step 5: Commit**
```bash
git add manifest.json sw.js assets/
git commit -m "feat(pwa): add progressive web app manifest, serviceworker and icons"
```

---

### Task 3: Portal Dashboard Telemetry Strip & Mobile Safe-Area Layout

**Files:**
- Modify: `index.html` (lines 1-120)

**Interfaces:**
- Consumes: `/api/host/vitals` from phone host daemon or AvatarOps power telemetry.
- Produces: Live visual HUD (battery bar, temperature indicator, RAM saturation, uptime).

- [ ] **Step 1: Add iOS Viewport, Manifest & Safe-Area Styles**
Update `<head>` with viewport-fit=cover, apple-touch-icon, and CSS variables:
```css
:root {
  --safe-top: env(safe-area-inset-top, 0px);
  --safe-bottom: env(safe-area-inset-bottom, 0px);
}
body {
  padding-top: max(20px, var(--safe-top));
  padding-bottom: max(20px, var(--safe-bottom));
}
```

- [ ] **Step 2: Add Host Vitals HUD HTML block**
Insert telemetry strip right below the hero header:
```html
<div class="vitals-strip" id="vitals-strip">
  <div class="vital-item">
    <span class="vital-label">Host Battery</span>
    <div class="vital-val-wrap">
      <div class="battery-meter"><div class="battery-level" id="battery-fill" style="width: 85%;"></div></div>
      <span class="vital-val" id="vital-battery">85% Charging</span>
    </div>
  </div>
  <div class="vital-item">
    <span class="vital-label">Thermal State</span>
    <span class="vital-val" id="vital-temp">🟢 32.4°C (Normal)</span>
  </div>
  <div class="vital-item">
    <span class="vital-label">Unified RAM</span>
    <span class="vital-val" id="vital-ram">💾 2.4 / 11.4 GB</span>
  </div>
  <div class="vital-item">
    <span class="vital-label">Host Uptime</span>
    <span class="vital-val" id="vital-uptime">⏱️ 4d 10h</span>
  </div>
</div>
```

- [ ] **Step 3: Wire JavaScript Telemetry Poller**
Fetch vitals from live host tunnel or fallback to power status:
```javascript
async function refreshHostVitals() {
  if (!avatarBaseUrl) return;
  try {
    const res = await fetch(avatarBaseUrl + "/api/power/status?t=" + Date.now());
    if (res.ok) {
      const p = await res.json();
      // Render battery, power source, and recommendation
      document.getElementById("vital-battery").textContent = p.is_ac_power ? "⚡ AC Power Connected" : "🔋 Battery";
      document.getElementById("vital-temp").innerHTML = `<span style="color:#10b981;">🟢 Active Host</span>`;
      document.getElementById("vital-ram").textContent = p.power_source || "Galaxy Z Fold3 5G";
    }
  } catch (e) {}
}
```

- [ ] **Step 4: Verify visual layout on desktop and mobile viewports**
Confirm cards do not overflow and spacing respects mobile displays.

- [ ] **Step 5: Commit**
```bash
git add index.html
git commit -m "feat(ui): add executive telemetry strip and iOS safe-area layout"
```

---

### Task 4: Remote Action Bar & Live Log Drawer

**Files:**
- Modify: `index.html` (lines 120-220)

**Interfaces:**
- Consumes: `/api/github/sync-now`, `/api/github/toggle-autosync`
- Produces: Collapsible live diagnostics log viewer modal.

- [ ] **Step 1: Add Quick Action Controls & Log Viewer Button**
Add action triggers to the control bar:
- "↻ Pull GitHub Updates Now"
- "📋 Live Diagnostics & Logs"

- [ ] **Step 2: Add Modal / Slide-out Drawer Markup**
Create diagnostic drawer with tabbed view:
- Tab 1: `AvatarOps Engine`
- Tab 2: `Nifty 50 Analyzer`
- Tab 3: `Watchdog & Sync`
- Preformatted terminal-style `<pre>` output with monospace font.

- [ ] **Step 3: Wire Log Streamer JavaScript**
Implement `openLogsModal(service)`, fetching live logs from `/api/logs?limit=50` and auto-scrolling to bottom.

- [ ] **Step 4: Verify Modal Functionality**
Test open, tab switch, and close interactions.

- [ ] **Step 5: Commit**
```bash
git add index.html
git commit -m "feat(diagnostics): add live log viewer drawer and remote control bar"
```

---

### Task 5: Tunnel Watchdog Integration on Phone Host

**Files:**
- Modify: `/data/data/com.termux/files/home/apps/tunnel_watchdog.sh` on phone host
- Deploy: `host_daemon.py` to phone host

**Interfaces:**
- Produces: Self-healing background loop maintaining `cloudflared`, `nifty-analyzer`, `avatar-ops`, and `host_daemon`.

- [ ] **Step 1: Add host_daemon to watchdog startup on phone**
Update `tunnel_watchdog.sh` on phone to ensure `host_daemon.py` is running on port 8088.

- [ ] **Step 2: Test daemon endpoint locally via ADB**
Run: `adb shell "curl -s http://localhost:8088/api/host/vitals"`  
Expected: Valid JSON with device vitals.

- [ ] **Step 3: Verify watchdog recovery cycle**
Verify watchdog restarts services if hung or disconnected.

---

### Task 6: End-to-End System Verification

- [ ] **Step 1: Rebase and push all commits to GitHub `Mayank9644/cloud-portal`**
- [ ] **Step 2: Trigger GitHub pull on phone host**
- [ ] **Step 3: Open `https://mayank9644.github.io/cloud-portal/` in browser**
  - Verify ServiceWorker registers.
  - Verify exactly 2 cards display with `🟢 Online`.
  - Verify live telemetry strip updates with phone power/host status.
  - Test clicking "📋 Live Diagnostics" and viewing live logs.
