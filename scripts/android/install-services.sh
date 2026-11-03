#!/data/data/com.termux/files/usr/bin/bash
# Create termux-services (runit) units so daemon/watchdog/tunnels are
# supervised OUTSIDE tmux (audit H-3, P0-4). Requires: pkg install termux-services
# (then restart Termux once so runsvdir is running).
set -eu
export PATH=/data/data/com.termux/files/usr/bin:${PATH:-}
PREFIX_DIR="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
APP_DIR="${APP_DIR:-$HOME_DIR/apps/cloud-portal}"
SERVICE_ROOT="$PREFIX_DIR/var/service"
TUNNEL_MODE="${TUNNEL_MODE:-quick}"
if ! command -v sv >/dev/null 2>&1; then
    echo "ERROR: termux-services not installed. Run: pkg install termux-services, restart Termux, re-run this script." >&2
    exit 1
fi
mkdir -p "$HOME_DIR/apps/logs"
make_service() {
    # $1 name, $2 exec line
    local name="$1" line="$2"
    local dir="$SERVICE_ROOT/$name"
    mkdir -p "$dir/log"
    {
        echo '#!/data/data/com.termux/files/usr/bin/sh'
        echo "exec $line 2>&1"
    } > "$dir/run"
    {
        echo '#!/data/data/com.termux/files/usr/bin/sh'
        echo "exec svlogger -t $HOME_DIR/apps/logs/$name"
    } > "$dir/log/run"
    chmod +x "$dir/run" "$dir/log/run"
    echo "created service: $name"
}
make_service cloudhost-daemon "python3 $APP_DIR/host_daemon.py"
make_service cloudhost-watchdog "bash $APP_DIR/scripts/tunnel_watchdog.sh"
if [ "$TUNNEL_MODE" = "named" ]; then
    make_service tunnel-named "bash $APP_DIR/scripts/run_named_tunnel.sh"
else
    make_service tunnel-avatar "bash $APP_DIR/scripts/run_tunnel_avatar.sh"
    make_service tunnel-nifty "bash $APP_DIR/scripts/run_tunnel_nifty.sh"
fi
for svc in cloudhost-daemon cloudhost-watchdog tunnel-nifty tunnel-avatar tunnel-named; do
    if [ -d "$SERVICE_ROOT/$svc" ]; then sv-enable "$svc" 2>/dev/null || true; fi
done
echo "Services installed under $SERVICE_ROOT. Check with: sv status cloudhost-daemon"
