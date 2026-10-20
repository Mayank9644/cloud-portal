#!/data/data/com.termux/files/usr/bin/bash
# Cloud Host supervisor (tmux). Fixed per audit H-2, H-3, M-6, M-7:
# - verifies required binaries and FAILS LOUDLY instead of printing a
#   false success message;
# - window 2 is the host daemon (it was referenced by the spec but never
#   started); github-sync moves to its real committed script;
# - app wrapper loops use capped exponential backoff, not a fixed 2s spin;
# - sshd only when START_SSHD=1;
# - TUNNEL_MODE=named starts ONE named-tunnel window instead of two
#   quick-tunnel windows.
set -u
export PATH=/data/data/com.termux/files/usr/bin:${PATH:-}
export TMPDIR=/data/data/com.termux/files/usr/tmp
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
APPS="$HOME_DIR/apps"
LOGS="$APPS/logs"
TUNNEL_MODE="${TUNNEL_MODE:-quick}"
mkdir -p "$LOGS"

missing=0
for bin in tmux python3 cloudflared proot-distro curl git; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "ERROR: required binary not found: $bin" >&2
        missing=1
    fi
done
if [ "$missing" -ne 0 ]; then
    echo "ERROR: refusing to start with missing dependencies (see docs/ANDROID-HOST.md)." >&2
    exit 1
fi

if command -v termux-wake-lock >/dev/null 2>&1; then termux-wake-lock || true; fi
if [ "${START_SSHD:-0}" = "1" ]; then
    pgrep sshd >/dev/null 2>&1 || sshd || echo "WARN: sshd failed to start" >&2
fi

echo "[$(date)] Initializing 24/7 Cloud Host Supervisor on Samsung Galaxy Z Fold3 (mode=$TUNNEL_MODE)..."

# Terminate the previous session and ONLY our own stale processes (narrow
# patterns, audit M-7).
tmux kill-session -t cloudhost 2>/dev/null || true
pkill -9 -f "apps/nifty-analyzer.*gunicorn|gunicorn app:app" 2>/dev/null || true
pkill -9 -f "apps/avatar-ops.*server\.py" 2>/dev/null || true
pkill -9 -f "cloud-portal/host_daemon.py" 2>/dev/null || true
pkill -9 -f "apps/tunnel_watchdog.sh" 2>/dev/null || true
pkill -9 -f "apps/github_auto_deploy.sh" 2>/dev/null || true
sleep 1

# Backoff wrapper injected into app windows: 2s -> 4 -> ... -> 30s cap.
BACKOFF_SNIPPET='b=2; while true; do %CMD% >> %LOG% 2>&1; echo "[$(date)] exited; restarting in ${b}s" >> %LOG%; sleep $b; b=$((b*2)); if [ $b -gt 30 ]; then b=30; fi; done'

# Window 0: Avatar Ops (:8080)
AVATAR_CMD=$(printf '%s' "$BACKOFF_SNIPPET" | sed "s|%CMD%|proot-distro login ubuntu --shared-tmp -- bash -c \"cd $APPS/avatar-ops \&\& AVATAR_OPS_PORT=8080 ./.venv_linux/bin/python3 server.py\"|; s|%LOG%|$LOGS/avatar-ops.log|g")
tmux new-session -d -s cloudhost -n avatar-ops "$AVATAR_CMD"

# Window 1: Nifty Analyzer (:5001)
NIFTY_CMD=$(printf '%s' "$BACKOFF_SNIPPET" | sed "s|%CMD%|proot-distro login ubuntu --shared-tmp -- bash -c \"cd $APPS/nifty-analyzer \&\& ./.venv_linux/bin/gunicorn app:app --workers 1 --threads 8 --timeout 120 --bind 0.0.0.0:5001\"|; s|%LOG%|$LOGS/nifty-analyzer.log|g")
tmux new-window -t cloudhost:1 -n nifty-analyzer "$NIFTY_CMD"

# Window 2: Host Daemon (:8088) — audit H-2: it exists and is supervised now.
tmux new-window -t cloudhost:2 -n host-daemon "while true; do python3 $APPS/cloud-portal/host_daemon.py >> $LOGS/host_daemon.log 2>&1; sleep 5; done"

# Window 3: GitHub Auto-Deploy (real committed script, audit M-9)
tmux new-window -t cloudhost:3 -n github-sync "while true; do bash $APPS/cloud-portal/scripts/github_auto_deploy.sh >> $LOGS/github_sync.log 2>&1; sleep 5; done"

if [ "$TUNNEL_MODE" = "named" ]; then
    # Windows 4: ONE named tunnel for all hostnames.
    tmux new-window -t cloudhost:4 -n tunnel-named "bash $APPS/cloud-portal/scripts/run_named_tunnel.sh"
    NEXT=5
else
    tmux new-window -t cloudhost:4 -n tunnel-avatar "bash $APPS/cloud-portal/scripts/run_tunnel_avatar.sh"
    tmux new-window -t cloudhost:5 -n tunnel-nifty "bash $APPS/cloud-portal/scripts/run_tunnel_nifty.sh"
    NEXT=6
fi

# Last window: watchdog
tmux new-window -t cloudhost:$NEXT -n watchdog "bash $APPS/cloud-portal/scripts/tunnel_watchdog.sh"

# Verify the session really exists before claiming success.
if tmux has-session -t cloudhost 2>/dev/null; then
    echo "[$(date)] cloudhost session started: $(tmux list-windows -t cloudhost | wc -l) windows."
else
    echo "ERROR: tmux session cloudhost did not start." >&2
    exit 1
fi
