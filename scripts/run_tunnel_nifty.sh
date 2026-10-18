#!/data/data/com.termux/files/usr/bin/bash
export PATH=/data/data/com.termux/files/usr/bin:$PATH
LOG_FILE="/data/data/com.termux/files/home/apps/logs/tunnel-nifty.log"

while true; do
    echo "[$(date)] Starting tunnel-nifty..." >> "$LOG_FILE"
    START_TS=$(date +%s)
    /data/data/com.termux/files/usr/bin/cloudflared tunnel --no-autoupdate --protocol http2 --url http://127.0.0.1:5001 >> "$LOG_FILE" 2>&1
    END_TS=$(date +%s)
    ELAPSED=$((END_TS - START_TS))
    
    if grep -q "status 429" "$LOG_FILE" 2>/dev/null; then
        echo "[$(date)] [tunnel-nifty] Rate limited (429). Sleeping 30s..." >> "$LOG_FILE"
        sleep 30
    elif [ "$ELAPSED" -lt 10 ]; then
        echo "[$(date)] [tunnel-nifty] Exited quickly in ${ELAPSED}s. Sleeping 15s..." >> "$LOG_FILE"
        sleep 15
    else
        sleep 3
    fi
done
