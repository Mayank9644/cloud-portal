#!/data/data/com.termux/files/usr/bin/bash
export PATH=/data/data/com.termux/files/usr/bin:$PATH
LOG_DIR=/data/data/com.termux/files/home/apps/logs
PORTAL_DIR=/data/data/com.termux/files/home/apps/cloud-portal
REALTIME_URL="https://ntfy.sh/fincept_cloudhost_endpoints_9644"

mkdir -p "$LOG_DIR"
echo "[$(date)] Autonomous Self-Healing Tunnel Watchdog initialized." >> "$LOG_DIR/watchdog.log"

# Publish current endpoints on startup
if [ -f "$PORTAL_DIR/endpoints.json" ]; then
    curl -s -m 5 -X POST -d @"$PORTAL_DIR/endpoints.json" "$REALTIME_URL" >/dev/null 2>&1 || true
fi

FAIL_NIFTY=0
FAIL_AVATAR=0
LAST_RECYCLE_TIME=$(date +%s)
COOLDOWN_SECONDS=45

probe_status_code() {
    local target_url="$1"
    local code
    code=$(curl -s -o /dev/null -m 7 -w "%{http_code}" "$target_url" 2>/dev/null || echo "000")
    if [ -z "$code" ]; then
        code="000"
    fi
    echo "$code"
}

while true; do
    NOW=$(date +%s)

    # 1. Read currently published URLs from endpoints.json
    PUB_AVATAR=$(grep -oE '"avatar_ops_url": *"[^"]+"' "$PORTAL_DIR/endpoints.json" 2>/dev/null | cut -d'"' -f4)
    PUB_NIFTY=$(grep -oE '"nifty_analyzer_url": *"[^"]+"' "$PORTAL_DIR/endpoints.json" 2>/dev/null | cut -d'"' -f4)

    # 2. Extract latest URLs from runner logs
    CUR_AVATAR=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" "$LOG_DIR/tunnel-avatar.log" 2>/dev/null | tail -n 1)
    CUR_NIFTY=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" "$LOG_DIR/tunnel-nifty.log" 2>/dev/null | tail -n 1)

    # 3. If URLs have changed in the logs, immediately sync & broadcast
    if [ -n "$CUR_NIFTY" ] && [ -n "$CUR_AVATAR" ]; then
        if [ "$CUR_NIFTY" != "$PUB_NIFTY" ] || [ "$CUR_AVATAR" != "$PUB_AVATAR" ]; then
            echo "[$(date)] [Watcher-AutoSync] URL change detected: Nifty: $PUB_NIFTY -> $CUR_NIFTY | Avatar: $PUB_AVATAR -> $CUR_AVATAR" >> "$LOG_DIR/watchdog.log"

            cd "$PORTAL_DIR" || continue
            git fetch origin main --quiet 2>/dev/null || true
            git reset --hard origin/main --quiet 2>/dev/null || true

            cat << 'JSON_EOF' > "$PORTAL_DIR/endpoints.json"
{
  "avatar_ops_url": "__AVATAR__",
  "nifty_analyzer_url": "__NIFTY__",
  "host": "Samsung Galaxy Z Fold3 5G (SM-F926N) • 24/7 Cloud Host",
  "updated_at": "__TIMESTAMP__"
}
JSON_EOF
            sed -i "s|__AVATAR__|$CUR_AVATAR|g" "$PORTAL_DIR/endpoints.json"
            sed -i "s|__NIFTY__|$CUR_NIFTY|g" "$PORTAL_DIR/endpoints.json"
            sed -i "s|__TIMESTAMP__|$(date '+%Y-%m-%d %H:%M:%S %Z')|g" "$PORTAL_DIR/endpoints.json"

            # Broadcast to Realtime SSE Push Stream (0ms latency to browser)
            curl -s -m 5 -X POST -d @"$PORTAL_DIR/endpoints.json" "$REALTIME_URL" >/dev/null 2>&1 || true

            # Push to GitHub
            git config user.name 'Android Cloud Host'
            git config user.email 'mayank9644@users.noreply.github.com'
            git add endpoints.json
            git commit -m "chore(live): auto-update cloudflare tunnel endpoints [skip ci]" 2>/dev/null || true
            git push origin main --quiet 2>/dev/null || true
            echo "[$(date)] [Watcher-AutoSync] Broadcasted to Realtime Channel & pushed to GitHub." >> "$LOG_DIR/watchdog.log"

            # Reset failure counters and give new tunnels time to settle
            FAIL_NIFTY=0
            FAIL_AVATAR=0
            LAST_RECYCLE_TIME=$(date +%s)
            PUB_AVATAR="$CUR_AVATAR"
            PUB_NIFTY="$CUR_NIFTY"
        fi
    fi

    # 4. Proactive Edge Health Check (only if device has internet and cooldown elapsed)
    TIME_SINCE_RECYCLE=$((NOW - LAST_RECYCLE_TIME))

    if [ "$TIME_SINCE_RECYCLE" -ge "$COOLDOWN_SECONDS" ]; then
        if curl -s -m 3 https://1.1.1.1 >/dev/null 2>&1; then
            # Check for Cloudflare 429 rate limit first (recent tail only)
            if (tail -n 15 "$LOG_DIR/tunnel-avatar.log" 2>/dev/null | grep -q "status 429") || (tail -n 15 "$LOG_DIR/tunnel-nifty.log" 2>/dev/null | grep -q "status 429"); then
                echo "[$(date)] [Watcher] Rate limit (429) active in logs. Pausing probe for 30s..." >> "$LOG_DIR/watchdog.log"
                sleep 30
                continue
            fi

            # Check Nifty tunnel
            CODE_N="200"
            if [ -n "$PUB_NIFTY" ]; then
                CODE_N=$(probe_status_code "$PUB_NIFTY/health")
                # Any code < 500 (200, 302, 404, etc.) means edge reached origin!
                if [ "$CODE_N" -ge 500 ] || [ "$CODE_N" = "000" ]; then
                    FAIL_NIFTY=$((FAIL_NIFTY + 1))
                else
                    FAIL_NIFTY=0
                fi
            fi

            # Check AvatarOps tunnel
            CODE_A="200"
            if [ -n "$PUB_AVATAR" ]; then
                CODE_A=$(probe_status_code "$PUB_AVATAR/")
                if [ "$CODE_A" -ge 500 ] || [ "$CODE_A" = "000" ]; then
                    FAIL_AVATAR=$((FAIL_AVATAR + 1))
                else
                    FAIL_AVATAR=0
                fi
            fi

            # Check log-level fatal disconnects
            EDGE_ERROR=0
            if grep -q -E "Unauthorized: Tunnel not found|connection with edge closed|Error shutting down control stream" "$LOG_DIR/tunnel-nifty.log" 2>/dev/null; then
                EDGE_ERROR=1
            fi
            if grep -q -E "Unauthorized: Tunnel not found|connection with edge closed|Error shutting down control stream" "$LOG_DIR/tunnel-avatar.log" 2>/dev/null; then
                EDGE_ERROR=1
            fi

            # Require 2 consecutive probe failures or direct edge closure to trigger self-healing recycle
            if [ "$FAIL_NIFTY" -ge 2 ] || [ "$FAIL_AVATAR" -ge 2 ] || [ "$EDGE_ERROR" -eq 1 ]; then
                echo "[$(date)] [Watcher-Healer] Edge disconnect confirmed (Nifty code: $CODE_N [fails: $FAIL_NIFTY], Avatar code: $CODE_A [fails: $FAIL_AVATAR], EdgeErr: $EDGE_ERROR). Auto-recycling tunnels..." >> "$LOG_DIR/watchdog.log"

                killall -9 cloudflared 2>/dev/null || pkill -9 -x cloudflared 2>/dev/null || true
                > "$LOG_DIR/tunnel-nifty.log"
                > "$LOG_DIR/tunnel-avatar.log"
                LAST_RECYCLE_TIME=$(date +%s)
                FAIL_NIFTY=0
                FAIL_AVATAR=0

                # Actively wait up to 30s for new tunnels to provision
                for i in $(seq 1 15); do
                    sleep 2
                    C_A=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" "$LOG_DIR/tunnel-avatar.log" 2>/dev/null | tail -n 1)
                    C_N=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" "$LOG_DIR/tunnel-nifty.log" 2>/dev/null | tail -n 1)
                    if [ -n "$C_A" ] && [ -n "$C_N" ]; then
                        echo "[$(date)] [Watcher-Healer] New tunnels acquired in $((i * 2))s: Nifty: $C_N | Avatar: $C_A" >> "$LOG_DIR/watchdog.log"
                        break
                    fi
                done
            fi
        fi
    fi

    # 5. Local Service Liveness Probes
    if ! curl -s -m 2 http://127.0.0.1:8088/health >/dev/null 2>&1; then
        echo "[$(date)] [Probe] host_daemon not running, starting on :8088..." >> "$LOG_DIR/watchdog.log"
        pkill -f host_daemon.py 2>/dev/null || true
        python3 /data/data/com.termux/files/home/apps/cloud-portal/host_daemon.py >> "$LOG_DIR/host_daemon.log" 2>&1 &
    fi
    if ! curl -s -m 3 http://127.0.0.1:5001/health >/dev/null 2>&1; then
        if ! pgrep -f gunicorn >/dev/null 2>&1; then
            echo "[$(date)] [Probe] Nifty gunicorn not running, clearing port 5001..." >> "$LOG_DIR/watchdog.log"
            pkill -9 -f gunicorn 2>/dev/null || true
        fi
    fi

    sleep 10
done
