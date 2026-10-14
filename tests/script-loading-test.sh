#!/bin/bash

# How install.sh and the installers fetch and run other scripts. curl is
# replaced by a fake that serves files from a temporary directory; nothing is
# downloaded and nothing runs as root.

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
TESTS=0
pass() { TESTS=$((TESTS + 1)); printf 'ok %s - %s\n' "$TESTS" "$1"; }
fail() { TESTS=$((TESTS + 1)); FAILURES=$((FAILURES + 1)); printf 'not ok %s - %s\n' "$TESTS" "$1" >&2; }
assert_eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (expected [$2] got [$1])"; fi; }

extract() { sed -n "/^$1() {\$/,/^}\$/p" "$2"; }

WORK=$(mktemp -d)
mkdir -p "$WORK/bin" "$WORK/srv/installers"
# Fake curl: serves $WORK/srv/<path after the base URL>; -f fails on a missing file.
cat > "$WORK/bin/curl" << 'EOF2'
#!/bin/bash
out="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >> "$FAKE_CURL_LOG"
path="$FAKE_SRV/${url#"$FAKE_BASE"/}"
if [ -f "$path" ]; then body=$(cat "$path"); rc=0
else body=""; rc=22; fi  # like a network error: nothing served
if [ -n "$out" ]; then printf '%s\n' "$body" > "$out"; else printf '%s\n' "$body"; fi
exit "$rc"
EOF2
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH" FAKE_SRV="$WORK/srv" FAKE_BASE="https://example.test/repo/branch" FAKE_CURL_LOG="$WORK/curl.log"
: > "$FAKE_CURL_LOG"

# --- get_script ---------------------------------------------------------------
error() { :; }
# shellcheck source=/dev/null
source <(extract get_script "$ROOT_DIR/lib/lib.sh")
export GITHUB_URL="$FAKE_BASE"

printf 'exit 7\n' > "$WORK/srv/installers/fails.sh"
get_script installers fails; assert_eq "$?" "7" "get_script returns the installer exit code"
printf 'exit 0\n' > "$WORK/srv/installers/works.sh"
get_script installers works; assert_eq "$?" "0" "get_script returns success from a working installer"
get_script installers missing; rc=$?
if [ "$rc" -ne 0 ]; then pass "get_script fails when the download fails"; else fail "get_script fails when the download fails"; fi
LEFT=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' -newer "$FAKE_CURL_LOG" -exec grep -l '^exit [07]$' {} + 2>/dev/null | wc -l)
assert_eq "$LEFT" "0" "get_script removes its downloaded copy"

printf '\n%s tests, %s failed\n' "$TESTS" "$FAILURES"
rm -rf "$WORK"
[ "$FAILURES" -eq 0 ]
