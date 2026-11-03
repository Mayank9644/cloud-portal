#!/data/data/com.termux/files/usr/bin/bash
# Named-tunnel runner (audit H-1 / P0-1). ONE cloudflared process serves all
# hostnames from cloudflared/config.yml. Supervised loop with backoff.
set -u
export PATH=/data/data/com.termux/files/usr/bin:${PATH:-}
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
LOG_FILE="${NAMED_TUNNEL_LOG:-$HOME_DIR/apps/logs/tunnel-named.log}"
CONFIG="${CLOUDFLARED_CONFIG:-$HOME_DIR/apps/cloud-portal/cloudflared/config.yml}"
mkdir -p "$(dirname "$LOG_FILE")"
BACKOFF=3
while true; do
    sz=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$sz" -gt 5242880 ]; then mv -f "$LOG_FILE" "$LOG_FILE.1"; : > "$LOG_FILE"; fi
    echo "[$(date)] Starting named tunnel with config $CONFIG..." >> "$LOG_FILE"
    START_TS=$(date +%s)
    cloudflared tunnel --config "$CONFIG" run >> "$LOG_FILE" 2>&1
    ELAPSED=$(( $(date +%s) - START_TS ))
    if [ "$ELAPSED" -gt 120 ]; then BACKOFF=3; fi
    echo "[$(date)] Named tunnel exited after ${ELAPSED}s; sleeping ${BACKOFF}s" >> "$LOG_FILE"
    sleep "$BACKOFF"
    BACKOFF=$((BACKOFF * 2)); if [ "$BACKOFF" -gt 60 ]; then BACKOFF=60; fi
done
