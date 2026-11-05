#!/data/data/com.termux/files/usr/bin/bash
# Quick-tunnel runner for host daemon (:8088). Supervised loop with exponential
# backoff and log rotation. Cmdline contains 127.0.0.1:8088.
set -u
export PATH=/data/data/com.termux/files/usr/bin:$PATH
LOG_FILE="${TUNNEL_DAEMON_LOG:-/data/data/com.termux/files/home/apps/logs/tunnel-daemon.log}"
mkdir -p "$(dirname "$LOG_FILE")"
rotate_log() {
  if [ -f "$LOG_FILE" ]; then
    local sz
    sz=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$sz" -gt 5242880 ]; then mv -f "$LOG_FILE" "$LOG_FILE.1"; : > "$LOG_FILE"; fi
  fi
}
BACKOFF=3
while true; do
    rotate_log
    echo "[$(date)] Starting tunnel-daemon..." >> "$LOG_FILE"
    START_TS=$(date +%s)
    cloudflared tunnel --no-autoupdate --protocol http2 --logfile "$LOG_FILE.cf" --url http://127.0.0.1:8088 >> "$LOG_FILE" 2>&1
    END_TS=$(date +%s)
    ELAPSED=$((END_TS - START_TS))
    if [ "$ELAPSED" -gt 120 ]; then BACKOFF=3; fi
    if tail -n 50 "$LOG_FILE" 2>/dev/null | grep -q "status 429"; then
        DELAY=$BACKOFF; if [ "$DELAY" -lt 30 ]; then DELAY=30; fi
        echo "[$(date)] [tunnel-daemon] Rate limited (429). Sleeping ${DELAY}s..." >> "$LOG_FILE"
    else
        DELAY=$BACKOFF
        echo "[$(date)] [tunnel-daemon] Exited after ${ELAPSED}s. Sleeping ${DELAY}s..." >> "$LOG_FILE"
    fi
    sleep "$DELAY"
    BACKOFF=$((BACKOFF * 2)); if [ "$BACKOFF" -gt 60 ]; then BACKOFF=60; fi
done
