#!/bin/bash

# Locks the MariaDB and phpMyAdmin defaults. No database server is contacted.

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPERS=$(mktemp)
sed -n '/^# BEGIN mariadb access helpers$/,/^# END mariadb access helpers$/p' "$ROOT_DIR/lib/lib.sh" > "$HELPERS"
# shellcheck source=/dev/null
source "$HELPERS"
rm -f "$HELPERS"

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

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label (expected [${expected}] got [${actual}])"
  fi
}

assert_fail() {
  local label="$1"
  shift
  if "$@"; then
    fail "$label (command succeeded)"
  else
    pass "$label"
  fi
}

assert_ok() {
  local label="$1"
  shift
  if "$@"; then
    pass "$label"
  else
    fail "$label (command failed)"
  fi
}

if grep -R -n --exclude-dir=tests -E -e ':-dbhostpassword' -e "IDENTIFIED BY 'dbhostpassword'" "$ROOT_DIR" --include='*.sh' --include='*.conf' >/dev/null; then
  fail "built-in database host password is not a default"
else
  pass "built-in database host password is not a default"
fi

if grep -R -n -E "CREATE USER .*phpmyadmin'@'%'|GRANT .*phpmyadmin'@'%'" "$ROOT_DIR/lib" "$ROOT_DIR/installers" >/dev/null; then
  fail "phpMyAdmin is not granted a wildcard account"
else
  pass "phpMyAdmin is not granted a wildcard account"
fi

if grep -n 'GRANT ALL PRIVILEGES ON \*\.\* TO .phpmyadmin' "$ROOT_DIR/lib/lib.sh" >/dev/null; then
  fail "phpMyAdmin is not a database superuser"
else
  pass "phpMyAdmin is not a database superuser"
fi

if grep -n 'listen 127.0.0.1:8081;' "$ROOT_DIR/configs/phpmyadmin.conf" >/dev/null; then
  pass "phpMyAdmin template listens on loopback"
else
  fail "phpMyAdmin template listens on loopback"
fi

assert_eq "$(mariadb_bind_address)" "127.0.0.1" "local install binds MariaDB to loopback"
assert_eq "$(mariadb_bind_address "203.0.113.10")" "0.0.0.0" "named remote clients may bind MariaDB widely"
assert_fail "wildcard database host is rejected" mariadb_account_host_ok "%"
assert_ok "explicit client address is accepted" mariadb_account_host_ok "203.0.113.10"
assert_ok "hostname client is accepted" mariadb_account_host_ok "node.example.com"

LOCAL_PORTS=$(panel_firewall_ports "" false)
case " $LOCAL_PORTS " in
  *" 3306 "*|*" 8081 "*)
    fail "local firewall list omits database and phpMyAdmin (got [${LOCAL_PORTS}])"
    ;;
  *)
    pass "local firewall list omits database and phpMyAdmin"
    ;;
esac

REMOTE_PORTS=$(panel_firewall_ports "203.0.113.10" true "8080 2022")
case " $REMOTE_PORTS " in
  *" 3306 "*)
    pass "remote database clients open 3306"
    ;;
  *)
    fail "remote database clients open 3306 (got [${REMOTE_PORTS}])"
    ;;
esac
case " $REMOTE_PORTS " in
  *" 8081 "*)
    fail "phpMyAdmin port stays closed (got [${REMOTE_PORTS}])"
    ;;
  *)
    pass "phpMyAdmin port stays closed"
    ;;
esac

GRANT_SQL=$(mariadb_database_host_grant_sql "dbhost" "127.0.0.1")
case "$GRANT_SQL" in
  *"ALL PRIVILEGES"*)
    fail "database host grant is limited"
    ;;
  *"CREATE USER"*"WITH GRANT OPTION"*)
    pass "database host grant can create server databases"
    ;;
  *)
    fail "database host grant can create server databases (got [${GRANT_SQL}])"
    ;;
esac
case "$GRANT_SQL" in
  *"@'127.0.0.1'"*)
    pass "database host grant is pinned to one client"
    ;;
  *)
    fail "database host grant is pinned to one client"
    ;;
esac

# --- root password stays off argv ---------------------------------------------
FAKEBIN=$(mktemp -d)
cat > "$FAKEBIN/mysql" << 'EOF2'
#!/bin/bash
printf '%s\n' "$*" > "$FAKE_MYSQL_LOG.argv"
for a in "$@"; do
  case "$a" in --defaults-extra-file=*) cp "${a#*=}" "$FAKE_MYSQL_LOG.cnf"; stat -c %a "${a#*=}" > "$FAKE_MYSQL_LOG.mode" ;; esac
done
exit "${FAKE_MYSQL_RC:-0}"
EOF2
chmod +x "$FAKEBIN/mysql"
export FAKE_MYSQL_LOG="$FAKEBIN/log"
SECRET='pa"ss\w0rd $x'
PATH="$FAKEBIN:$PATH" mysql_root "$SECRET" -e "SELECT 1"
if grep -qF 'w0rd' "$FAKE_MYSQL_LOG.argv"; then
  fail "mysql_root keeps the password out of argv"
else
  pass "mysql_root keeps the password out of argv"
fi
assert_eq "$(cat "$FAKE_MYSQL_LOG.mode")" "600" "mysql_root defaults file is private"
assert_eq "$(grep '^password=' "$FAKE_MYSQL_LOG.cnf")" 'password="pa\"ss\\w0rd $x"' "mysql_root escapes quotes and backslashes"
LEFT=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -newer "$FAKE_MYSQL_LOG.argv" -name 'tmp.*' -exec grep -l 'w0rd' {} + 2>/dev/null | wc -l)
assert_eq "$LEFT" "0" "mysql_root removes its defaults file"
export FAKE_MYSQL_RC=3
PATH="$FAKEBIN:$PATH" mysql_root "$SECRET" -e "SELECT 1"
assert_eq "$?" "3" "mysql_root returns the client exit status"
unset FAKE_MYSQL_RC
if grep -rnE 'mysql(dump)? -u root -p' "$ROOT_DIR/lib" "$ROOT_DIR/installers" "$ROOT_DIR/ui" >/dev/null; then
  fail "no script passes the MariaDB root password on the command line"
else
  pass "no script passes the MariaDB root password on the command line"
fi
if grep -nE "'password' => '\\$\\{" "$ROOT_DIR/lib/lib.sh" >/dev/null; then
  fail "database host password is not interpolated into the artisan command line"
else
  pass "database host password is not interpolated into the artisan command line"
fi
MEM=$(mktemp)
printf 'MemTotal:        1009000 kB\n' > "$MEM"
assert_eq "$(MEMINFO_FILE="$MEM" mariadb_buffer_pool_mb)" "246" "1 GB host gets a quarter-RAM buffer pool"
printf 'MemTotal:       16000000 kB\n' > "$MEM"
assert_eq "$(MEMINFO_FILE="$MEM" mariadb_buffer_pool_mb)" "1024" "large host keeps the 1 GB buffer pool cap"
printf 'MemTotal:         300000 kB\n' > "$MEM"
assert_eq "$(MEMINFO_FILE="$MEM" mariadb_buffer_pool_mb)" "128" "tiny host gets the 128 MB floor"
rm -f "$MEM"
rm -rf "$FAKEBIN"

printf '\n%s tests, %s failed\n' "$TESTS" "$FAILURES"
[ "$FAILURES" -eq 0 ]
