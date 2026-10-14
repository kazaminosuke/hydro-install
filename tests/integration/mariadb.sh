#!/bin/bash
# Real MariaDB integration test (systemd + mariadb-server). Run as root
# INSIDE A THROWAWAY CONTAINER/VM ONLY:
#   HYDRO_VM_TEST_I_AM_DISPOSABLE=1 bash tests/integration/mariadb.sh
set -u
[ "${HYDRO_VM_TEST_I_AM_DISPOSABLE:-}" = 1 ] || { echo "refusing: set HYDRO_VM_TEST_I_AM_DISPOSABLE=1 in a throwaway VM"; exit 2; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
F=0; N=0
ok() { N=$((N+1)); echo "ok $N - [mariadb] $1"; }
ng() { N=$((N+1)); F=$((F+1)); echo "not ok $N - [mariadb] $1" >&2; }
check() { local l="$1"; shift; if "$@"; then ok "$l"; else ng "$l"; fi; }
cp "$ROOT_DIR/lib/wings-layout.sh" /tmp/wings-layout.sh
# shellcheck source=lib/lib.sh
source "$ROOT_DIR/lib/lib.sh" >/dev/null 2>&1
set +e
# shellcheck disable=SC2034  # read by configure_mariadb_tcp
OS=debian
systemctl start mariadb
for _ in $(seq 30); do mysqladmin ping --silent 2>/dev/null && break; sleep 1; done

# Root password with characters that break naive quoting in option files.
# shellcheck disable=SC2089,SC2090  # the quotes are part of the password
MYSQL_ROOT_PASSWORD='Pa"s\s w0rd#$x'"'"'q'
SQLPW=$(printf '%s' "$MYSQL_ROOT_PASSWORD" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g")
mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('${SQLPW}');"
# shellcheck disable=SC2090
export MYSQL_ROOT_PASSWORD
check "mysql_root authenticates with a hard password over TCP" bash -c 'source '"$ROOT_DIR"'/lib/lib.sh >/dev/null 2>&1; mysql_root "$MYSQL_ROOT_PASSWORD" -h 127.0.0.1 --protocol=TCP -N -e "SELECT 1" | grep -qx 1'
check "a wrong password is rejected" bash -c 'source '"$ROOT_DIR"'/lib/lib.sh >/dev/null 2>&1; ! mysql_root "nope" -h 127.0.0.1 --protocol=TCP -e "SELECT 1" 2>/dev/null'

# The password must not be visible in the process table while a query runs.
( mysql_root "$MYSQL_ROOT_PASSWORD" -h 127.0.0.1 --protocol=TCP -e "SELECT SLEEP(3)" >/dev/null 2>&1 & )
sleep 1
leak=0
for p in /proc/[0-9]*/cmdline; do tr '\0' ' ' < "$p" 2>/dev/null | grep -qF 'w0rd' && leak=1; done
check "root password is not in any process command line" test "$leak" = 0
sleep 3
check "no defaults file is left behind" bash -c '! grep -lF w0rd /tmp/tmp.* 2>/dev/null | grep -q .'

# Loopback-only by default.
quiet() { "$@" >/dev/null 2>&1; }
check "TCP config applies the loopback bind" quiet configure_mariadb_tcp
check "MariaDB listens on 127.0.0.1:3306 only" bash -c 'ss -ltnH "sport = :3306" | awk "{print \$4}" | grep -qx "127.0.0.1:3306" && ! ss -ltnH "sport = :3306" | grep -qE "0\.0\.0\.0:3306|\*:3306|\[::\]:3306"'
check "buffer pool sized to the host" bash -c 'v=$(mysql -u root -N -e "SELECT @@innodb_buffer_pool_size DIV 1048576"); [ "$v" -ge 128 ] && [ "$v" -le 1024 ]'
check "socket activation is pinned to loopback too" bash -c '! systemctl is-active -q mariadb.socket || grep -qx "ListenStream=127.0.0.1:3306" /etc/systemd/system/mariadb.socket.d/99-hydrodactyl.conf'
check "explicit bad bind address is refused" bash -c 'source '"$ROOT_DIR"'/lib/lib.sh >/dev/null 2>&1; OS=debian; ! configure_mariadb_tcp 10.0.0.5 >/dev/null 2>&1'

# Database host user: pinned hosts, limited grant, '%' refused.
# shellcheck disable=SC2034  # read by setup_database_host
INSTALL_DIR=/nonexistent
setup_database_host 127.0.0.1 "Local" dbhost "" 3306 "10.20.30.40" >/dev/null 2>&1
hosts=$(mysql -u root -N -e "SELECT host FROM mysql.user WHERE user='dbhost' ORDER BY host" | tr '\n' ' ')
check "dbhost exists only for loopback and the listed client" test "$hosts" = "10.20.30.40 127.0.0.1 localhost "
grants=$(mysql -u root -N -e "SHOW GRANTS FOR 'dbhost'@'10.20.30.40'")
check "dbhost grant has no SUPER, FILE or SHUTDOWN" bash -c '! grep -qE "SUPER|FILE|SHUTDOWN|ALL PRIVILEGES" <<< "$1"' _ "$grants"
check "dbhost password stored root-only" test "$(stat -c %a /root/.config/hydrodactyl/db-credentials)" = 600
check "wildcard remote host is refused" bash -c 'source '"$ROOT_DIR"'/lib/lib.sh >/dev/null 2>&1; ! setup_database_host 127.0.0.1 x dbhost2 "" 3306 "%" >/dev/null 2>&1'
check "no dbhost2 account was created" test "$(mysql -u root -N -e "SELECT COUNT(*) FROM mysql.user WHERE user='dbhost2'")" = 0
check "remote clients switch the bind to 0.0.0.0" test "$(mariadb_bind_address 10.20.30.40)" = 0.0.0.0

echo "$N tests, $F failed"; exit $((F>0))
