# Cloud Host Control: 24/7 Phone Host Telemetry, Remote Management & PWA Architecture

**Document ID**: SPEC-2026-10-18-CHC-UPGRADE  
**Target Repository**: `Mayank9644/cloud-portal` (`/Users/mayankyadav/Desktop/AI/Projects/Cloud Host Control/`)  
**Host Hardware Target**: Samsung Galaxy Z Fold3 5G (SM-F926N) • Apple Silicon M1 (Development Workstation)  
**Status**: APPROVED DESIGN SPECIFICATION  

---

## 1. Executive Summary & Problem Definition

The **Cloud Host Control** system orchestrates 24/7 background microservices (Nifty 50 Analyzer on port 5001 and AvatarOps Engine on port 8080) running on a dedicated Android host (Samsung Galaxy Z Fold3) exposed via Cloudflare edge tunnels to a GitHub Pages portal dashboard (`https://mayank9644.github.io/cloud-portal/`).

### Prior Deficiencies
1. **Zero Host Observability**: The user cannot view host battery level, thermal state, RAM saturation, or device uptime without attaching USB debugging (ADB) or SSH.
2. **No Remote Control**: Service restarts or tunnel recycling required physical phone interaction or terminal sessions.
3. **Mobile & iPhone Friction**: Uncached network waterfalls and lack of iOS safe-area handling caused intermittent UI hangs and Safari layout clipping.
4. **Ephemeral URL Lag**: Free trycloudflare tunnels regenerate URLs on network switches; GitHub CDN caching can cause 2–5 minute lag before the portal resolves the new URL.

---

## 2. Architectural Boundaries & System Decomposition

### Scope Boundaries
* **Included**: `Cloud Host Control` portal (`Mayank9644/cloud-portal`), phone-side host daemon, watchdog scripts, ServiceWorker PWA engine, and telemetry visualization.
* **Explicitly Excluded**: Application internals of `Nifty 50 Analyzer` (`Mayank9644/nifty-analyzer`) and `AvatarOps Engine` (`avatar_ops`), which remain self-contained in their own respective projects.

### System Diagram

```
┌──────────────────────────────────────────────────────────────┐
│  Client Device (iPhone / Safari / Desktop PWA)               │
│  ├── ServiceWorker Shell (0ms local launch cache)            │
│  ├── Executive Telemetry Strip (Battery, Temp, RAM, Uptime)   │
│  ├── Quick Action Bar (Restart, Re-sync, Cycle Tunnels)      │
│  └── Live Diagnostics Drawer (Tail 50 lines per service)     │
└───────────────▲──────────────────────────────▲───────────────┘
                │ Direct Tunnel / HTTPS        │ endpoints.json
                │                              │
┌───────────────▼──────────────────────────────┴───────────────┐
│  Host Device: Samsung Galaxy Z Fold3 5G (SM-F926N)            │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ Tmux Session "cloudhost"                                │ │
│  │  ├── 0: avatar-ops      (FastAPI :8080)                 │ │
│  │  ├── 1: nifty-analyzer  (Gunicorn :5001)                │ │
│  │  ├── 2: host-daemon     (Telemetry & Control :8088)     │ │
│  │  ├── 3: github-sync     (Auto-Deployer)                 │ │
│  │  ├── 4: tunnel-avatar   (cloudflared -> :8080)          │ │
│  │  ├── 5: tunnel-nifty    (cloudflared -> :5001)          │ │
│  │  └── 6: watchdog        (tunnel_watchdog.sh)            │ │
│  └─────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

---

## 3. Host Telemetry & Control Daemon (`host_daemon.py`)

A zero-dependency Python 3 standard-library HTTP server running locally on the phone at `127.0.0.1:8088` (or exposed through a dedicated edge endpoint).

### 3.1 REST API Specification

#### `GET /api/host/vitals`
Returns real-time operating metrics from Android `/sys` and `/proc` filesystems:
```json
{
  "status": "online",
  "device": "Samsung Galaxy Z Fold3 5G (SM-F926N)",
  "battery": {
    "capacity_pct": 85,
    "status": "Charging",
    "is_ac_power": true,
    "temperature_c": 32.4
  },
  "memory": {
    "total_mb": 11420,
    "used_mb": 2410,
    "free_mb": 6250,
    "used_pct": 21.1
  },
  "system": {
    "load_1m": 0.42,
    "uptime_seconds": 384200,
    "uptime_display": "4d 10h 43m",
    "thermal_state": "normal"
  },
  "services": {
    "nifty_analyzer": { "port": 5001, "alive": true, "pid": 26802 },
    "avatar_ops": { "port": 8080, "alive": true, "pid": 25087 },
    "watchdog": { "alive": true }
  }
}
```

#### `GET /api/host/logs?service=<nifty|avatar|watchdog>&lines=50`
Safely streams the tail of the requested service log file from `/data/data/com.termux/files/home/apps/logs/`.
* Path traversal protection enforced: service must match a strict enum.

#### `POST /api/host/action`
Headers: `X-Host-Token: <SECRET_TOKEN>`  
Payload: `{"action": "restart_nifty" | "restart_avatar" | "recycle_tunnels" | "git_pull_all"}`  
* Executes controlled process cycling without requiring shell access.

---

## 4. Web Portal Dashboard Upgrade (`index.html`)

### 4.1 Telemetry Strip (Header Bar)
* **Battery Meter**: Real-time percentage badge with dynamic color transitions (`🟢 >35%`, `🟡 15-35%`, `🔴 <15%`) and charging bolt indicator.
* **Thermal Badge**: Live host temperature monitor (`🟢 <38°C Normal`, `🟡 38-43°C Warm`, `🔴 >44°C Hot`).
* **RAM Footprint**: Clean numerical badge (e.g. `💾 2.4 / 11.4 GB (21%)`).
* **Uptime Counter**: Displayed from host kernel statistics.

### 4.2 Quick Action Panel
* Buttons for **↻ Pull GitHub Updates**, **🔄 Restart Services**, and **⚡ Recycle Tunnels**.
* Optimistic UI with immediate feedback ("⏳ Executing...") and auto-reverting status toasts.

### 4.3 Live Log Diagnostic Drawer
* Integrated slide-out drawer or full-screen modal on mobile.
* Tabbed selection between Nifty Analyzer, AvatarOps, and Watchdog logs.
* Auto-refresh toggle (every 5 seconds) with manual refresh button.

---

## 5. iPhone & Mobile Progressive Web App (PWA) Engine

### 5.1 Web App Manifest (`manifest.json`)
* `name`: "Fincept Cloud Host Control"
* `short_name`: "Cloud Host"
* `display`: "standalone"
* `orientation`: "portrait"
* `background_color`: "#0b0f19"
* `theme_color`: "#0b0f19"
* High-resolution adaptive SVG and PNG icon definitions (192x192, 512x512).

### 5.2 Service Worker (`sw.js`)
* **Shell Caching**: Caches `index.html`, stylesheets, fonts, and local assets using a Stale-While-Revalidate pattern. Allows the app shell to render in **0ms** even offline or under poor cellular coverage.
* **Network-Only for Live Endpoints**: Explicitly bypasses cache for `/api/host/vitals`, `endpoints.json`, and dynamic tunnel requests using `cache: 'no-store'`.

### 5.3 iOS Safari Safe-Area Compliance
* Enforce `<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">`.
* CSS padding variables `env(safe-area-inset-top)` and `env(safe-area-inset-bottom)` applied to dashboard wrapper.
* iOS status bar config: `<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">`.

---

## 6. Tunnel Resilience & Dynamic Edge Resolution

1. **Watchdog Self-Healing (`tunnel_watchdog.sh`)**:
   * Evaluates service health endpoints (`http://127.0.0.1:5001/health` and `http://127.0.0.1:8080/api/power/status`) every 10 seconds.
   * Auto-recycles hung tunnels upon noticing disconnect patterns.
   * On URL change, updates `endpoints.json` and pushes to GitHub within 5 seconds.
2. **Client-Side Cache Busting**:
   * All client requests to `endpoints.json` append `?t=<timestamp>` to bypass GitHub's 5-minute raw CDN cache.
   * Dual-mode probing (`cors` with instant fallback to `no-cors`) ensures host status is recognized without blocking.
3. **Gateway Fast-Path**:
   * Sub-gateways (`nifty-analyzer/index.html` and `avatar-ops/index.html`) automatically bypass the 3-second probing screen if the host was marked alive within the last 60 seconds.

---

## 7. Verification & Acceptance Criteria

1. **Host Daemon Verification**:
   * `curl http://127.0.0.1:8088/api/host/vitals` returns valid JSON containing battery, RAM, uptime, and service status.
2. **Portal Vitals Verification**:
   * Opening `https://mayank9644.github.io/cloud-portal/` renders real-time battery %, temperature, and RAM from the Samsung Galaxy Z Fold3.
3. **Remote Control Verification**:
   * Triggering "Pull GitHub Updates" or "Restart Service" from the portal successfully executes on the phone and reflects in the live log.
4. **PWA & Mobile Verification**:
   * Adding to iPhone Home Screen launches in full standalone mode without browser chrome.
   * Subsequent page loads on mobile load the UI shell in under 100ms.
5. **No Regressions**:
   * AvatarOps (Port 8080) and Nifty Analyzer (Port 5001) launch cleanly with exactly 2 cards on the dashboard.
