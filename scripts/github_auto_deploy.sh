#!/data/data/com.termux/files/usr/bin/bash
# GitHub auto-deploy: pull the app repos (and portal) with ff-only pulls.
# Committed for real (audit M-9): start_services.sh window 2 runs this file.
# One pass per invocation; start_services.sh / runit loops it, and failures
# back off instead of spinning.
set -u
export PATH=/data/data/com.termux/files/usr/bin:${PATH:-}
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
LOG_DIR="${LOG_DIR:-$HOME_DIR/apps/logs}"
mkdir -p "$LOG_DIR"
INTERVAL="${GITHUB_SYNC_INTERVAL:-60}"
FAIL_FILE="$LOG_DIR/.github_sync_backoff"
log_msg() { echo "[$(date)] [github-sync] $*" >> "$LOG_DIR/github_sync.log"; }
backoff_sleep() {
    local fails=0
    if [ -f "$FAIL_FILE" ]; then fails=$(cat "$FAIL_FILE" 2>/dev/null || echo 0); fi
    fails=$((fails + 1)); echo "$fails" > "$FAIL_FILE"
    local delay=$((INTERVAL * fails)); if [ "$delay" -gt 600 ]; then delay=600; fi
    log_msg "failure #$fails; backing off ${delay}s"
    sleep "$delay"
}
any_fail=0
for repo in "$HOME_DIR/apps/cloud-portal" "$HOME_DIR/apps/nifty-analyzer" "$HOME_DIR/apps/avatar-ops"; do
    if [ -d "$repo/.git" ]; then
        if git -C "$repo" pull --ff-only --quiet >> "$LOG_DIR/github_sync.log" 2>&1; then
            log_msg "pulled $repo"
        else
            log_msg "ERROR: git pull --ff-only failed in $repo"
            any_fail=1
        fi
    fi
done
if [ "$any_fail" -eq 1 ]; then backoff_sleep; exit 1; fi
echo 0 > "$FAIL_FILE"
sleep "$INTERVAL"
