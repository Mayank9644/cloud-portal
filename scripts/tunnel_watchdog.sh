#!/data/data/com.termux/files/usr/bin/bash
# Tunnel watchdog — fixed per audit C3, C4, M-1, M-2, M-6.
#
# C3 fix: probe_status_code captures ONLY curl's -w output. A failed curl
# already prints "000"; there is deliberately NO `|| echo "000"` (that
# produced "000000", which passed as healthy).
# C4 fix: no hard git resets anywhere. Sync uses `git pull --ff-only`,
# checks every exit code, retries a failed push once after a ff-pull, and
# logs ERROR (never success) when the push does not land.
# Recycle policy: ONLY the failing service's cloudflared is recycled, and
# only after failures have spanned >= SUSTAIN_SECONDS (120s).
set -u
export PATH=/data/data/com.termux/files/usr/bin:${PATH:-}

HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
LOG_DIR="${LOG_DIR:-$HOME_DIR/apps/logs}"
PORTAL_DIR="${PORTAL_DIR:-$HOME_DIR/apps/cloud-portal}"
TUNNEL_MODE="${TUNNEL_MODE:-quick}"
SUSTAIN_SECONDS="${SUSTAIN_SECONDS:-120}"
COOLDOWN_SECONDS=45

# Optional local config (git-ignored): NTFY_TOPIC etc. See local.env.example.
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo "$PORTAL_DIR/scripts")"
if [ -f "$SCRIPT_DIR/local.env" ]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/local.env"
fi
NTFY_TOPIC="${NTFY_TOPIC:-}"
if [ -n "$NTFY_TOPIC" ]; then
    REALTIME_URL="https://ntfy.sh/$NTFY_TOPIC"
else
    REALTIME_URL=""
fi

log_msg() {
    echo "[$(date)] $*" >> "$LOG_DIR/watchdog.log"
}

rotate_one() {
    local f="$1" sz
    if [ -f "$f" ]; then
        sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
        if [ "$sz" -gt 5242880 ]; then mv -f "$f" "$f.1"; : > "$f"; fi
    fi
}

rotate_logs() {
    rotate_one "$LOG_DIR/watchdog.log"
    rotate_one "$LOG_DIR/tunnel-avatar.log"
    rotate_one "$LOG_DIR/tunnel-nifty.log"
    rotate_one "$LOG_DIR/host_daemon.log"
    rotate_one "$LOG_DIR/nifty-analyzer.log"
    rotate_one "$LOG_DIR/avatar-ops.log"
}

# --- C3: the probe. Returns exactly "000" on any curl failure. ---
probe_status_code() {
    local target_url="$1"
    local code
    code=$(curl -s -o /dev/null -m 7 -w "%{http_code}" "$target_url" 2>/dev/null)
    if [ -z "$code" ]; then
        code="000"
    fi
    echo "$code"
}

is_failure_code() {
    # failure = 000 (unreachable) or any 5xx
    local code="$1"
    case "$code" in
        000) return 0 ;;
    esac
    if [ "$code" -ge 500 ] 2>/dev/null; then return 0; fi
    return 1
}

recycle_service() {
    # Recycle ONLY this service's cloudflared: its cmdline carries its port.
    local svc="$1" port
    if [ "$svc" = "nifty" ]; then port=5001; else port=8080; fi
    log_msg "[Watcher-Healer] Recycling ONLY the $svc tunnel (port $port) after sustained failure."
    pkill -f "127.0.0.1:$port" 2>/dev/null || true
    : > "$LOG_DIR/tunnel-$svc.log"
}

publish_endpoints() {
    # $1 = avatar url, $2 = nifty url. Returns 0 only on a VERIFIED push.
    local cur_avatar="$1" cur_nifty="$2"
    local ts host_daemon_line=""
    ts=$(date '+%Y-%m-%d %H:%M:%S %Z')
    if grep -q '"host_daemon_url"' "$PORTAL_DIR/endpoints.json" 2>/dev/null; then
        host_daemon_line=$(grep -oE '"host_daemon_url": *"[^"]+"' "$PORTAL_DIR/endpoints.json" | head -1)
    fi
    cd "$PORTAL_DIR" || { log_msg "[Watcher-AutoSync] ERROR: cannot cd to $PORTAL_DIR"; return 1; }
    if ! git pull --ff-only --quiet; then
        log_msg "[Watcher-AutoSync] ERROR: git pull --ff-only failed; skipping publish this cycle."
        return 1
    fi
    {
        echo "{"
        echo "  \"avatar_ops_url\": \"$cur_avatar\","
        echo "  \"nifty_analyzer_url\": \"$cur_nifty\","
        if [ -n "$host_daemon_line" ]; then echo "  $host_daemon_line,"; fi
        echo "  \"host\": \"Samsung Galaxy Z Fold3 5G (SM-F926N) - 24/7 Cloud Host\","
        echo "  \"updated_at\": \"$ts\""
        echo "}"
    } > "$PORTAL_DIR/endpoints.json"

    # ntfy is an OPTIONAL hint channel only, and only when a (private) topic
    # is configured via local.env / NTFY_TOPIC. GitHub is the source of truth.
    if [ -n "$REALTIME_URL" ]; then
        curl -s -m 5 -X POST -d @"$PORTAL_DIR/endpoints.json" "$REALTIME_URL" >/dev/null 2>&1 || log_msg "[Watcher-AutoSync] WARN: ntfy broadcast failed (non-fatal)."
    else
        log_msg "[Watcher-AutoSync] No NTFY_TOPIC configured; skipping ntfy broadcast."
    fi

    git config user.name 'Android Cloud Host'
    git config user.email 'mayank9644@users.noreply.github.com'
    git add endpoints.json || { log_msg "[Watcher-AutoSync] ERROR: git add failed"; return 1; }
    if ! git commit -m "chore(live): auto-update cloudflare tunnel endpoints [skip ci]" --quiet; then
        log_msg "[Watcher-AutoSync] ERROR: git commit failed"
        return 1
    fi
    if git push origin main --quiet; then
        log_msg "[Watcher-AutoSync] Pushed endpoints to GitHub (verified push)."
        return 0
    fi
    log_msg "[Watcher-AutoSync] ERROR: git push failed; retrying once after ff-pull."
    git pull --ff-only --quiet || true
    if git push origin main --quiet; then
        log_msg "[Watcher-AutoSync] Pushed endpoints to GitHub on retry (verified push)."
        return 0
    fi
    log_msg "[Watcher-AutoSync] ERROR: git push failed after retry. Endpoints NOT published."
    return 1
}

main_loop() {
    mkdir -p "$LOG_DIR"
    log_msg "Autonomous Self-Healing Tunnel Watchdog initialized (mode=$TUNNEL_MODE)."
    FAIL_SINCE_NIFTY=0
    FAIL_SINCE_AVATAR=0
    LAST_RECYCLE_TIME=0

    if [ "$TUNNEL_MODE" = "named" ]; then
        log_msg "named mode: fixed hostnames - watchdog skips endpoint publishing."
    fi

    while true; do
        NOW=$(date +%s)
        rotate_logs
        touch "$LOG_DIR/watchdog.heartbeat" 2>/dev/null || true

        if [ "$TUNNEL_MODE" != "named" ]; then
            PUB_AVATAR=$(grep -oE '"avatar_ops_url": *"[^"]+"' "$PORTAL_DIR/endpoints.json" 2>/dev/null | cut -d'"' -f4)
            PUB_NIFTY=$(grep -oE '"nifty_analyzer_url": *"[^"]+"' "$PORTAL_DIR/endpoints.json" 2>/dev/null | cut -d'"' -f4)
            CUR_AVATAR=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" "$LOG_DIR/tunnel-avatar.log" 2>/dev/null | tail -n 1)
            CUR_NIFTY=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" "$LOG_DIR/tunnel-nifty.log" 2>/dev/null | tail -n 1)

            if [ -n "$CUR_NIFTY" ] && [ -n "$CUR_AVATAR" ]; then
                if [ "$CUR_NIFTY" != "$PUB_NIFTY" ] || [ "$CUR_AVATAR" != "$PUB_AVATAR" ]; then
                    log_msg "[Watcher-AutoSync] URL change detected: Nifty: $PUB_NIFTY -> $CUR_NIFTY | Avatar: $PUB_AVATAR -> $CUR_AVATAR"
                    if publish_endpoints "$CUR_AVATAR" "$CUR_NIFTY"; then
                        FAIL_SINCE_NIFTY=0; FAIL_SINCE_AVATAR=0
                        LAST_RECYCLE_TIME=$(date +%s)
                    else
                        log_msg "[Watcher-AutoSync] ERROR: publish failed; will retry next loop."
                    fi
                fi
            fi

            # Edge health, gated by cooldown and internet reachability.
            if [ $((NOW - LAST_RECYCLE_TIME)) -ge $COOLDOWN_SECONDS ]; then
                if curl -s -m 3 https://1.1.1.1 >/dev/null 2>&1; then
                    if (tail -n 50 "$LOG_DIR/tunnel-avatar.log" 2>/dev/null | grep -q "status 429") || (tail -n 50 "$LOG_DIR/tunnel-nifty.log" 2>/dev/null | grep -q "status 429"); then
                        log_msg "[Watcher] Rate limit (429) in recent logs. Pausing probe 30s."
                        sleep 30
                        continue
                    fi
                    # Per-service probes + per-service edge-error tails (M-2).
                    for svc in nifty avatar; do
                        if [ "$svc" = "nifty" ]; then url="$PUB_NIFTY"; path="/health"; else url="$PUB_AVATAR"; path="/"; fi
                        code="200"
                        if [ -n "$url" ]; then code=$(probe_status_code "$url$path"); fi
                        edge=0
                        if tail -n 100 "$LOG_DIR/tunnel-$svc.log" 2>/dev/null | grep -q -E "Unauthorized: Tunnel not found|connection with edge closed|Error shutting down control stream"; then
                            edge=1
                        fi
                        failed=0
                        if is_failure_code "$code" || [ "$edge" -eq 1 ]; then failed=1; fi
                        if [ "$svc" = "nifty" ]; then
                            if [ "$failed" -eq 1 ]; then
                                if [ "$FAIL_SINCE_NIFTY" -eq 0 ]; then FAIL_SINCE_NIFTY=$NOW; fi
                                if [ $((NOW - FAIL_SINCE_NIFTY)) -ge "$SUSTAIN_SECONDS" ]; then
                                    recycle_service nifty; FAIL_SINCE_NIFTY=0; LAST_RECYCLE_TIME=$(date +%s)
                                fi
                            else
                                FAIL_SINCE_NIFTY=0
                            fi
                        else
                            if [ "$failed" -eq 1 ]; then
                                if [ "$FAIL_SINCE_AVATAR" -eq 0 ]; then FAIL_SINCE_AVATAR=$NOW; fi
                                if [ $((NOW - FAIL_SINCE_AVATAR)) -ge "$SUSTAIN_SECONDS" ]; then
                                    recycle_service avatar; FAIL_SINCE_AVATAR=0; LAST_RECYCLE_TIME=$(date +%s)
                                fi
                            else
                                FAIL_SINCE_AVATAR=0
                            fi
                        fi
                    done
                fi
            fi
        fi

        # Local liveness (all modes).
        if ! curl -s -m 2 http://127.0.0.1:8088/health >/dev/null 2>&1; then
            log_msg "[Probe] host_daemon not running, starting on :8088..."
            pkill -f "cloud-portal/host_daemon.py" 2>/dev/null || true
            python3 "$PORTAL_DIR/host_daemon.py" >> "$LOG_DIR/host_daemon.log" 2>&1 &
        fi
        if ! curl -s -m 3 http://127.0.0.1:5001/health >/dev/null 2>&1; then
            log_msg "[Probe] Nifty :5001/health not responding (supervisor loop owns restart)."
        fi
        if ! curl -s -m 3 http://127.0.0.1:8080/ >/dev/null 2>&1; then
            log_msg "[Probe] AvatarOps :8080 not responding (supervisor loop owns restart)."
        fi

        sleep 10
    done
}

# Run the loop only when executed, not when sourced (tests source this file
# to exercise probe_status_code — the C3 regression test).
if [ "${WATCHDOG_SOURCE_ONLY:-0}" != "1" ]; then
    main_loop
fi
