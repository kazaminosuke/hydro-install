#!/bin/bash

# Exercises Wings layout detection, config rewriting, and migration against a
# temporary root. No root privileges, systemd, or Docker daemon are required.

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/wings-layout.sh
source "$ROOT_DIR/lib/wings-layout.sh"

FAILURES=0
TESTS=0
DISCOVERED_NONE=$(mktemp)
: > "$DISCOVERED_NONE"

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
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label (expected [${expected}] got [${actual}])"
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

assert_fail() {
  local label="$1"
  shift
  if "$@"; then
    fail "$label (command succeeded)"
  else
    pass "$label"
  fi
}

reset_state() {
  unset WINGS_LAYOUT WINGS_BINARY WINGS_CONFIG_DIR WINGS_CONFIG_FILE WINGS_DATA_DIR || true
  unset WINGS_LOG_DIR WINGS_TMP_DIR WINGS_PASSWD_DIR WINGS_SERVICE WINGS_PID_FILE || true
  unset WINGS_DOCKER_NETWORK WINGS_DOCKER_INTERFACE WINGS_DOCKER_SUBNET WINGS_DOCKER_GATEWAY || true
  unset WINGS_DOCKER_V6_SUBNET WINGS_DOCKER_V6_GATEWAY WINGS_INSTALL_DIR || true
  unset WINGS_INSTALL_STATE WINGS_FOREIGN_PRESENT WINGS_OWNED WINGS_BINARY_SHARED || true
  unset WINGS_SERVICE_OWNER WINGS_ALLOW_SHARED_BINARY WINGS_MIGRATE_FAIL_AT || true
  unset WINGS_MOCK_WINGS_ACTIVE WINGS_MOCK_WINGS_ENABLED || true
  unset WINGS_FOREIGN_SERVICE_ACTIVE WINGS_FOREIGN_SERVICE_ENABLED WINGS_SERVICE_TEMPLATE WINGS_DOCKER_NETWORK_READY WINGS_DOCKER_MOCK_DIR || true
  export WINGS_LAYOUT_SKIP_DOCKER=1
  export WINGS_DOCKER_NETWORKS_FILE="${DISCOVERED_NONE:?}"
  export WINGS_HOST_ROUTES_FILE="${DISCOVERED_NONE:?}"
  export WINGS_LAYOUT_SKIP_SYSTEMCTL=1
  export WINGS_LAYOUT_SKIP_OS_CHECK=1
  export WINGS_MIGRATE_ASSUME_YES=1
  export WINGS_ASSUME_NO=""
  export WINGS_ASSUME_YES=""
}

new_root() {
  local root
  root=$(mktemp -d)
  mkdir -p \
    "$root/usr/local/bin" \
    "$root/etc/hydrodactyl" \
    "$root/etc/systemd/system" \
    "$root/var/log" \
    "$root/tmp"
  printf '%s\n' "$root"
}

write_legacy_unit() {
  local root="$1"
  cat > "$root/etc/systemd/system/wings.service" << 'EOF'
[Service]
WorkingDirectory=/etc/pterodactyl
ExecStart=/usr/local/bin/wings
EOF
}

write_pelican_unit() {
  local root="$1"
  cat > "$root/etc/systemd/system/wings.service" << 'EOF'
[Service]
WorkingDirectory=/etc/pelican
ExecStart=/usr/local/bin/wings
EOF
}

write_legacy_config() {
  local root="$1"
  local network="${2:-pterodactyl_nw}"
  mkdir -p "$root/etc/pterodactyl" \
    "$root/var/lib/pterodactyl/volumes" \
    "$root/var/lib/pterodactyl/archives" \
    "$root/var/lib/pterodactyl/backups" \
    "$root/var/log/pterodactyl"
  printf 'world\n' > "$root/var/lib/pterodactyl/volumes/server.txt"
  cat > "$root/etc/pterodactyl/config.yml" << EOF
app_name: Pterodactyl
system:
  root_directory: /var/lib/pterodactyl
  log_directory: /var/log/pterodactyl
  data: /var/lib/pterodactyl/volumes
  archive_directory: /var/lib/pterodactyl/archives
  backup_directory: /var/lib/pterodactyl/backups
  tmp_directory: /tmp/pterodactyl
  username: pterodactyl
  passwd:
    directory: /run/wings/etc
  machine_id:
    directory: /etc/pterodactyl/machine-id
docker:
  network:
    interface: 172.18.0.1
    name: ${network}
    network_mode: ${network}
    interfaces:
      v4:
        subnet: 172.18.0.0/16
        gateway: 172.18.0.1
      v6:
        subnet: fdba:17c8:6c94::/64
        gateway: fdba:17c8:6c94::1011
  installer_limits:
    memory: 1024
remote: https://panel.example.com
EOF
}

write_service_template() {
  local path="$1"
  cat > "$path" << 'EOF'
[Service]
WorkingDirectory=__WINGS_CONFIG_DIR__
PIDFile=__WINGS_PID_FILE__
ExecStart=__WINGS_BINARY__ --config __WINGS_CONFIG_FILE__
EOF
}

seed_legacy_install() {
  local root="$1"
  printf 'v1.11.0\n' > "$root/etc/hydrodactyl/wings-version"
  printf '#!/bin/sh\necho wings-test\n' > "$root/usr/local/bin/wings"
  chmod 755 "$root/usr/local/bin/wings"
  write_legacy_unit "$root"
  write_legacy_config "$root"
}

# --- new install -----------------------------------------------------------

reset_state
EMPTY_ROOT=$(new_root)
export WINGS_LAYOUT_ROOT="$EMPTY_ROOT"
assert_ok "new host has no Hydrodactyl Wings" wings_resolve_for_action install
assert_eq "$WINGS_LAYOUT" "namespaced" "new install layout is namespaced"
assert_eq "$WINGS_BINARY" "/usr/local/bin/hydrodactyl-wings" "new install binary path"
assert_eq "$WINGS_CONFIG_DIR" "/etc/hydrodactyl/wings" "new install config path"
assert_eq "$WINGS_DATA_DIR" "/var/lib/hydrodactyl/wings" "new install data path"
assert_eq "$WINGS_SERVICE" "hydrodactyl-wings" "new install systemd unit"
assert_eq "$WINGS_DOCKER_SUBNET" "172.22.0.0/16" "new install avoids the Pterodactyl docker subnet"
assert_eq "$WINGS_DOCKER_NETWORK_READY" "1" "new install confirms the docker network"
assert_fail "new install does not stop a missing foreign unit" wings_may_stop_service wings
rm -rf "$EMPTY_ROOT"

# --- existing Hydrodactyl install ------------------------------------------

reset_state
LEGACY_ROOT=$(new_root)
export WINGS_LAYOUT_ROOT="$LEGACY_ROOT"
seed_legacy_install "$LEGACY_ROOT"
assert_ok "existing install resolves for update" wings_resolve_for_action update
assert_eq "$WINGS_INSTALL_STATE" "legacy" "existing install state stays legacy"
assert_eq "$WINGS_BINARY" "/usr/local/bin/wings" "update keeps the legacy binary"
assert_eq "$WINGS_CONFIG_DIR" "/etc/pterodactyl" "update keeps the legacy config directory"
assert_eq "$WINGS_DATA_DIR" "/var/lib/pterodactyl" "update keeps the legacy data directory"
assert_eq "$WINGS_SERVICE" "wings" "update keeps the legacy service name"
assert_ok "legacy reinstall does not switch layout" wings_resolve_for_action install
assert_eq "$WINGS_LAYOUT" "legacy" "reinstall of an existing install stays legacy"
assert_ok "owned legacy service may be stopped" wings_may_stop_service wings
assert_ok "owned legacy binary may be replaced" wings_may_modify_path /usr/local/bin/wings
OWNED=$(wings_owned_binary)
assert_eq "$OWNED" "/usr/local/bin/wings" "owned binary detector returns the legacy path"

# --- Pelican / foreign Wings ------------------------------------------------

reset_state
PELICAN_ROOT=$(new_root)
export WINGS_LAYOUT_ROOT="$PELICAN_ROOT"
mkdir -p "$PELICAN_ROOT/etc/pelican" "$PELICAN_ROOT/var/lib/pelican/volumes"
printf 'token: pelican\n' > "$PELICAN_ROOT/etc/pelican/config.yml"
printf '#!/bin/sh\n' > "$PELICAN_ROOT/usr/local/bin/wings"
chmod 755 "$PELICAN_ROOT/usr/local/bin/wings"
write_pelican_unit "$PELICAN_ROOT"
assert_ok "install beside Pelican resolves" wings_resolve_for_action install
assert_eq "$WINGS_INSTALL_STATE" "none" "Pelican alone is not a Hydrodactyl install"
assert_eq "$WINGS_LAYOUT" "namespaced" "install beside Pelican uses namespaced paths"
assert_eq "$WINGS_FOREIGN_PRESENT" "true" "Pelican is reported as foreign Wings"
assert_fail "Pelican unit is not stopped" wings_may_stop_service wings
assert_fail "Pelican binary is not replaced" wings_may_modify_path /usr/local/bin/wings
assert_fail "Pelican config is not modified" wings_may_modify_path /etc/pelican/config.yml
assert_fail "Pelican data is not modified" wings_may_modify_path /var/lib/pelican/volumes
assert_ok "namespaced binary is a safe install target" wings_may_modify_path /usr/local/bin/hydrodactyl-wings
assert_fail "update refuses a foreign-only host" wings_resolve_for_action update
rm -rf "$PELICAN_ROOT"

# --- shared binary ----------------------------------------------------------

reset_state
SHARED_ROOT=$(new_root)
export WINGS_LAYOUT_ROOT="$SHARED_ROOT"
seed_legacy_install "$SHARED_ROOT"
mkdir -p "$SHARED_ROOT/etc/pelican"
printf 'token: pelican\n' > "$SHARED_ROOT/etc/pelican/config.yml"
assert_ok "shared host still detects the Hydrodactyl install" wings_resolve_for_action update
assert_eq "$WINGS_BINARY_SHARED" "true" "legacy binary is shared when Pelican config exists"
assert_fail "shared binary is not replaced automatically" wings_may_modify_path /usr/local/bin/wings
assert_ok "owned config can be removed while the binary stays" wings_may_modify_path /etc/pterodactyl/config.yml
assert_ok "Hydrodactyl unit may still be stopped" wings_may_stop_service wings
rm -rf "$SHARED_ROOT"

# --- config rewrite ---------------------------------------------------------

reset_state
export WINGS_LAYOUT_ROOT=""
wings_layout_apply namespaced
SAMPLE=$(mktemp)
cat > "$SAMPLE" << 'EOF'
system:
  root_directory: /var/lib/pterodactyl
  log_directory: /var/log/pterodactyl
  data: /var/lib/pterodactyl/volumes
  archive_directory: /var/lib/pterodactyl/archives
  backup_directory: /var/lib/pterodactyl/backups
  tmp_directory: /tmp/pterodactyl
  username: pterodactyl
  diffs_directory: /var/lib/calagopus-wings/diffs
  vmount_directory: /var/lib/calagopus-wings/vmounts
  passwd:
    directory: /run/wings/etc
  machine_id:
    directory: /etc/pelican/machine-id
docker:
  network:
    interface: 172.18.0.1
    name: calagopus_nw
    network_mode: calagopus_nw
    interfaces:
      v4:
        subnet: 172.18.0.0/16
        gateway: 172.18.0.1
      v6:
        subnet: fdba:17c8:6c94::/64
        gateway: fdba:17c8:6c94::1011
  installer_limits:
    memory: 1024
EOF
BEFORE=$(wings_config_collisions "$SAMPLE" namespaced | wc -l | tr -d ' ')
if [ "$BEFORE" -gt 0 ]; then
  pass "unmodified config reports foreign runtime paths"
else
  fail "unmodified config reports foreign runtime paths"
fi
assert_ok "namespaced runtime paths are applied" wings_apply_namespaced_runtime "$SAMPLE"
AFTER=$(wings_config_collisions "$SAMPLE" namespaced | wc -l | tr -d ' ')
assert_eq "$AFTER" "0" "rewritten config has no foreign paths or docker networks"
assert_eq "$(wings_config_get "$SAMPLE" root_directory)" "/var/lib/hydrodactyl/wings" "root directory moved"
assert_eq "$(wings_config_get "$SAMPLE" data)" "/var/lib/hydrodactyl/wings/volumes" "Go and wings-rs data key moved"
assert_eq "$(wings_config_get "$SAMPLE" name)" "hydrodactyl_nw" "docker network renamed"
assert_eq "$(wings_config_get "$SAMPLE" memory)" "1024" "unrelated docker limits stay"
wings_layout_apply legacy
LEGACY_SAMPLE=$(mktemp)
cp "$SAMPLE" "$LEGACY_SAMPLE"
printf 'name: pterodactyl_nw\n' >> "$LEGACY_SAMPLE"
assert_ok "legacy layout does not rewrite config" wings_apply_namespaced_runtime "$LEGACY_SAMPLE"
if grep -q 'pterodactyl_nw' "$LEGACY_SAMPLE"; then
  pass "legacy apply leaves the file unchanged"
else
  fail "legacy apply leaves the file unchanged"
fi
rm -f "$SAMPLE" "$LEGACY_SAMPLE"

reset_state
export WINGS_LAYOUT_ROOT=""
wings_layout_apply namespaced
FOUR_SPACE=$(mktemp)
cat > "$FOUR_SPACE" << 'EOF'
system:
    root_directory: /var/lib/pterodactyl
    data: /var/lib/pterodactyl/volumes
docker:
    network:
        name: pterodactyl_nw
        interface: 172.18.0.1
        interfaces:
            v4:
                subnet: 172.18.0.0/16
                gateway: 172.18.0.1
EOF
assert_ok "four-space config is rewritten" wings_apply_namespaced_runtime "$FOUR_SPACE"
assert_eq "$(wings_config_get "$FOUR_SPACE" root_directory)" "/var/lib/hydrodactyl/wings" "four-space root directory moved"
assert_eq "$(wings_config_get "$FOUR_SPACE" name)" "hydrodactyl_nw" "four-space docker network renamed"
rm -f "$FOUR_SPACE"

reset_state
export WINGS_LAYOUT_ROOT=""
wings_layout_apply namespaced
TABBED=$(mktemp)
printf 'system:\n\troot_directory: /var/lib/pterodactyl\n\tdata: /var/lib/pterodactyl/volumes\n' > "$TABBED"
assert_ok "tab-indented config is rewritten" wings_apply_namespaced_runtime "$TABBED"
assert_eq "$(wings_config_get "$TABBED" data)" "/var/lib/hydrodactyl/wings/volumes" "tab-indented data path moved"
rm -f "$TABBED"

reset_state
export WINGS_LAYOUT_ROOT=""
wings_layout_apply namespaced
UNMAPPED=$(mktemp)
printf 'system:\n  note: /var/lib/pterodactyl\n' > "$UNMAPPED"
BEFORE_UNMAPPED=$(wings_checksum "$UNMAPPED")
assert_fail "unmapped foreign path is rejected" wings_apply_namespaced_runtime "$UNMAPPED"
assert_eq "$(wings_checksum "$UNMAPPED")" "$BEFORE_UNMAPPED" "rejected rewrite leaves the original config"
rm -f "$UNMAPPED"

# --- subnet selection -------------------------------------------------------

reset_state
NET_FILE=$(mktemp)
printf 'pterodactyl_nw 172.18.0.0/16\nbridge 172.22.0.0/16\n' > "$NET_FILE"
export WINGS_DOCKER_NETWORKS_FILE="$NET_FILE"
wings_layout_apply namespaced
assert_ok "occupied subnet is skipped" wings_choose_docker_network
assert_eq "$WINGS_DOCKER_SUBNET" "172.23.0.0/16" "next free subnet is selected"
assert_eq "$WINGS_DOCKER_NETWORK" "hydrodactyl_nw23" "network name follows the free subnet"
rm -f "$NET_FILE"

# Overlapping (not only equal) Docker pools and host routes are skipped.
NET_FILE=$(mktemp)
printf 'custom 172.22.5.0/24\nwide 172.24.0.0/14\n' > "$NET_FILE"
export WINGS_DOCKER_NETWORKS_FILE="$NET_FILE"
ROUTES_FILE=$(mktemp)
printf '172.23.128.0/20\n' > "$ROUTES_FILE"
export WINGS_HOST_ROUTES_FILE="$ROUTES_FILE"
wings_layout_apply namespaced
assert_ok "overlapping subnets are skipped" wings_choose_docker_network
assert_eq "$WINGS_DOCKER_SUBNET" "172.28.0.0/16" "first subnet clear of Docker pools and host routes is selected"
assert_ok "overlap detects a contained /24" wings_ipv4_cidr_overlaps 172.22.0.0/16 172.22.5.0/24
assert_ok "overlap detects a containing /12" wings_ipv4_cidr_overlaps 172.22.0.0/16 172.16.0.0/12
assert_fail "adjacent ranges do not overlap" wings_ipv4_cidr_overlaps 172.22.0.0/16 172.23.0.0/16
assert_fail "IPv6 input is not an IPv4 overlap" wings_ipv4_cidr_overlaps 172.22.0.0/16 fdba::/64
assert_fail "malformed CIDR is not an overlap" wings_ipv4_cidr_overlaps 172.22.0.0/16 999.1.1.1/8
rm -f "$NET_FILE" "$ROUTES_FILE"
export WINGS_HOST_ROUTES_FILE="${DISCOVERED_NONE:?}"

# The Hydrodactyl network gets its own bridge device, never pterodactyl0.
NETCFG=$(mktemp)
cat > "$NETCFG" << 'EOF2'
docker:
  network:
    interface: 172.23.0.1
    name: hydrodactyl_nw23
    network_mode: hydrodactyl_nw23
    interfaces:
      v4:
        subnet: 172.23.0.0/16
        gateway: 172.23.0.1
      v6:
        subnet: fdba:17c8:6d17::/64
        gateway: fdba:17c8:6d17::1011
  installer_limits:
    memory: 1024
EOF2
assert_eq "$(wings_config_network "$NETCFG")" "hydrodactyl_nw23 172.23.0.0/16 172.23.0.1 fdba:17c8:6d17::/64 fdba:17c8:6d17::1011" "network block is read from config.yml"
assert_eq "$(wings_bridge_name_for hydrodactyl_nw)" "hydro0" "default network uses bridge hydro0"
assert_eq "$(wings_bridge_name_for hydrodactyl_nw23)" "hydro23" "numbered network uses its own bridge"
NETMOCK=$(mktemp -d)
: > "$NETMOCK/actions"
WINGS_DOCKER_MOCK_DIR="$NETMOCK" wings_ensure_docker_network "$NETCFG"
assert_eq "$(cat "$NETMOCK/actions")" "network-create hydrodactyl_nw23 hydro23 172.23.0.0/16 fdba:17c8:6d17::/64" "network is pre-created with the Hydrodactyl bridge"
printf 'docker:\n  network:\n    name: x\n' > "$NETCFG"
assert_fail "network without a subnet is not created" wings_ensure_docker_network "$NETCFG"
rm -rf "$NETCFG" "$NETMOCK"

# Real Wings-RS 1.2.5 default config: every path and network key is rewritten.
reset_state
export WINGS_LAYOUT_ROOT=""
wings_layout_apply namespaced
wings_choose_docker_network >/dev/null
RS_CFG=$(mktemp)
cp "$ROOT_DIR/tests/fixtures/wings-rs-1.2.5-default.yml" "$RS_CFG"
assert_ok "Wings-RS default config is rewritten" wings_apply_namespaced_runtime "$RS_CFG"
assert_eq "$(wings_config_get "$RS_CFG" root_directory)" "/var/lib/hydrodactyl/wings" "Wings-RS root directory is namespaced"
assert_eq "$(grep -c 'calagopus_nw' "$RS_CFG")" "0" "Wings-RS network name and mode are rewritten"
assert_eq "$(grep -E '^    mode:' "$RS_CFG")" "    mode: hydrodactyl_nw" "Wings-RS network mode follows the Hydrodactyl network"
rm -f "$RS_CFG"

# Version output for both variants (fake binaries mimic the real CLIs).
VBIN=$(mktemp -d)
printf '#!/bin/sh\ncase "$1" in version) echo "wings vv1.13.4"; echo "Copyright";; *) echo "Error: unknown flag: $1" >&2; exit 1;; esac\n' > "$VBIN/go"
printf '#!/bin/sh\ncase "$1" in --version) echo "calagopus-wings 1.2.5";; *) exit 2;; esac\n' > "$VBIN/rs"
printf '#!/bin/sh\nexit 1\n' > "$VBIN/broken"
chmod +x "$VBIN"/*
assert_eq "$(wings_binary_version "$VBIN/go")" "wings vv1.13.4" "Go Wings version comes from the version subcommand"
assert_eq "$(wings_binary_version "$VBIN/rs")" "calagopus-wings 1.2.5" "Wings-RS version comes from --version"
assert_fail "a binary without version output reports failure" wings_binary_version "$VBIN/broken"
rm -rf "$VBIN"

V6_FILE=$(mktemp)
wings_record_discovered_network "$V6_FILE" "bridge" "172.17.0.0/16" "fdba:17c8:6d16::/64"
export WINGS_DOCKER_NETWORKS_FILE="$V6_FILE"
wings_layout_apply namespaced
assert_ok "occupied IPv6 prefix is skipped" wings_choose_docker_network
assert_eq "$WINGS_DOCKER_SUBNET" "172.23.0.0/16" "IPv4 advances when the paired IPv6 prefix is in use"
assert_eq "$WINGS_DOCKER_V6_SUBNET" "fdba:17c8:6d17::/64" "IPv6 prefix follows the free subnet"
rm -f "$V6_FILE"

reset_state
unset WINGS_DOCKER_NETWORKS_FILE
assert_fail "network selection fails when Docker networks cannot be read" wings_choose_docker_network
assert_eq "$WINGS_DOCKER_NETWORK_READY" "0" "unreadable Docker networks are not treated as free"
export WINGS_LAYOUT_ROOT=""
wings_layout_apply namespaced
SAMPLE_UNCONFIRMED=$(mktemp)
printf 'name: pterodactyl_nw\n' > "$SAMPLE_UNCONFIRMED"
assert_fail "unconfirmed network is not written into a config" wings_apply_namespaced_runtime "$SAMPLE_UNCONFIRMED"
rm -f "$SAMPLE_UNCONFIRMED"

# --- service template -------------------------------------------------------

reset_state
wings_layout_apply namespaced
wings_choose_docker_network
TEMPLATE=$(mktemp)
UNIT=$(mktemp)
write_service_template "$TEMPLATE"
assert_ok "service template renders" wings_render_service_unit "$TEMPLATE" "$UNIT"
if grep -q 'ExecStart=/usr/local/bin/hydrodactyl-wings --config /etc/hydrodactyl/wings/config.yml' "$UNIT"; then
  pass "rendered unit uses the namespaced binary and config flag"
else
  fail "rendered unit uses the namespaced binary and config flag"
fi
rm -f "$TEMPLATE" "$UNIT"

# --- migration --------------------------------------------------------------

reset_state
MIGRATE_ROOT=$(new_root)
export WINGS_LAYOUT_ROOT="$MIGRATE_ROOT"
seed_legacy_install "$MIGRATE_ROOT"
TEMPLATE=$(mktemp)
write_service_template "$TEMPLATE"
export WINGS_SERVICE_TEMPLATE="$TEMPLATE"
SOURCE_SHA=$(wings_checksum "$MIGRATE_ROOT/etc/pterodactyl/config.yml")
: > "$MIGRATE_ROOT/var/log/wings-systemctl.log"
BACKUP=$(wings_migrate_to_namespaced)
if [ -n "$BACKUP" ] && [ -d "$BACKUP" ]; then
  pass "migration returns a backup directory"
else
  fail "migration returns a backup directory (got [${BACKUP:-}])"
fi
assert_eq "$(wings_checksum "$MIGRATE_ROOT/etc/pterodactyl/config.yml")" "$SOURCE_SHA" "migration leaves the original config untouched"
if [ -f "$MIGRATE_ROOT/usr/local/bin/wings" ] && [ -f "$MIGRATE_ROOT/usr/local/bin/hydrodactyl-wings" ]; then
  pass "migration copies the binary and keeps the original"
else
  fail "migration copies the binary and keeps the original"
fi
assert_eq "$(wings_config_get "$MIGRATE_ROOT/etc/hydrodactyl/wings/config.yml" data)" "/var/lib/hydrodactyl/wings/volumes" "migrated config uses the new data path"
if [ -f "$MIGRATE_ROOT/var/lib/hydrodactyl/wings/volumes/server.txt" ] && [ -f "$MIGRATE_ROOT/var/lib/pterodactyl/volumes/server.txt" ]; then
  pass "server data is copied and the original data remains"
else
  fail "server data is copied and the original data remains"
fi
COLLISIONS=$(wings_config_collisions "$MIGRATE_ROOT/etc/hydrodactyl/wings/config.yml" namespaced | wc -l | tr -d ' ')
assert_eq "$COLLISIONS" "0" "migrated config has no runtime collisions"
if grep -q 'disable wings' "$MIGRATE_ROOT/var/log/wings-systemctl.log" && ! grep -q 'stop pelican' "$MIGRATE_ROOT/var/log/wings-systemctl.log"; then
  pass "migration disables the owned unit"
else
  fail "migration disables the owned unit"
fi
assert_ok "migrated install resolves as namespaced" wings_resolve_for_action update
assert_eq "$WINGS_BINARY" "/usr/local/bin/hydrodactyl-wings" "later updates use the migrated binary"
rm -rf "$MIGRATE_ROOT"
rm -f "$TEMPLATE"

# Failure restores the source and removes the partial target.
reset_state
FAIL_ROOT=$(new_root)
export WINGS_LAYOUT_ROOT="$FAIL_ROOT"
seed_legacy_install "$FAIL_ROOT"
TEMPLATE=$(mktemp)
write_service_template "$TEMPLATE"
export WINGS_SERVICE_TEMPLATE="$TEMPLATE"
export WINGS_MIGRATE_FAIL_AT="after-copy-data"
export WINGS_MOCK_WINGS_ACTIVE=1
export WINGS_MOCK_WINGS_ENABLED=1
mkdir -p "$FAIL_ROOT/var/log"
: > "$FAIL_ROOT/var/log/wings-systemctl.log"
SOURCE_SHA=$(wings_checksum "$FAIL_ROOT/etc/pterodactyl/config.yml")
assert_fail "migration failure is reported" wings_migrate_to_namespaced
assert_eq "$(wings_checksum "$FAIL_ROOT/etc/pterodactyl/config.yml")" "$SOURCE_SHA" "failed migration restores the original config checksum"
if [ ! -e "$FAIL_ROOT/usr/local/bin/hydrodactyl-wings" ] && [ ! -e "$FAIL_ROOT/etc/hydrodactyl/wings/config.yml" ] && [ ! -d "$FAIL_ROOT/var/lib/hydrodactyl/wings" ]; then
  pass "failed migration removes partial namespaced files"
else
  fail "failed migration removes partial namespaced files"
fi
if [ -f "$FAIL_ROOT/usr/local/bin/wings" ] && [ -f "$FAIL_ROOT/var/lib/pterodactyl/volumes/server.txt" ]; then
  pass "failed migration keeps the original binary and data"
else
  fail "failed migration keeps the original binary and data"
fi
if grep -qx 'enable wings' "$FAIL_ROOT/var/log/wings-systemctl.log" && grep -qx 'start wings' "$FAIL_ROOT/var/log/wings-systemctl.log"; then
  pass "failed migration restores a running enabled legacy service"
else
  fail "failed migration restores a running enabled legacy service"
fi
unset WINGS_MIGRATE_FAIL_AT
unset WINGS_MOCK_WINGS_ACTIVE WINGS_MOCK_WINGS_ENABLED
assert_ok "legacy install remains after a failed migration" wings_resolve_for_action update
assert_eq "$WINGS_LAYOUT" "legacy" "failed migration does not switch the saved layout"
rm -rf "$FAIL_ROOT"
rm -f "$TEMPLATE"

# A service that was stopped stays stopped. Rollback must not start it.
reset_state
STOPPED_ROOT=$(new_root)
export WINGS_LAYOUT_ROOT="$STOPPED_ROOT"
seed_legacy_install "$STOPPED_ROOT"
TEMPLATE=$(mktemp)
write_service_template "$TEMPLATE"
export WINGS_SERVICE_TEMPLATE="$TEMPLATE"
export WINGS_MIGRATE_FAIL_AT="after-stop"
mkdir -p "$STOPPED_ROOT/var/log"
: > "$STOPPED_ROOT/var/log/wings-systemctl.log"
assert_fail "migration of a stopped service can fail" wings_migrate_to_namespaced
if grep -qx 'stop wings' "$STOPPED_ROOT/var/log/wings-systemctl.log" \
  && ! grep -qx 'start wings' "$STOPPED_ROOT/var/log/wings-systemctl.log" \
  && ! grep -qx 'enable wings' "$STOPPED_ROOT/var/log/wings-systemctl.log"; then
  pass "failed migration leaves a stopped legacy service stopped"
else
  fail "failed migration leaves a stopped legacy service stopped"
fi
unset WINGS_MIGRATE_FAIL_AT
rm -rf "$STOPPED_ROOT"
rm -f "$TEMPLATE"

migrate_quietly_live() { wings_migrate_to_namespaced >/dev/null; }
# Live server containers are stopped before their volumes are copied.
reset_state
LIVE_ROOT=$(new_root)
export WINGS_LAYOUT_ROOT="$LIVE_ROOT"
seed_legacy_install "$LIVE_ROOT"
TEMPLATE=$(mktemp)
write_service_template "$TEMPLATE"
export WINGS_SERVICE_TEMPLATE="$TEMPLATE"
: > "$LIVE_ROOT/var/log/wings-systemctl.log"
LIVE_MOCK=$(mktemp -d)
mkdir -p "$LIVE_MOCK/mounts"
printf 'game\npelgame\n' > "$LIVE_MOCK/ps"
printf '/var/lib/pterodactyl/volumes/abc\n' > "$LIVE_MOCK/mounts/game"
printf '/var/lib/pelican/volumes/abc\n' > "$LIVE_MOCK/mounts/pelgame"
: > "$LIVE_MOCK/actions"
export WINGS_DOCKER_MOCK_DIR="$LIVE_MOCK"
assert_ok "migration with live containers succeeds" migrate_quietly_live
if grep -qx 'stop game' "$LIVE_MOCK/actions" && ! grep -q 'pelgame' "$LIVE_MOCK/actions"; then
  pass "migration stops legacy server containers and leaves Pelican containers"
else
  fail "migration stops legacy server containers and leaves Pelican containers"
fi
rm -rf "$LIVE_ROOT"

# Failure injection: a container that cannot be stopped aborts and rolls back.
reset_state
LIVE_ROOT=$(new_root)
export WINGS_LAYOUT_ROOT="$LIVE_ROOT"
seed_legacy_install "$LIVE_ROOT"
export WINGS_SERVICE_TEMPLATE="$TEMPLATE"
export WINGS_MOCK_WINGS_ACTIVE=1
export WINGS_MOCK_WINGS_ENABLED=1
: > "$LIVE_ROOT/var/log/wings-systemctl.log"
: > "$LIVE_MOCK/actions"
printf 'game\n' > "$LIVE_MOCK/fail_stop"
export WINGS_DOCKER_MOCK_DIR="$LIVE_MOCK"
assert_fail "migration aborts when a server container cannot be stopped" migrate_quietly_live
if [ ! -e "$LIVE_ROOT/var/lib/hydrodactyl/wings" ] && [ ! -e "$LIVE_ROOT/usr/local/bin/hydrodactyl-wings" ] \
  && [ -f "$LIVE_ROOT/var/lib/pterodactyl/volumes/server.txt" ] && grep -q 'start wings' "$LIVE_ROOT/var/log/wings-systemctl.log"; then
  pass "container stop failure rolls back and restarts the legacy service"
else
  fail "container stop failure rolls back and restarts the legacy service"
fi
rm -rf "$LIVE_ROOT" "$LIVE_MOCK"
rm -f "$TEMPLATE"
unset WINGS_DOCKER_MOCK_DIR

# Pelican-owned paths are not a migration source.
reset_state
FOREIGN_SRC=$(new_root)
export WINGS_LAYOUT_ROOT="$FOREIGN_SRC"
seed_legacy_install "$FOREIGN_SRC"
sed -i 's#/var/lib/pterodactyl#/var/lib/pelican#g' "$FOREIGN_SRC/etc/pterodactyl/config.yml"
assert_fail "migration refuses Pelican data paths" wings_migrate_to_namespaced
if [ ! -e "$FOREIGN_SRC/usr/local/bin/hydrodactyl-wings" ]; then
  pass "refused migration does not create a namespaced binary"
else
  fail "refused migration does not create a namespaced binary"
fi
rm -rf "$FOREIGN_SRC"

# Foreign unit is not stopped while our old config is copied.
reset_state
CONFLICT_ROOT=$(new_root)
export WINGS_LAYOUT_ROOT="$CONFLICT_ROOT"
seed_legacy_install "$CONFLICT_ROOT"
write_pelican_unit "$CONFLICT_ROOT"
mkdir -p "$CONFLICT_ROOT/etc/pelican"
printf 'token: pelican\n' > "$CONFLICT_ROOT/etc/pelican/config.yml"
TEMPLATE=$(mktemp)
write_service_template "$TEMPLATE"
export WINGS_SERVICE_TEMPLATE="$TEMPLATE"
export WINGS_FOREIGN_SERVICE_ACTIVE=1
mkdir -p "$CONFLICT_ROOT/var/log"
: > "$CONFLICT_ROOT/var/log/wings-systemctl.log"
migrate_quietly() { wings_migrate_to_namespaced >/dev/null; }
assert_ok "conflicted install can be copied aside" migrate_quietly
if grep -q 'stop wings' "$CONFLICT_ROOT/var/log/wings-systemctl.log"; then
  fail "migration does not stop a Pelican wings unit"
else
  pass "migration does not stop a Pelican wings unit"
fi
if grep -q 'disable wings' "$CONFLICT_ROOT/var/log/wings-systemctl.log"; then
  fail "migration does not disable a Pelican wings unit"
else
  pass "migration does not disable a Pelican wings unit"
fi
if [ -f "$CONFLICT_ROOT/usr/local/bin/wings" ] && [ -f "$CONFLICT_ROOT/etc/pelican/config.yml" ]; then
  pass "Pelican binary and config survive migration"
else
  fail "Pelican binary and config survive migration"
fi
rm -rf "$CONFLICT_ROOT"
rm -f "$TEMPLATE"

# Replacement confirmation never stops a foreign unit, and it asks before
# touching an install we already own.
reset_state
export WINGS_LAYOUT_ROOT="$PELICAN_ROOT"
# The Pelican fixture was removed. Rebuild a small one.
FOREIGN_CONFIRM=$(new_root)
export WINGS_LAYOUT_ROOT="$FOREIGN_CONFIRM"
mkdir -p "$FOREIGN_CONFIRM/etc/pelican"
printf 'token: pelican\n' > "$FOREIGN_CONFIRM/etc/pelican/config.yml"
write_pelican_unit "$FOREIGN_CONFIRM"
mkdir -p "$FOREIGN_CONFIRM/var/log"
: > "$FOREIGN_CONFIRM/var/log/wings-systemctl.log"
assert_ok "install beside Pelican needs no replacement prompt" wings_resolve_for_action install
assert_ok "foreign neighbor is not part of the replacement prompt" wings_confirm_replace_existing
if grep -q 'stop wings' "$FOREIGN_CONFIRM/var/log/wings-systemctl.log"; then
  fail "replacement prompt does not stop Pelican"
else
  pass "replacement prompt does not stop Pelican"
fi
rm -rf "$FOREIGN_CONFIRM"

reset_state
CONFIRM_LEGACY=$(new_root)
export WINGS_LAYOUT_ROOT="$CONFIRM_LEGACY"
seed_legacy_install "$CONFIRM_LEGACY"
mkdir -p "$CONFIRM_LEGACY/var/log"
: > "$CONFIRM_LEGACY/var/log/wings-systemctl.log"
export WINGS_MIGRATE_ASSUME_YES=""
export WINGS_ASSUME_YES=""
export WINGS_ASSUME_NO=1
assert_ok "legacy install is detected before the prompt" wings_resolve_for_action install
assert_fail "replacement of an existing install requires confirmation" wings_confirm_replace_existing
export WINGS_ASSUME_NO=""
export WINGS_ASSUME_YES=1
assert_ok "confirmed replacement stops the owned service" wings_confirm_replace_existing
if grep -q 'stop wings' "$CONFIRM_LEGACY/var/log/wings-systemctl.log"; then
  pass "confirmed replacement records a stop of the owned unit"
else
  fail "confirmed replacement records a stop of the owned unit"
fi
rm -rf "$CONFIRM_LEGACY"

# The auto-updater must follow the saved layout and refuse a foreign binary.
updater_case() {
  local root="$1"
  local expect="$2"
  (
    set +e
    # shellcheck source=installers/auto-update-wings.sh
    source "$ROOT_DIR/installers/auto-update-wings.sh"
    set +e
    export WINGS_LAYOUT_ROOT="$root"
    export WINGS_LAYOUT_SKIP_SYSTEMCTL=1
    export WINGS_LAYOUT_SKIP_OS_CHECK=1
    if [ "$expect" = "legacy" ]; then
      prepare_wings_paths
      [ "$WINGS_BINARY" = "/usr/local/bin/wings" ] && [ "$WINGS_SERVICE" = "wings" ]
    else
      if prepare_wings_paths; then
        return 0
      fi
      return 1
    fi
  )
}

reset_state
UPDATER_LEGACY=$(new_root)
export WINGS_LAYOUT_ROOT="$UPDATER_LEGACY"
seed_legacy_install "$UPDATER_LEGACY"
assert_ok "auto-updater keeps a legacy install on its original paths" updater_case "$UPDATER_LEGACY" legacy
rm -rf "$UPDATER_LEGACY"

reset_state
UPDATER_FOREIGN=$(new_root)
export WINGS_LAYOUT_ROOT="$UPDATER_FOREIGN"
mkdir -p "$UPDATER_FOREIGN/etc/pelican" "$UPDATER_FOREIGN/usr/local/bin"
printf 'token: pelican\n' > "$UPDATER_FOREIGN/etc/pelican/config.yml"
printf '#!/bin/sh\n' > "$UPDATER_FOREIGN/usr/local/bin/wings"
chmod 755 "$UPDATER_FOREIGN/usr/local/bin/wings"
write_pelican_unit "$UPDATER_FOREIGN"
assert_fail "auto-updater refuses a Pelican Wings binary" updater_case "$UPDATER_FOREIGN" foreign
if [ -f "$UPDATER_FOREIGN/usr/local/bin/wings" ] && [ ! -e "$UPDATER_FOREIGN/usr/local/bin/hydrodactyl-wings" ]; then
  pass "refused update leaves the Pelican binary unchanged"
else
  fail "refused update leaves the Pelican binary unchanged"
fi
rm -rf "$UPDATER_FOREIGN"

# --- migration disk estimate ------------------------------------------------

reset_state
DISK_ROOT=$(new_root)
export WINGS_LAYOUT_ROOT="$DISK_ROOT"
mkdir -p "$DISK_ROOT/var/lib/pterodactyl/volumes" "$DISK_ROOT/var/lib/pterodactyl/archives" "$DISK_ROOT/var/log/pterodactyl"
printf 'world-data\n' > "$DISK_ROOT/var/lib/pterodactyl/volumes/server.txt"
printf 'archive\n' > "$DISK_ROOT/var/lib/pterodactyl/archives/pack.tar"
PARENT_KB=$(du -sk "$DISK_ROOT/var/lib/pterodactyl" | awk '{print $1}')
LOG_KB=$(du -sk "$DISK_ROOT/var/log/pterodactyl" | awk '{print $1}')
NEEDED_KB=$(wings_migrate_needed_kb /var/lib/pterodactyl/volumes /var/lib/pterodactyl/archives /var/lib/pterodactyl /var/log/pterodactyl)
assert_eq "$NEEDED_KB" "$((PARENT_KB + LOG_KB))" "nested data directories are counted once"
PROBE=$(wings_migrate_space_probe)
case "$PROBE" in
  "$DISK_ROOT"|"$DISK_ROOT"/*)
    pass "disk check uses the destination filesystem"
    ;;
  *)
    fail "disk check uses the destination filesystem (got [${PROBE}])"
    ;;
esac
rm -rf "$DISK_ROOT"

# --- owned containers -------------------------------------------------------

reset_state
DOCKER_MOCK=$(mktemp -d)
mkdir -p "$DOCKER_MOCK/mounts"
printf 'owned\nforeign\nfly\n' > "$DOCKER_MOCK/ps"
printf '/var/lib/hydrodactyl/wings/volumes/abc\n' > "$DOCKER_MOCK/mounts/owned"
printf '/var/lib/pelican/volumes/abc\n' > "$DOCKER_MOCK/mounts/foreign"
printf '/tmp/unrelated\n' > "$DOCKER_MOCK/mounts/fly"
: > "$DOCKER_MOCK/actions"
export WINGS_DOCKER_MOCK_DIR="$DOCKER_MOCK"
assert_ok "owned data containers can be selected" wings_stop_containers_using /var/lib/hydrodactyl/wings
if grep -qx 'stop owned' "$DOCKER_MOCK/actions" && ! grep -q 'stop foreign' "$DOCKER_MOCK/actions" && ! grep -q 'stop fly' "$DOCKER_MOCK/actions"; then
  pass "only the container mounted on owned data is stopped"
else
  fail "only the container mounted on owned data is stopped"
fi
assert_fail "Pelican data is not a container stop target" wings_stop_containers_using /var/lib/pelican
unset WINGS_DOCKER_MOCK_DIR
rm -rf "$DOCKER_MOCK"

# --- data permissions -------------------------------------------------------

reset_state
PERM_ROOT=$(mktemp -d)
mkdir -p "$PERM_ROOT/volumes" "$PERM_ROOT/archives" "$PERM_ROOT/backups"
printf 'world\n' > "$PERM_ROOT/volumes/server.txt"
printf 'save\n' > "$PERM_ROOT/backups/save.tar"
chmod 777 "$PERM_ROOT/volumes" "$PERM_ROOT/volumes/server.txt" "$PERM_ROOT/backups" "$PERM_ROOT/backups/save.tar"
assert_ok "data permissions can be applied" wings_apply_data_permissions "$PERM_ROOT"
if uname -s | grep -q '^Linux$'; then
  assert_eq "$(stat -c '%a' "$PERM_ROOT/volumes")" "775" "volumes are group-writable rather than world-writable"
  assert_eq "$(stat -c '%a' "$PERM_ROOT/archives")" "750" "archives are not world-accessible"
  assert_eq "$(stat -c '%a' "$PERM_ROOT/backups/save.tar")" "770" "backup files lose access for other users"
else
  pass "volume mode is checked on Linux"
  pass "archive mode is checked on Linux"
  pass "backup mode is checked on Linux"
fi
rm -rf "$PERM_ROOT"

if grep -R -n -E 'chmod (-R )?777' "$ROOT_DIR/installers" "$ROOT_DIR/lib" "$ROOT_DIR/ui" --include='*.sh' >/dev/null; then
  fail "installers no longer force mode 777"
else
  pass "installers no longer force mode 777"
fi

# --- startup reporting ------------------------------------------------------

reset_state
export WINGS_FOREIGN_SERVICE_ACTIVE=1
assert_ok "a running foreign Wings blocks startup" wings_foreign_blocks_start
assert_fail "a running foreign Wings is not described as a reboot-only conflict" wings_foreign_reboot_conflict
assert_eq "$(wings_start_result_label 2)" "blocked" "blocked startup is not reported as running"
unset WINGS_FOREIGN_SERVICE_ACTIVE
export WINGS_FOREIGN_SERVICE_ENABLED=1
assert_fail "an enabled stopped foreign Wings does not block startup" wings_foreign_blocks_start
assert_ok "an enabled stopped foreign Wings warns about the next reboot" wings_foreign_reboot_conflict
unset WINGS_FOREIGN_SERVICE_ENABLED

# --- Pterodactyl removal vs Pelican ---------------------------------------

reset_state
PTERO_REMOVE=$(new_root)
export WINGS_LAYOUT_ROOT="$PTERO_REMOVE"
mkdir -p "$PTERO_REMOVE/etc/pterodactyl"
printf 'token: pterodactyl\n' > "$PTERO_REMOVE/etc/pterodactyl/config.yml"
printf '#!/bin/sh\n' > "$PTERO_REMOVE/usr/local/bin/wings"
write_legacy_unit "$PTERO_REMOVE"
assert_eq "$(wings_pterodactyl_removal_plan || true)" "unit-binary-and-config" "unmanaged Pterodactyl Wings is removed with its binary"
rm -rf "$PTERO_REMOVE"

reset_state
PELICAN_REMOVE=$(new_root)
export WINGS_LAYOUT_ROOT="$PELICAN_REMOVE"
mkdir -p "$PELICAN_REMOVE/etc/pelican" "$PELICAN_REMOVE/etc/pterodactyl"
printf 'token: pelican\n' > "$PELICAN_REMOVE/etc/pelican/config.yml"
printf 'token: old\n' > "$PELICAN_REMOVE/etc/pterodactyl/config.yml"
write_pelican_unit "$PELICAN_REMOVE"
assert_eq "$(wings_pterodactyl_removal_plan || true)" "none" "Pelican Wings is not part of Pterodactyl removal"
rm -rf "$PELICAN_REMOVE"

reset_state
HYDRO_REMOVE=$(new_root)
export WINGS_LAYOUT_ROOT="$HYDRO_REMOVE"
seed_legacy_install "$HYDRO_REMOVE"
assert_eq "$(wings_pterodactyl_removal_plan || true)" "none" "Hydrodactyl-owned legacy Wings is left for its own uninstaller"
rm -rf "$HYDRO_REMOVE"

reset_state
SHARED_REMOVE=$(new_root)
export WINGS_LAYOUT_ROOT="$SHARED_REMOVE"
mkdir -p "$SHARED_REMOVE/etc/pterodactyl" "$SHARED_REMOVE/etc/pelican"
printf 'token: pterodactyl\n' > "$SHARED_REMOVE/etc/pterodactyl/config.yml"
printf 'token: pelican\n' > "$SHARED_REMOVE/etc/pelican/config.yml"
write_legacy_unit "$SHARED_REMOVE"
assert_eq "$(wings_pterodactyl_removal_plan || true)" "unit-and-config" "shared binary stays when Pelican files are also present"
rm -rf "$SHARED_REMOVE"

if grep -q 'Migrate an existing Hydrodactyl Wings install' "$ROOT_DIR/install.sh" \
  && grep -q 'wings_migrate_to_namespaced' "$ROOT_DIR/installers/wings-migrate.sh"; then
  pass "installer menu offers the optional migration"
else
  fail "installer menu offers the optional migration"
fi

printf '\n%s tests, %s failed\n' "$TESTS" "$FAILURES"
[ "$FAILURES" -eq 0 ]
