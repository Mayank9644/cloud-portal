#!/data/data/com.termux/files/usr/bin/bash
# Termux:Boot entry point (audit P0-4). Install with:
#   mkdir -p ~/.termux/boot && cp scripts/android/boot-cloudhost.sh ~/.termux/boot/10-cloudhost.sh
# Open the Termux:Boot app once after installing it, or Android will not
# deliver the boot broadcast.
export PATH=/data/data/com.termux/files/usr/bin:${PATH:-}
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
mkdir -p "$HOME_DIR/apps/logs"
termux-wake-lock || true
{
    echo "[$(date)] boot-cloudhost: wake-lock acquired"
    # If termux-services (runit) is installed, enabled services auto-start
    # with Termux; bring them up explicitly as well when sv exists.
    if command -v sv >/dev/null 2>&1; then
        for svc in cloudhost-daemon cloudhost-watchdog tunnel-nifty tunnel-avatar tunnel-named; do
            sv up "$svc" 2>/dev/null || true
        done
        echo "[$(date)] boot-cloudhost: runit services signalled"
    else
        bash "$HOME_DIR/apps/start_services.sh"
        echo "[$(date)] boot-cloudhost: tmux supervisor started"
    fi
} >> "$HOME_DIR/apps/logs/boot.log" 2>&1
