#!/bin/bash

# Static checks for update safety and operator guidance. No git repository is modified.

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
TESTS=0

pass() {
  TESTS=$((TESTS + 1))
  printf 'ok %s - %s\n' "$TESTS" "$1"
}

fail() {
  TESTS=$((TESTS + 1))
  FAILURES=$((FAILURES + 1))
  printf 'not ok %s - %s\n' "$TESTS" "$1" >&2
}

if grep -n 'git stash push' "$ROOT_DIR/installers/auto-update-panel.sh" | grep -q '|| true'; then
  fail "panel update does not ignore a failed stash"
else
  pass "panel update does not ignore a failed stash"
fi

if grep -q 'working tree was left unchanged' "$ROOT_DIR/installers/auto-update-panel.sh"; then
  pass "panel update explains that a failed stash leaves files in place"
else
  fail "panel update explains that a failed stash leaves files in place"
fi

for script in auto-update-wings.sh auto-update-elytra.sh auto-update-panel.sh; do
  if grep -q 'option \[7\] Repair' "$ROOT_DIR/installers/$script"; then
    fail "$script points at the repair menu entry"
  elif grep -q 'option \[6\] Repair' "$ROOT_DIR/installers/$script"; then
    pass "$script points at the repair menu entry"
  else
    fail "$script points at the repair menu entry"
  fi
done

printf '\n%s tests, %s failed\n' "$TESTS" "$FAILURES"
[ "$FAILURES" -eq 0 ]
