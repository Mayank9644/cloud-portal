#!/data/data/com.termux/files/usr/bin/bash
export PATH=/data/data/com.termux/files/usr/bin:$PATH
export TMPDIR=/data/data/com.termux/files/usr/tmp
mkdir -p /data/data/com.termux/files/home/apps/logs

termux-wake-lock 2>/dev/null || true
pgrep sshd >/dev/null || sshd

echo "[$(date)] Initializing 24/7 Cloud Host Supervisor on Samsung Galaxy Z Fold3..."

# Terminate previous tmux sessions & stale processes
tmux kill-session -t cloudhost 2>/dev/null || true
pkill -9 -f 'gunicorn' 2>/dev/null || true
pkill -9 -f 'server.py' 2>/dev/null || true
killall -9 cloudflared 2>/dev/null || pkill -9 -x cloudflared 2>/dev/null || true
pkill -9 -f 'tunnel_watchdog' 2>/dev/null || true
pkill -9 -f 'github_auto_deploy' 2>/dev/null || true
pkill -9 -f 'host_daemon' 2>/dev/null || true
sleep 1

> /data/data/com.termux/files/home/apps/logs/tunnel-avatar.log
> /data/data/com.termux/files/home/apps/logs/tunnel-nifty.log

# Window 0: Avatar Ops (:8080)
tmux new-session -d -s cloudhost -n avatar-ops 'while true; do echo "[$(date)] Starting AvatarOps..." >> /data/data/com.termux/files/home/apps/logs/avatar-ops.log; proot-distro login ubuntu --shared-tmp -- bash -c "cd /data/data/com.termux/files/home/apps/avatar-ops && AVATAR_OPS_PORT=8080 ./.venv_linux/bin/python3 server.py" >> /data/data/com.termux/files/home/apps/logs/avatar-ops.log 2>&1; sleep 2; done'

# Window 1: Nifty Analyzer (:5001)
tmux new-window -t cloudhost:1 -n nifty-analyzer 'while true; do echo "[$(date)] Starting Nifty Analyzer..." >> /data/data/com.termux/files/home/apps/logs/nifty-analyzer.log; proot-distro login ubuntu --shared-tmp -- bash -c "cd /data/data/com.termux/files/home/apps/nifty-analyzer && ./.venv_linux/bin/gunicorn app:app --workers 1 --threads 8 --timeout 120 --bind 0.0.0.0:5001" >> /data/data/com.termux/files/home/apps/logs/nifty-analyzer.log 2>&1; sleep 2; done'

# Window 2: GitHub Auto-Deploy
tmux new-window -t cloudhost:2 -n github-sync 'while true; do bash /data/data/com.termux/files/home/apps/github_auto_deploy.sh >> /data/data/com.termux/files/home/apps/logs/github_sync.log 2>&1; sleep 10; done'

# Window 3: Cloudflare Tunnel Avatar (:8080)
tmux new-window -t cloudhost:3 -n tunnel-avatar 'bash /data/data/com.termux/files/home/apps/run_tunnel_avatar.sh'

# Window 4: Cloudflare Tunnel Nifty (:5001)
tmux new-window -t cloudhost:4 -n tunnel-nifty 'bash /data/data/com.termux/files/home/apps/run_tunnel_nifty.sh'

# Window 5: Continuous Tunnel Watchdog & Self-Healing Endpoint Syncer
tmux new-window -t cloudhost:5 -n watchdog 'bash /data/data/com.termux/files/home/apps/tunnel_watchdog.sh'

echo "[$(date)] Successfully started 6 tmux windows for cloudhost session."
