# Cloud Portal — Cloud Host Tool

Control portal + host daemon for running two apps on an Android phone
(Samsung Galaxy Z Fold3, Termux) as a 24/7 personal cloud host:
**Nifty Analyzer** (:5001) and **AvatarOps** (:8080), exposed through
Cloudflare tunnels, with a GitHub Pages PWA as the control UI.

## Architecture
- **Phone (Termux):** both apps under PRoot Ubuntu, supervised by tmux
  (`scripts/start_services.sh`) or runit (`scripts/android/install-services.sh`),
  `host_daemon.py` (:8088) for telemetry/logs/actions, and
  `scripts/tunnel_watchdog.sh` for tunnel health + endpoint publishing.
- **Tunnels:** Cloudflare **quick tunnels** by default (random URL per
  restart, republished into `endpoints.json`); **named tunnel** supported
  and recommended — see `docs/NAMED-TUNNEL.md`.
- **Portal (GitHub Pages):** `index.html` + sub-pages share ONE logic module,
  `assets/portal-common.js`. Endpoint resolution order is **GitHub Contents
  API → raw file → ./endpoints.json**.

## Security model
- **Why ntfy was demoted (audit C2):** public ntfy topics are world-writable,
  so treating ntfy messages as endpoint truth let anyone redirect portal
  visitors to a phishing clone. The portal no longer resolves endpoints from
  ntfy at all; GitHub is the source of truth. ntfy remains only as an
  *optional* watchdog broadcast/alert hint, and only when a private topic is
  configured in `scripts/local.env` (git-ignored; see `local.env.example`).
- **Daemon actions** (`POST /api/host/action`) require `X-Host-Token`
  matching `HOST_DAEMON_TOKEN`; if the token is unset the daemon fails
  closed (503) and executes nothing. The daemon binds `127.0.0.1` by default
  (`HOST_DAEMON_BIND`) and CORS is a single configured origin
  (`HOST_DAEMON_CORS_ORIGIN`), never `*`.
- **Telemetry is honest:** unreadable sensors produce `null` + a `sources`
  map, never invented numbers.
- Endpoint URLs are allowlist-validated (`https:` + `*.trycloudflare.com`,
  the configured domain, or loopback) and rendered with `textContent` only.

## Modes
| | Quick (default) | Named (`TUNNEL_MODE=named`) |
|---|---|---|
| Hostnames | new random URL per restart | fixed, on your domain |
| endpoints.json churn | watchdog republishes + git-pushes | watchdog skips publishing |
| Setup | none | domain + `cloudflared tunnel create` (`docs/NAMED-TUNNEL.md`) |

## Setup
Full phone setup: `docs/ANDROID-HOST.md`. In short: F-Droid Termux +
Termux:API + Termux:Boot, packages, `scripts/install.sh`, battery/Doze
exemptions, Phantom Process Killer ADB fix, runit units, Termux:Boot script.

## Tests
```bash
./run_all_tests.sh
```
Runs the Python unittest suites (daemon + watchdog probe regression),
`bash -n` on every script, `node --check` + `node test_portal_common.js`,
`py_compile`, and JSON validation. CI does the same
(`.github/workflows/tests.yml`), and a scheduled workflow probes the live
host (`.github/workflows/healthcheck.yml`) — it alerts on downtime but, by
design, cannot wake a sleeping phone.
