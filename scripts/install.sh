#!/data/data/com.termux/files/usr/bin/bash
# Install the repo's scripts + daemon into ~/apps/cloud-portal so the phone
# runs exactly what is in Git (audit M-9). Idempotent.
set -eu
export PATH=/data/data/com.termux/files/usr/bin:${PATH:-}
APP_DIR="${APP_DIR:-$HOME/apps/cloud-portal}"
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$APP_DIR/scripts" "$APP_DIR/scripts/android" "$HOME/apps/logs" "$HOME/apps"
cp "$SRC_DIR/host_daemon.py" "$APP_DIR/host_daemon.py"
cp "$SRC_DIR/scripts/"*.sh "$APP_DIR/scripts/"
cp "$SRC_DIR/scripts/android/"*.sh "$APP_DIR/scripts/android/" 2>/dev/null || true
# Backwards-compatible flat copies the tmux windows have always referenced:
cp "$SRC_DIR/scripts/tunnel_watchdog.sh" "$HOME/apps/tunnel_watchdog.sh"
cp "$SRC_DIR/scripts/run_tunnel_avatar.sh" "$HOME/apps/run_tunnel_avatar.sh"
cp "$SRC_DIR/scripts/run_tunnel_nifty.sh" "$HOME/apps/run_tunnel_nifty.sh"
cp "$SRC_DIR/scripts/github_auto_deploy.sh" "$HOME/apps/github_auto_deploy.sh"
cp "$SRC_DIR/scripts/start_services.sh" "$HOME/apps/start_services.sh"
if [ ! -f "$APP_DIR/scripts/local.env" ] && [ -f "$SRC_DIR/scripts/local.env.example" ]; then
    cp "$SRC_DIR/scripts/local.env.example" "$APP_DIR/scripts/local.env"
    echo "Created $APP_DIR/scripts/local.env from example - edit it (private ntfy topic etc.), it is git-ignored."
fi
chmod +x "$APP_DIR/scripts/"*.sh "$HOME/apps/"*.sh 2>/dev/null || true
echo "Installed cloud-portal scripts to $APP_DIR (APP_DIR=$APP_DIR)"
