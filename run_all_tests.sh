#!/usr/bin/env bash
# Run every check for this repo. Exits non-zero if anything fails.
set -u
cd "$(dirname "$0")"
FAIL=0
step() { echo; echo "=== $* ==="; }

step "python unittest (daemon + watchdog probe)"
python3 -m unittest discover -v 2>&1 | tail -40
if [ "${PIPESTATUS[0]}" -ne 0 ]; then FAIL=1; fi

step "bash -n on all shell scripts"
for f in $(find . -name "*.sh" -not -path "./.git/*"); do
    if bash -n "$f"; then echo "ok $f"; else echo "FAIL $f"; FAIL=1; fi
done

step "shellcheck (if available)"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck scripts/*.sh scripts/android/*.sh run_all_tests.sh || FAIL=1
else
    echo "shellcheck not installed - skipped (manual shell review in audit)"
fi

step "node --check JS"
for f in sw.js assets/portal-common.js test_portal_common.js; do
    if node --check "$f"; then echo "ok $f"; else echo "FAIL $f"; FAIL=1; fi
done

step "node portal-common tests"
node test_portal_common.js || FAIL=1

step "py_compile"
python3 -m py_compile host_daemon.py test_host_daemon.py test_watchdog.py && echo "py_compile ok" || FAIL=1

step "JSON validation"
python3 - <<'JSONEOF' || FAIL=1
import json
for f in ("endpoints.json", "manifest.json"):
    json.load(open(f)); print("ok", f)
JSONEOF

step "cloudflared config example present"
test -f cloudflared/config.example.yml && grep -q "ingress:" cloudflared/config.example.yml && echo "ok config.example.yml (yaml eyeballed)" || { echo "FAIL config"; FAIL=1; }

echo
if [ "$FAIL" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit "$FAIL"
