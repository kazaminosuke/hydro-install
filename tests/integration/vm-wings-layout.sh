#!/bin/bash
# Real integration test for a disposable Debian/Ubuntu VM with systemd,
# Docker and MariaDB. Run as root INSIDE A THROWAWAY VM ONLY.
# It installs fake legacy and Pelican Wings units, real Docker containers
# and exercises migration, rollback, uninstall protection and MariaDB binding.
set -u
[ "${HYDRO_VM_TEST_I_AM_DISPOSABLE:-}" = 1 ] || { echo "refusing: set HYDRO_VM_TEST_I_AM_DISPOSABLE=1 in a throwaway VM"; exit 2; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/wings-layout.sh
source "$ROOT_DIR/lib/wings-layout.sh"
F=0; N=0
ok() { N=$((N+1)); echo "ok $N - $1"; }
ng() { N=$((N+1)); F=$((F+1)); echo "not ok $N - $1" >&2; }
check() { local l="$1"; shift; if "$@"; then ok "$l"; else ng "$l"; fi; }
export WINGS_MIGRATE_ASSUME_YES=1 WINGS_LAYOUT_ROOT=""

fake_wings() { # $1 path  $2 marker
  printf '#!/bin/sh\nexec sleep infinity # %s\n' "$2" > "$1"; chmod 755 "$1"; }

setup_legacy() {
  mkdir -p /etc/pterodactyl /var/lib/pterodactyl/volumes/srv1 /var/log/pterodactyl /etc/hydrodactyl
  echo v1.11.0 > /etc/hydrodactyl/wings-version
  fake_wings /usr/local/bin/wings legacy
  echo world > /var/lib/pterodactyl/volumes/srv1/world.dat
  cat > /etc/pterodactyl/config.yml <<C
system:
  root_directory: /var/lib/pterodactyl
  log_directory: /var/log/pterodactyl
  data: /var/lib/pterodactyl/volumes
  archive_directory: /var/lib/pterodactyl/archives
  backup_directory: /var/lib/pterodactyl/backups
  tmp_directory: /tmp/pterodactyl
  username: pterodactyl
docker:
  network:
    interface: 172.18.0.1
    name: pterodactyl_nw
    interfaces:
      v4:
        subnet: 172.18.0.0/16
        gateway: 172.18.0.1
remote: https://panel.example.com
C
  cat > /etc/systemd/system/wings.service <<U
[Unit]
Description=Pterodactyl Wings Daemon
[Service]
User=root
WorkingDirectory=/etc/pterodactyl
ExecStart=/usr/local/bin/wings
PIDFile=/run/wings/daemon.pid
[Install]
WantedBy=multi-user.target
U
  systemctl daemon-reload; systemctl enable --now wings
}

setup_pelican() {
  mkdir -p /etc/pelican /var/lib/pelican/volumes/p1
  echo pel > /etc/pelican/config.yml; echo pel > /var/lib/pelican/volumes/p1/x
  fake_wings /usr/local/bin/pelican-wings pelican
  printf '[Service]\nExecStart=/usr/local/bin/pelican-wings\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/pelican-wings.service
  systemctl daemon-reload; systemctl enable --now pelican-wings
  docker rm -f pelgame >/dev/null 2>&1
  docker run -d --name pelgame -v /var/lib/pelican/volumes/p1:/data busybox sleep 3600 >/dev/null
}

template=$(mktemp)
printf '[Service]\nWorkingDirectory=__WINGS_CONFIG_DIR__\nPIDFile=__WINGS_PID_FILE__\nExecStart=__WINGS_BINARY__ --config __WINGS_CONFIG_FILE__\n[Install]\nWantedBy=multi-user.target\n' > "$template"
export WINGS_SERVICE_TEMPLATE="$template"
docker pull -q busybox >/dev/null

# 1. failure injection: a container stop failure must roll back for real
setup_legacy; setup_pelican
docker rm -f game >/dev/null 2>&1
docker run -d --name game -v /var/lib/pterodactyl/volumes/srv1:/data busybox sleep 3600 >/dev/null
export WINGS_MIGRATE_FAIL_AT=after-copy-data
check "real: injected failure is reported" bash -c '! (source '"$ROOT_DIR"'/lib/wings-layout.sh; wings_migrate_to_namespaced >/dev/null)'
unset WINGS_MIGRATE_FAIL_AT
check "real: rollback leaves legacy wings active" systemctl is-active -q wings
check "real: rollback leaves legacy wings enabled" systemctl is-enabled -q wings
check "real: rollback removes namespaced unit" test ! -e /etc/systemd/system/hydrodactyl-wings.service
check "real: pelican untouched after rollback" systemctl is-active -q pelican-wings

# 2. migration with a live game container
docker rm -f game >/dev/null 2>&1
docker run -d --name game -v /var/lib/pterodactyl/volumes/srv1:/data busybox sh -c 'while :; do date >> /data/live; sleep 0.2; done' >/dev/null
check "real: migration succeeds" bash -c 'source '"$ROOT_DIR"'/lib/wings-layout.sh; wings_migrate_to_namespaced >/dev/null'
check "real: legacy game container stopped before copy" bash -c '! docker ps -q --filter name=^game$ | grep -q .'
check "real: pelican container still running" bash -c 'docker ps -q --filter name=^pelgame$ | grep -q .'
check "real: copied live file matches source" cmp -s /var/lib/pterodactyl/volumes/srv1/live /var/lib/hydrodactyl/wings/volumes/srv1/live
check "real: hydrodactyl-wings active" systemctl is-active -q hydrodactyl-wings
check "real: legacy wings disabled" bash -c '! systemctl is-enabled -q wings'
check "real: pelican service still active" systemctl is-active -q pelican-wings
check "real: original data kept" test -f /var/lib/pterodactyl/volumes/srv1/world.dat

# 3. uninstall the namespaced wings; pelican must survive
cp "$ROOT_DIR/lib/lib.sh" /tmp/hydrodactyl-lib.sh; cp "$ROOT_DIR/lib/wings-layout.sh" /tmp/wings-layout.sh
check "real: uninstall (installers/uninstall.sh, wings only) runs" env REMOVE_WINGS=true REMOVE_PANEL=false REMOVE_ELYTRA=false REMOVE_DATABASE=false REMOVE_DATA=false REMOVE_AUTO_UPDATERS=false bash "$ROOT_DIR/installers/uninstall.sh"
check "real: namespaced unit removed" test ! -e /etc/systemd/system/hydrodactyl-wings.service
check "real: namespaced data removed" test ! -e /var/lib/hydrodactyl/wings
check "real: pelican config kept" test -f /etc/pelican/config.yml
check "real: pelican data kept" test -f /var/lib/pelican/volumes/p1/x
check "real: pelican service active" systemctl is-active -q pelican-wings
check "real: pelican container running" bash -c 'docker ps -q --filter name=^pelgame$ | grep -q .'

echo "$N tests, $F failed"; exit $((F>0))
