#!/bin/bash

######################################################################################
#                                                                                    #
# Hydrodactyl Wings layout                                                           #
#                                                                                    #
# New installs use a Hydrodactyl-specific binary, config, data directory, and       #
# systemd unit so they can sit beside Pelican, Pterodactyl, or wings-rs. Existing  #
# Hydrodactyl installs keep /usr/local/bin/wings and /etc/pterodactyl. Nothing in   #
# this file moves an existing install unless wings_migrate_to_namespaced is called. #
#                                                                                    #
######################################################################################

# Prefix filesystem checks when tests point this at a temporary root.
# Empty in production, so paths stay absolute.
wings_actual() {
  printf '%s%s' "${WINGS_LAYOUT_ROOT:-}" "$1"
}

wings_layout_apply() {
  local layout="$1"

  case "$layout" in
    legacy)
      WINGS_LAYOUT="legacy"
      WINGS_BINARY="/usr/local/bin/wings"
      WINGS_CONFIG_DIR="/etc/pterodactyl"
      WINGS_CONFIG_FILE="/etc/pterodactyl/config.yml"
      WINGS_DATA_DIR="/var/lib/pterodactyl"
      WINGS_LOG_DIR="/var/log/pterodactyl"
      WINGS_TMP_DIR="/tmp/pterodactyl"
      WINGS_PASSWD_DIR="/run/wings/etc"
      WINGS_SERVICE="wings"
      WINGS_PID_FILE="/run/wings.pid"
      WINGS_DOCKER_NETWORK="pterodactyl_nw"
      WINGS_DOCKER_INTERFACE="172.18.0.1"
      WINGS_DOCKER_SUBNET="172.18.0.0/16"
      WINGS_DOCKER_GATEWAY="172.18.0.1"
      WINGS_DOCKER_V6_SUBNET="fdba:17c8:6c94::/64"
      WINGS_DOCKER_V6_GATEWAY="fdba:17c8:6c94::1011"
      ;;
    namespaced)
      WINGS_LAYOUT="namespaced"
      WINGS_BINARY="/usr/local/bin/hydrodactyl-wings"
      WINGS_CONFIG_DIR="/etc/hydrodactyl/wings"
      WINGS_CONFIG_FILE="/etc/hydrodactyl/wings/config.yml"
      WINGS_DATA_DIR="/var/lib/hydrodactyl/wings"
      WINGS_LOG_DIR="/var/log/hydrodactyl/wings"
      WINGS_TMP_DIR="/tmp/hydrodactyl-wings"
      WINGS_PASSWD_DIR="/run/hydrodactyl-wings/etc"
      WINGS_SERVICE="hydrodactyl-wings"
      WINGS_PID_FILE="/run/hydrodactyl-wings.pid"
      # Always reset the network here. Callers that already chose a free subnet
      # run wings_choose_docker_network afterwards. A saved layout is loaded by
      # sourcing the env file, not by calling this function again.
      WINGS_DOCKER_NETWORK="hydrodactyl_nw"
      WINGS_DOCKER_INTERFACE="172.22.0.1"
      WINGS_DOCKER_SUBNET="172.22.0.0/16"
      WINGS_DOCKER_GATEWAY="172.22.0.1"
      WINGS_DOCKER_V6_SUBNET="fdba:17c8:6d16::/64"
      WINGS_DOCKER_V6_GATEWAY="fdba:17c8:6d16::1011"
      ;;
    *)
      return 1
      ;;
  esac

  WINGS_INSTALL_DIR="$WINGS_CONFIG_DIR"
  export WINGS_LAYOUT WINGS_BINARY WINGS_CONFIG_DIR WINGS_CONFIG_FILE WINGS_DATA_DIR
  export WINGS_LOG_DIR WINGS_TMP_DIR WINGS_PASSWD_DIR WINGS_SERVICE WINGS_PID_FILE
  export WINGS_DOCKER_NETWORK WINGS_DOCKER_INTERFACE WINGS_DOCKER_SUBNET WINGS_DOCKER_GATEWAY
  export WINGS_DOCKER_V6_SUBNET WINGS_DOCKER_V6_GATEWAY WINGS_INSTALL_DIR
}

# Reject a layout file that points at another panel's files.
wings_layout_targets_are_sane() {
  case "${WINGS_LAYOUT:-}" in
    legacy)
      [ "$WINGS_BINARY" = "/usr/local/bin/wings" ] || return 1
      [ "$WINGS_CONFIG_DIR" = "/etc/pterodactyl" ] || return 1
      [ "$WINGS_CONFIG_FILE" = "/etc/pterodactyl/config.yml" ] || return 1
      [ "$WINGS_DATA_DIR" = "/var/lib/pterodactyl" ] || return 1
      [ "$WINGS_SERVICE" = "wings" ] || return 1
      ;;
    namespaced)
      [ "$WINGS_BINARY" = "/usr/local/bin/hydrodactyl-wings" ] || return 1
      [ "$WINGS_CONFIG_DIR" = "/etc/hydrodactyl/wings" ] || return 1
      [ "$WINGS_CONFIG_FILE" = "/etc/hydrodactyl/wings/config.yml" ] || return 1
      [ "$WINGS_DATA_DIR" = "/var/lib/hydrodactyl/wings" ] || return 1
      [ "$WINGS_LOG_DIR" = "/var/log/hydrodactyl/wings" ] || return 1
      [ "$WINGS_SERVICE" = "hydrodactyl-wings" ] || return 1
      [[ "$WINGS_DOCKER_NETWORK" =~ ^hydrodactyl_nw[0-9]*$ ]] || return 1
      [[ "$WINGS_DOCKER_SUBNET" =~ ^172\.(2[2-9]|3[0-1])\.0\.0/16$ ]] || return 1
      ;;
    *)
      return 1
      ;;
  esac
}

wings_load_saved_layout() {
  local layout_file
  layout_file=$(wings_actual /etc/hydrodactyl/wings-layout.env)
  [ -f "$layout_file" ] || return 1

  # shellcheck disable=SC1090
  source "$layout_file"
  wings_layout_targets_are_sane
}

wings_hydro_marker_present() {
  [ -f "$(wings_actual /etc/hydrodactyl/wings-version)" ] && return 0
  [ -f "$(wings_actual /etc/hydrodactyl/wings-layout.env)" ] && return 0
  [ -f "$(wings_actual /etc/hydrodactyl/auto-update-wings.env)" ] && return 0
  [ -f "$(wings_actual /etc/hydrodactyl/install-info/wings-info)" ] && return 0
  return 1
}

# Echo one of: absent, hydro-legacy, hydro-namespaced, foreign, unknown.
wings_unit_kind_from_file() {
  local file="$1"
  local content=""

  if [ ! -f "$file" ]; then
    printf '%s\n' "absent"
    return 0
  fi

  content=$(cat "$file")

  if printf '%s\n' "$content" | grep -Eq '/etc/pelican(/|$)|/var/lib/pelican|WorkingDirectory=/etc/pelican'; then
    printf '%s\n' "foreign"
    return 0
  fi
  if printf '%s\n' "$content" | grep -Eq '/etc/calagopus-wings(/|$)'; then
    printf '%s\n' "foreign"
    return 0
  fi
  if printf '%s\n' "$content" | grep -Eq 'hydrodactyl-wings|/etc/hydrodactyl/wings(/|$)'; then
    printf '%s\n' "hydro-namespaced"
    return 0
  fi
  if printf '%s\n' "$content" | grep -Eq 'WorkingDirectory=/etc/pterodactyl(/|$)|/usr/local/bin/wings'; then
    if wings_hydro_marker_present; then
      printf '%s\n' "hydro-legacy"
    else
      printf '%s\n' "foreign"
    fi
    return 0
  fi

  printf '%s\n' "unknown"
}

# An unmanaged Pterodactyl unit can be removed. Pelican, calagopus, and a
# Hydrodactyl-owned daemon stay in place for their own uninstallers.
wings_may_remove_pterodactyl_daemon() {
  local unit content

  wings_hydro_marker_present && return 1
  [ -f "$(wings_actual /etc/pterodactyl/config.yml)" ] || return 1
  unit=$(wings_actual /etc/systemd/system/wings.service)
  [ -f "$unit" ] || return 1
  content=$(cat "$unit")
  if printf '%s\n' "$content" | grep -Eq '/etc/pelican(/|$)|/var/lib/pelican|WorkingDirectory=/etc/pelican|/etc/calagopus-wings(/|$)'; then
    return 1
  fi
  if printf '%s\n' "$content" | grep -Eq 'hydrodactyl-wings|/etc/hydrodactyl/wings(/|$)'; then
    return 1
  fi
  printf '%s\n' "$content" | grep -Eq 'WorkingDirectory=/etc/pterodactyl(/|$)|ExecStart=/usr/local/bin/wings'
}

# Prints none, unit-and-config, or unit-binary-and-config.
wings_pterodactyl_removal_plan() {
  if ! wings_may_remove_pterodactyl_daemon; then
    printf '%s\n' "none"
    return 1
  fi
  if [ -f "$(wings_actual /etc/pelican/config.yml)" ] || [ -d "$(wings_actual /var/lib/pelican)" ] || [ -f "$(wings_actual /etc/calagopus-wings/config.yml)" ] || [ -d "$(wings_actual /var/lib/calagopus-wings)" ]; then
    printf '%s\n' "unit-and-config"
    return 0
  fi
  printf '%s\n' "unit-binary-and-config"
}

wings_foreign_wings_present() {
  local kind=""

  [ -f "$(wings_actual /etc/pelican/config.yml)" ] && return 0
  [ -d "$(wings_actual /var/lib/pelican)" ] && return 0
  [ -d "$(wings_actual /var/www/pelican)" ] && return 0
  [ -f "$(wings_actual /etc/calagopus-wings/config.yml)" ] && return 0
  [ -d "$(wings_actual /var/lib/calagopus-wings)" ] && return 0
  # /var/www/pelican is the panel, not the daemon. It must not be deleted, but
  # it does not by itself mean the Wings binary is shared.

  kind=$(wings_unit_kind_from_file "$(wings_actual /etc/systemd/system/wings.service)")
  [ "$kind" = "foreign" ] && return 0

  if [ -f "$(wings_actual /etc/pterodactyl/config.yml)" ] && ! wings_hydro_marker_present; then
    return 0
  fi
  if [ -e "$(wings_actual /usr/local/bin/wings)" ] && ! wings_hydro_marker_present; then
    return 0
  fi
  if [ -e "$(wings_actual /usr/bin/wings)" ] && ! wings_hydro_marker_present; then
    return 0
  fi
  return 1
}

wings_service_unit_kind() {
  local service="$1"
  wings_unit_kind_from_file "$(wings_actual "/etc/systemd/system/${service}.service")"
}

# Sets WINGS_INSTALL_STATE to none, legacy, namespaced, or conflict.
wings_detect_installation() {
  local saved_ok=false
  local legacy_kind=""
  local namespaced_kind=""

  WINGS_INSTALL_STATE="none"
  WINGS_FOREIGN_PRESENT=false
  WINGS_OWNED=false
  WINGS_BINARY_SHARED=false
  WINGS_SERVICE_OWNER="absent"

  if wings_foreign_wings_present; then
    WINGS_FOREIGN_PRESENT=true
  fi

  if wings_load_saved_layout; then
    saved_ok=true
  else
    unset WINGS_LAYOUT WINGS_BINARY WINGS_CONFIG_DIR WINGS_CONFIG_FILE WINGS_DATA_DIR
    unset WINGS_LOG_DIR WINGS_TMP_DIR WINGS_PASSWD_DIR WINGS_SERVICE WINGS_PID_FILE
    unset WINGS_DOCKER_NETWORK WINGS_DOCKER_INTERFACE WINGS_DOCKER_SUBNET WINGS_DOCKER_GATEWAY
    unset WINGS_DOCKER_V6_SUBNET WINGS_DOCKER_V6_GATEWAY
  fi

  legacy_kind=$(wings_service_unit_kind "wings")
  namespaced_kind=$(wings_service_unit_kind "hydrodactyl-wings")

  if [ "$saved_ok" = true ] && [ "$WINGS_LAYOUT" = "namespaced" ]; then
    WINGS_INSTALL_STATE="namespaced"
    WINGS_OWNED=true
    WINGS_SERVICE_OWNER="$namespaced_kind"
  elif [ "$saved_ok" = true ] && [ "$WINGS_LAYOUT" = "legacy" ]; then
    if [ "$legacy_kind" = "foreign" ]; then
      WINGS_INSTALL_STATE="conflict"
      WINGS_OWNED=false
      WINGS_FOREIGN_PRESENT=true
      WINGS_SERVICE_OWNER="foreign"
    else
      WINGS_INSTALL_STATE="legacy"
      WINGS_OWNED=true
      WINGS_SERVICE_OWNER="$legacy_kind"
    fi
  elif wings_hydro_marker_present || [ "$namespaced_kind" = "hydro-namespaced" ] || [ -x "$(wings_actual /usr/local/bin/hydrodactyl-wings)" ]; then
    if [ "$namespaced_kind" = "hydro-namespaced" ] || [ -x "$(wings_actual /usr/local/bin/hydrodactyl-wings)" ]; then
      wings_layout_apply namespaced
      WINGS_INSTALL_STATE="namespaced"
      WINGS_OWNED=true
      WINGS_SERVICE_OWNER="$namespaced_kind"
    elif [ "$legacy_kind" = "foreign" ]; then
      wings_layout_apply legacy
      WINGS_INSTALL_STATE="conflict"
      WINGS_OWNED=false
      WINGS_FOREIGN_PRESENT=true
      WINGS_SERVICE_OWNER="foreign"
    else
      wings_layout_apply legacy
      WINGS_INSTALL_STATE="legacy"
      WINGS_OWNED=true
      WINGS_SERVICE_OWNER="$legacy_kind"
    fi
  fi

  if [ "$WINGS_FOREIGN_PRESENT" = true ] && [ "${WINGS_BINARY:-}" = "/usr/local/bin/wings" ]; then
    WINGS_BINARY_SHARED=true
  fi

  export WINGS_INSTALL_STATE WINGS_FOREIGN_PRESENT WINGS_OWNED WINGS_BINARY_SHARED WINGS_SERVICE_OWNER
}

wings_path_is_foreign_tree() {
  local path="$1"
  case "$path" in
    /etc/pelican|/etc/pelican/*|\
    /var/lib/pelican|/var/lib/pelican/*|\
    /var/log/pelican|/var/log/pelican/*|\
    /tmp/pelican|/tmp/pelican/*|\
    /var/www/pelican|/var/www/pelican/*|\
    /etc/calagopus-wings|/etc/calagopus-wings/*|\
    /var/lib/calagopus-wings|/var/lib/calagopus-wings/*|\
    /var/log/calagopus-wings|/var/log/calagopus-wings/*|\
    /tmp/calagopus-wings|/tmp/calagopus-wings/*|\
    /usr/bin/wings|\
    /var/www/pterodactyl|/var/www/pterodactyl/*)
      return 0
      ;;
  esac
  return 1
}

wings_path_is_legacy_tree() {
  local path="$1"
  case "$path" in
    /usr/local/bin/wings|\
    /etc/pterodactyl|/etc/pterodactyl/*|\
    /var/lib/pterodactyl|/var/lib/pterodactyl/*|\
    /var/log/pterodactyl|/var/log/pterodactyl/*|\
    /tmp/pterodactyl|/tmp/pterodactyl/*|\
    /run/wings|/run/wings/*|\
    /run/wings.pid|\
    /etc/systemd/system/wings.service)
      return 0
      ;;
  esac
  return 1
}

# True when this process may write or delete the path.
# A shared /usr/local/bin/wings stays protected. Hydrodactyl's own config and
# data directories can still be removed when the live systemd unit is not
# Pelican's, because Pelican keeps those files under /etc/pelican and
# /var/lib/pelican.
wings_may_modify_path() {
  local path="$1"
  local unit_kind=""

  if wings_path_is_foreign_tree "$path"; then
    return 1
  fi

  if [ "$path" = "/usr/local/bin/wings" ] && [ "${WINGS_ALLOW_SHARED_BINARY:-}" = 1 ]; then
    return 0
  fi

  if wings_path_is_legacy_tree "$path"; then
    case "$path" in
      /usr/local/bin/wings)
        [ "${WINGS_INSTALL_STATE:-}" = "legacy" ] && [ "${WINGS_BINARY_SHARED:-}" != true ]
        return
        ;;
      /etc/systemd/system/wings.service|/run/wings.pid|/run/wings|/run/wings/*)
        unit_kind=$(wings_service_unit_kind "wings")
        if [ "$unit_kind" = "hydro-legacy" ]; then
          return 0
        fi
        if [ "$unit_kind" = "absent" ] && [ "${WINGS_INSTALL_STATE:-}" = "legacy" ]; then
          return 0
        fi
        return 1
        ;;
      *)
        [ "${WINGS_INSTALL_STATE:-}" = "legacy" ] || [ "${WINGS_INSTALL_STATE:-}" = "conflict" ]
        return
        ;;
    esac
  fi

  return 0
}

wings_may_stop_service() {
  local service="${1:-${WINGS_SERVICE:-}}"
  local kind=""

  [ -n "$service" ] || return 1
  kind=$(wings_service_unit_kind "$service")

  case "$kind" in
    hydro-namespaced)
      return 0
      ;;
    hydro-legacy)
      [ "$service" = "wings" ] && return 0
      return 1
      ;;
    absent)
      # Nothing is running under this name. Stopping is a no-op, not a foreign stop.
      [ "$service" = "hydrodactyl-wings" ] && return 0
      if [ "$service" = "wings" ] && [ "${WINGS_INSTALL_STATE:-}" = "legacy" ] && [ "${WINGS_BINARY_SHARED:-}" != true ]; then
        return 0
      fi
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

wings_address_in_use() {
  local value="$1"
  case "$value" in
    172.17.0.0/16|172.18.0.0/16|172.19.0.0/16|172.20.0.0/16|172.21.0.0/16|fdba:17c8:6c94::/64)
      return 0
      ;;
  esac

  if [ -n "${WINGS_DOCKER_NETWORKS_FILE:-}" ] && [ -f "$WINGS_DOCKER_NETWORKS_FILE" ]; then
    if awk -v value="$value" '$2 == value || $3 == value { found = 1 } END { exit found ? 0 : 1 }' "$WINGS_DOCKER_NETWORKS_FILE"; then
      return 0
    fi
  fi
  return 1
}

wings_subnet_is_reserved() {
  wings_address_in_use "$1"
}

# Append one discovered network. Extra arguments are its subnets, v4 or v6.
wings_record_discovered_network() {
  local file="$1"
  local name="$2"
  shift 2
  local subnet="" recorded=0
  for subnet in "$@"; do
    [ -n "$subnet" ] || continue
    printf '%s %s\n' "$name" "$subnet" >> "$file"
    recorded=1
  done
  if [ "$recorded" = 0 ]; then
    printf '%s\n' "$name" >> "$file"
  fi
}

# Read live Docker networks into WINGS_DOCKER_NETWORKS_FILE.
# A caller-supplied file is trusted, which is how tests inject results.
# Missing Docker, a stopped daemon, or a failed inspect is a hard failure.
wings_discover_docker_networks() {
  if [ -n "${WINGS_DOCKER_NETWORKS_FILE:-}" ] && [ -f "$WINGS_DOCKER_NETWORKS_FILE" ]; then
    return 0
  fi
  if [ "${WINGS_LAYOUT_SKIP_DOCKER:-}" = 1 ]; then
    return 1
  fi
  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    return 1
  fi

  local out name subnets
  out=$(mktemp)
  : > "$out"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! subnets=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' "$name"); then
      rm -f "$out"
      return 1
    fi
    # shellcheck disable=SC2086
    wings_record_discovered_network "$out" "$name" $subnets
  done < <(docker network ls --format '{{.Name}}')
  WINGS_DOCKER_NETWORKS_FILE="$out"
  export WINGS_DOCKER_NETWORKS_FILE
}

wings_network_name_in_use() {
  local name="$1"
  if [ -n "${WINGS_DOCKER_NETWORKS_FILE:-}" ] && [ -f "$WINGS_DOCKER_NETWORKS_FILE" ]; then
    if awk -v name="$name" '$1 == name { found = 1 } END { exit found ? 0 : 1 }' "$WINGS_DOCKER_NETWORKS_FILE"; then
      return 0
    fi
  fi
  return 1
}

# Pick a bridge that is outside the Docker, Pterodactyl, wings-rs, and Pelican defaults.
wings_choose_docker_network() {
  local octet name subnet v6

  if ! wings_discover_docker_networks; then
    WINGS_DOCKER_NETWORK_READY=0
    export WINGS_DOCKER_NETWORK_READY
    return 1
  fi

  for octet in 22 23 24 25 26 27 28 29 30 31; do
    subnet="172.${octet}.0.0/16"
    v6=$(printf 'fdba:17c8:6d%02x::/64' "$octet")
    if wings_address_in_use "$subnet" || wings_address_in_use "$v6"; then
      continue
    fi
    name="hydrodactyl_nw"
    if [ "$octet" != "22" ] || wings_network_name_in_use "$name"; then
      name="hydrodactyl_nw${octet}"
    fi
    if wings_network_name_in_use "$name"; then
      continue
    fi
    WINGS_DOCKER_NETWORK="$name"
    WINGS_DOCKER_SUBNET="$subnet"
    WINGS_DOCKER_GATEWAY="172.${octet}.0.1"
    WINGS_DOCKER_INTERFACE="172.${octet}.0.1"
    WINGS_DOCKER_V6_SUBNET="$v6"
    WINGS_DOCKER_V6_GATEWAY=$(printf 'fdba:17c8:6d%02x::1011' "$octet")
    WINGS_DOCKER_NETWORK_READY=1
    export WINGS_DOCKER_NETWORK WINGS_DOCKER_SUBNET WINGS_DOCKER_GATEWAY WINGS_DOCKER_INTERFACE
    export WINGS_DOCKER_V6_SUBNET WINGS_DOCKER_V6_GATEWAY WINGS_DOCKER_NETWORK_READY
    return 0
  done
  WINGS_DOCKER_NETWORK_READY=0
  export WINGS_DOCKER_NETWORK_READY
  return 1
}

wings_finalize_docker_network() {
  if ! wings_choose_docker_network; then
    return 1
  fi
}

wings_resolve_for_action() {
  local action="$1"

  wings_detect_installation

  case "$action" in
    install)
      case "$WINGS_INSTALL_STATE" in
        legacy)
          wings_layout_apply legacy
          WINGS_DOCKER_NETWORK_READY=1
          export WINGS_DOCKER_NETWORK_READY
          ;;
        namespaced)
          if ! wings_load_saved_layout; then
            wings_layout_apply namespaced
          fi
          WINGS_DOCKER_NETWORK_READY=1
          export WINGS_DOCKER_NETWORK_READY
          ;;
        none|conflict)
          # A foreign daemon stays where it is. This install uses the new paths.
          # Docker may not be installed yet. A failed lookup leaves the network
          # unconfirmed instead of guessing that 172.22.0.0/16 is free.
          unset WINGS_DOCKER_NETWORK WINGS_DOCKER_SUBNET WINGS_DOCKER_GATEWAY WINGS_DOCKER_INTERFACE
          unset WINGS_DOCKER_V6_SUBNET WINGS_DOCKER_V6_GATEWAY
          wings_layout_apply namespaced
          wings_choose_docker_network || true
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    update|repair)
      case "$WINGS_INSTALL_STATE" in
        legacy|namespaced)
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    uninstall)
      case "$WINGS_INSTALL_STATE" in
        legacy|namespaced|conflict)
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    migrate)
      case "$WINGS_INSTALL_STATE" in
        legacy|conflict)
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac

  WINGS_INSTALL_DIR="$WINGS_CONFIG_DIR"
  export WINGS_INSTALL_DIR
}

wings_save_layout() {
  local dest tmp
  dest=$(wings_actual /etc/hydrodactyl/wings-layout.env)
  wings_layout_targets_are_sane || return 1
  mkdir -p "$(dirname "$dest")"
  tmp=$(mktemp)
  cat > "$tmp" << EOF
WINGS_LAYOUT="${WINGS_LAYOUT}"
WINGS_BINARY="${WINGS_BINARY}"
WINGS_CONFIG_DIR="${WINGS_CONFIG_DIR}"
WINGS_CONFIG_FILE="${WINGS_CONFIG_FILE}"
WINGS_DATA_DIR="${WINGS_DATA_DIR}"
WINGS_LOG_DIR="${WINGS_LOG_DIR}"
WINGS_TMP_DIR="${WINGS_TMP_DIR}"
WINGS_PASSWD_DIR="${WINGS_PASSWD_DIR}"
WINGS_SERVICE="${WINGS_SERVICE}"
WINGS_PID_FILE="${WINGS_PID_FILE}"
WINGS_DOCKER_NETWORK="${WINGS_DOCKER_NETWORK}"
WINGS_DOCKER_INTERFACE="${WINGS_DOCKER_INTERFACE}"
WINGS_DOCKER_SUBNET="${WINGS_DOCKER_SUBNET}"
WINGS_DOCKER_GATEWAY="${WINGS_DOCKER_GATEWAY}"
WINGS_DOCKER_V6_SUBNET="${WINGS_DOCKER_V6_SUBNET}"
WINGS_DOCKER_V6_GATEWAY="${WINGS_DOCKER_V6_GATEWAY}"
EOF
  mv "$tmp" "$dest"
  chmod 644 "$dest"
}

wings_env_set() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp mode

  mkdir -p "$(dirname "$file")"
  tmp=$(mktemp)
  if [ -f "$file" ]; then
    grep -v "^${key}=" "$file" > "$tmp" || true
  fi
  printf '%s="%s"\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$file"
  mode=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%OLp' "$file" 2>/dev/null || echo "")
  if [ "$mode" != "600" ] && [ "$mode" != "644" ]; then
    chmod 644 "$file"
  fi
}

wings_sync_update_env_paths() {
  local env_file
  env_file=$(wings_actual /etc/hydrodactyl/auto-update-wings.env)
  [ -n "${WINGS_BINARY:-}" ] || return 1
  wings_env_set "$env_file" "WINGS_LAYOUT" "$WINGS_LAYOUT"
  wings_env_set "$env_file" "WINGS_BINARY" "$WINGS_BINARY"
  wings_env_set "$env_file" "WINGS_INSTALL_DIR" "$WINGS_CONFIG_DIR"
  wings_env_set "$env_file" "WINGS_CONFIG_DIR" "$WINGS_CONFIG_DIR"
  wings_env_set "$env_file" "WINGS_DATA_DIR" "$WINGS_DATA_DIR"
  wings_env_set "$env_file" "WINGS_SERVICE" "$WINGS_SERVICE"
  chmod 600 "$env_file"
}

wings_replacement_value() {
  local key="$1"
  local level="$2"
  local s0="$3"
  local s1="$4"
  local s2="$5"
  local s3="$6"
  local out=""

  if [ "$s0" = "system" ] && [ "$level" -eq 1 ]; then
    case "$key" in
      root_directory) out="$WINGS_DATA_DIR" ;;
      log_directory) out="$WINGS_LOG_DIR" ;;
      data) out="$WINGS_DATA_DIR/volumes" ;;
      archive_directory) out="$WINGS_DATA_DIR/archives" ;;
      backup_directory) out="$WINGS_DATA_DIR/backups" ;;
      tmp_directory) out="$WINGS_TMP_DIR" ;;
      diffs_directory) out="$WINGS_DATA_DIR/diffs" ;;
      vmount_directory) out="$WINGS_DATA_DIR/vmounts" ;;
    esac
  elif [ "$s0" = "system" ] && [ "$s1" = "passwd" ] && [ "$level" -eq 2 ] && [ "$key" = "directory" ]; then
    out="$WINGS_PASSWD_DIR"
  elif [ "$s0" = "system" ] && [ "$s1" = "machine_id" ] && [ "$level" -eq 2 ] && [ "$key" = "directory" ]; then
    out="$WINGS_CONFIG_DIR/machine-id"
  elif [ "$s0" = "docker" ] && [ "$s1" = "network" ] && [ "$level" -eq 2 ]; then
    case "$key" in
      name|network_mode) out="$WINGS_DOCKER_NETWORK" ;;
      interface) out="$WINGS_DOCKER_INTERFACE" ;;
    esac
  elif [ "$s0" = "docker" ] && [ "$s1" = "network" ] && [ "$s2" = "interfaces" ] && [ "$level" -eq 4 ]; then
    if [ "$s3" = "v4" ]; then
      case "$key" in
        subnet) out="$WINGS_DOCKER_SUBNET" ;;
        gateway) out="$WINGS_DOCKER_GATEWAY" ;;
      esac
    elif [ "$s3" = "v6" ]; then
      case "$key" in
        subnet) out="$WINGS_DOCKER_V6_SUBNET" ;;
        gateway) out="$WINGS_DOCKER_V6_GATEWAY" ;;
      esac
    fi
  fi

  printf '%s' "$out"
}

wings_rewrite_config_stream() {
  local -a stack_key=()
  local -a stack_indent=()
  local depth=0
  local line spaces trimmed key value level newval indent

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
      printf '%s\n' "$line"
      continue
    fi

    spaces="${line%%[![:space:]]*}"
    trimmed="${line#"$spaces"}"
    if [[ ! "$trimmed" =~ ^([A-Za-z0-9_]+):[[:space:]]*(.*)$ ]]; then
      printf '%s\n' "$line"
      continue
    fi

    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    # Character count works for both a 2-space, 4-space, and tab indent as
    # long as one file uses one style. Nesting is the increase in indent.
    indent=${#spaces}

    while [ "$depth" -gt 0 ] && [ "${stack_indent[$((depth - 1))]}" -ge "$indent" ]; do
      depth=$((depth - 1))
      unset "stack_key[$depth]"
      unset "stack_indent[$depth]"
    done

    level=$depth
    stack_key[$depth]="$key"
    stack_indent[$depth]=$indent
    depth=$((depth + 1))

    newval=""
    if [ "${WINGS_LAYOUT:-}" = "namespaced" ] && [ -n "$value" ] && [[ ! "$value" =~ ^# ]]; then
      newval=$(wings_replacement_value "$key" "$level" "${stack_key[0]:-}" "${stack_key[1]:-}" "${stack_key[2]:-}" "${stack_key[3]:-}")
    fi

    if [ -n "$newval" ]; then
      printf '%s%s: %s\n' "$spaces" "$key" "$newval"
    else
      printf '%s\n' "$line"
    fi
  done
}

wings_apply_namespaced_runtime() {
  local file="$1"
  local tmp

  [ "${WINGS_LAYOUT:-}" = "namespaced" ] || return 0
  [ -f "$file" ] || return 1
  if [ "${WINGS_DOCKER_NETWORK_READY:-}" = 0 ]; then
    return 1
  fi
  tmp=$(mktemp)
  if ! wings_rewrite_config_stream < "$file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  local collisions=""
  collisions=$(wings_config_collisions "$tmp" namespaced || true)
  if [ -n "$collisions" ]; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file"
  chmod 600 "$file"
}

wings_collision_tokens() {
  local mode="${1:-${WINGS_LAYOUT:-namespaced}}"

  if [ "$mode" = "legacy" ]; then
    printf '%s\n' \
      "/var/lib/pelican" "/var/log/pelican" "/tmp/pelican" "/etc/pelican" \
      "/var/lib/calagopus-wings" "/var/log/calagopus-wings" "/etc/calagopus-wings" \
      "calagopus_nw" "pelican_nw"
  else
    printf '%s\n' \
      "/var/lib/pterodactyl" "/var/lib/pelican" "/var/lib/calagopus-wings" \
      "/var/log/pterodactyl" "/var/log/pelican" "/var/log/calagopus-wings" \
      "/tmp/pterodactyl" "/tmp/pelican" \
      "/etc/pterodactyl" "/etc/pelican" "/etc/calagopus-wings" \
      "pterodactyl_nw" "calagopus_nw" "pelican_nw" \
      "172.18.0.0/16" "172.18.0.1" "172.17.0.0/16" "172.21.0.0/16" \
      "fdba:17c8:6c94::"
  fi
}

wings_config_collisions() {
  local file="$1"
  local mode="${2:-${WINGS_LAYOUT:-namespaced}}"
  local line token
  local -a tokens=()

  [ -f "$file" ] || return 1
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    tokens+=("$token")
  done < <(wings_collision_tokens "$mode")

  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    for token in "${tokens[@]}"; do
      case "$line" in
        *"$token"*)
          printf '%s\n' "$line"
          break
          ;;
      esac
    done
  done < "$file"
}

wings_config_get() {
  local file="$1"
  local wanted="$2"
  local line spaces trimmed key value

  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    spaces="${line%%[![:space:]]*}"
    trimmed="${line#"$spaces"}"
    if [[ "$trimmed" =~ ^([A-Za-z0-9_]+):[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      value="${value%%#*}"
      value="${value%"${value##*[![:space:]]}"}"
      value="${value#\"}"
      value="${value%\"}"
      if [ "$key" = "$wanted" ] && [ -n "$value" ]; then
        printf '%s\n' "$value"
        return 0
      fi
    fi
  done < "$file"
  return 1
}

wings_builtin_service_template() {
  cat << 'EOF'
[Unit]
Description=Hydrodactyl Wings Daemon
Documentation=https://github.com/pterodactyl/wings
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
User=root
Group=root
WorkingDirectory=__WINGS_CONFIG_DIR__
LimitNOFILE=4096
PIDFile=__WINGS_PID_FILE__
ExecStart=__WINGS_BINARY__ --config __WINGS_CONFIG_FILE__
ExecStop=/bin/kill -s QUIT $MAINPID
ExecReload=/bin/kill -s HUP $MAINPID
Restart=on-failure
RestartSec=5s
StartLimitInterval=60s
StartLimitBurst=3

[Install]
WantedBy=multi-user.target
EOF
}

wings_render_service_unit() {
  local template="$1"
  local dest="$2"
  local tmp

  [ -f "$template" ] || return 1
  if ! grep -q '__WINGS_BINARY__' "$template"; then
    return 1
  fi
  mkdir -p "$(dirname "$dest")"
  tmp=$(mktemp)
  sed \
    -e "s|__WINGS_CONFIG_DIR__|${WINGS_CONFIG_DIR}|g" \
    -e "s|__WINGS_PID_FILE__|${WINGS_PID_FILE}|g" \
    -e "s|__WINGS_BINARY__|${WINGS_BINARY}|g" \
    -e "s|__WINGS_CONFIG_FILE__|${WINGS_CONFIG_FILE}|g" \
    "$template" > "$tmp"
  if grep -q '__WINGS_' "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$dest"
  chmod 644 "$dest"
}

wings_install_service_unit() {
  local template="$1"
  wings_render_service_unit "$template" "$(wings_actual "/etc/systemd/system/${WINGS_SERVICE}.service")"
}

wings_checksum() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    cksum "$file" | awk '{print $1}'
  fi
}

wings_systemctl() {
  local log_file
  if [ "${WINGS_LAYOUT_SKIP_SYSTEMCTL:-}" = 1 ]; then
    log_file=$(wings_actual /var/log/wings-systemctl.log)
    mkdir -p "$(dirname "$log_file")"
    printf '%s\n' "$*" >> "$log_file"
    return 0
  fi
  systemctl "$@"
}

# Active and enabled state for the legacy unit. Tests set the mock variables
# instead of calling the host's systemd.
wings_unit_is_active() {
  local service="$1"
  if [ "${WINGS_LAYOUT_SKIP_SYSTEMCTL:-}" = 1 ]; then
    [ "$service" = "wings" ] && [ "${WINGS_MOCK_WINGS_ACTIVE:-}" = 1 ]
    return
  fi
  systemctl is-active --quiet "$service"
}

wings_unit_is_enabled() {
  local service="$1"
  if [ "${WINGS_LAYOUT_SKIP_SYSTEMCTL:-}" = 1 ]; then
    [ "$service" = "wings" ] && [ "${WINGS_MOCK_WINGS_ENABLED:-}" = 1 ]
    return
  fi
  systemctl is-enabled --quiet "$service"
}

wings_foreign_blocks_start() {
  local kind=""

  if [ "${WINGS_FOREIGN_SERVICE_ACTIVE:-}" = 1 ]; then
    return 0
  fi
  if [ "${WINGS_LAYOUT_SKIP_SYSTEMCTL:-}" = 1 ]; then
    return 1
  fi
  kind=$(wings_service_unit_kind "wings")
  if [ "$kind" = "foreign" ] && systemctl is-active --quiet wings 2>/dev/null; then
    return 0
  fi
  return 1
}

# Enabled but stopped: Hydrodactyl can start now, and a reboot can bring the
# other daemon back onto ports 8080 and 2022.
wings_foreign_reboot_conflict() {
  if wings_foreign_blocks_start; then
    return 1
  fi
  if [ "${WINGS_FOREIGN_SERVICE_ENABLED:-}" = 1 ]; then
    return 0
  fi
  if [ "${WINGS_LAYOUT_SKIP_SYSTEMCTL:-}" = 1 ]; then
    return 1
  fi
  local kind=""
  kind=$(wings_service_unit_kind "wings")
  if [ "$kind" = "foreign" ] && systemctl is-enabled --quiet wings 2>/dev/null; then
    return 0
  fi
  return 1
}

wings_start_result_label() {
  local start_status="$1"
  if [ "$start_status" -eq 2 ]; then
    printf '%s\n' "blocked"
    return 0
  fi
  if [ "$start_status" -eq 0 ]; then
    if [ "${WINGS_LAYOUT_SKIP_SYSTEMCTL:-}" = 1 ] || systemctl is-active --quiet "${WINGS_SERVICE:-}" 2>/dev/null; then
      printf '%s\n' "started"
      return 0
    fi
  fi
  printf '%s\n' "uncertain"
}

wings_stop_owned_service() {
  local service="${1:-$WINGS_SERVICE}"
  if ! wings_may_stop_service "$service"; then
    return 1
  fi
  if [ "$(wings_service_unit_kind "$service")" = "absent" ]; then
    return 0
  fi
  wings_systemctl stop "$service"
}

wings_start_owned_service() {
  if wings_foreign_blocks_start; then
    return 2
  fi
  wings_systemctl enable "$WINGS_SERVICE" || return 1
  wings_systemctl restart "$WINGS_SERVICE"
}

wings_confirm() {
  local prompt="$1"
  local default="${2:-n}"
  local result=""

  if [ "${WINGS_ASSUME_YES:-}${WINGS_MIGRATE_ASSUME_YES:-}" = "1" ] || [ "${WINGS_ASSUME_YES:-}" = 1 ] || [ "${WINGS_MIGRATE_ASSUME_YES:-}" = 1 ]; then
    return 0
  fi
  if [ "${WINGS_ASSUME_NO:-}" = 1 ]; then
    return 1
  fi
  if [ ! -t 0 ]; then
    return 1
  fi
  if declare -F bool_input >/dev/null 2>&1; then
    bool_input result "$prompt" "$default"
    [ "$result" = "y" ]
    return
  fi
  return 1
}

wings_preflight_os() {
  if [ "${WINGS_LAYOUT_SKIP_OS_CHECK:-}" = 1 ]; then
    return 0
  fi
  [ "$(uname -s 2>/dev/null || echo unknown)" = "Linux" ] || return 1
  if [ "${WINGS_LAYOUT_SKIP_SYSTEMCTL:-}" != 1 ] && ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi
}

wings_prepare_directories() {
  mkdir -p \
    "$(wings_actual "$WINGS_CONFIG_DIR")" \
    "$(wings_actual "$WINGS_DATA_DIR/volumes")" \
    "$(wings_actual "$WINGS_DATA_DIR/archives")" \
    "$(wings_actual "$WINGS_DATA_DIR/backups")" \
    "$(wings_actual "$WINGS_LOG_DIR")" \
    "$(wings_actual "$WINGS_TMP_DIR")" \
    "$(wings_actual /etc/hydrodactyl)"
}

wings_owned_binary() {
  wings_detect_installation
  case "$WINGS_INSTALL_STATE" in
    legacy|namespaced)
      if [ -e "$(wings_actual "$WINGS_BINARY")" ]; then
        printf '%s\n' "$WINGS_BINARY"
        return 0
      fi
      ;;
  esac
  return 1
}

wings_migrate_checkpoint() {
  local name="$1"
  if [ "${WINGS_MIGRATE_FAIL_AT:-}" = "$name" ]; then
    return 1
  fi
}

wings_path_is_legacy_source() {
  local path="$1"
  case "$path" in
    /etc/pterodactyl|/etc/pterodactyl/*|\
    /var/lib/pterodactyl|/var/lib/pterodactyl/*|\
    /var/log/pterodactyl|/var/log/pterodactyl/*|\
    /tmp/pterodactyl|/tmp/pterodactyl/*|\
    /run/wings|/run/wings/*)
      return 0
      ;;
  esac
  return 1
}

wings_migrate_validate() {
  local config_file root_dir data_dir archive_dir backup_dir log_dir tmp_dir
  local needed=0 free_kb=0 dir_kb=0 path

  wings_preflight_os || return 1
  wings_resolve_for_action migrate || return 1

  if [ "$WINGS_INSTALL_STATE" = "namespaced" ]; then
    return 1
  fi
  if [ "$WINGS_INSTALL_STATE" != "legacy" ] && [ "$WINGS_INSTALL_STATE" != "conflict" ]; then
    return 1
  fi

  config_file=$(wings_actual /etc/pterodactyl/config.yml)
  [ -f "$config_file" ] || return 1
  [ -e "$(wings_actual /usr/local/bin/wings)" ] || return 1
  wings_hydro_marker_present || return 1

  root_dir=$(wings_config_get "$config_file" root_directory || true)
  data_dir=$(wings_config_get "$config_file" data || true)
  archive_dir=$(wings_config_get "$config_file" archive_directory || true)
  backup_dir=$(wings_config_get "$config_file" backup_directory || true)
  log_dir=$(wings_config_get "$config_file" log_directory || true)
  tmp_dir=$(wings_config_get "$config_file" tmp_directory || true)

  [ -n "$root_dir" ] || return 1
  for path in "$root_dir" "$data_dir" "$archive_dir" "$backup_dir" "$log_dir" "$tmp_dir"; do
    [ -n "$path" ] || continue
    if ! wings_path_is_legacy_source "$path"; then
      return 1
    fi
  done

  if [ -e "$(wings_actual /usr/local/bin/hydrodactyl-wings)" ]; then
    return 1
  fi
  if [ -e "$(wings_actual /etc/hydrodactyl/wings/config.yml)" ]; then
    return 1
  fi
  if [ -d "$(wings_actual /var/lib/hydrodactyl/wings)" ]; then
    return 1
  fi

  for path in "$data_dir" "$archive_dir" "$backup_dir" "$root_dir" "$log_dir"; do
    [ -n "$path" ] || continue
    [ -d "$(wings_actual "$path")" ] || continue
    dir_kb=$(du -sk "$(wings_actual "$path")" 2>/dev/null | awk '{print $1}')
    needed=$((needed + ${dir_kb:-0}))
  done
  free_kb=$(df -Pk "$(wings_actual /)" 2>/dev/null | awk 'NR==2 {print $4}')
  [ -n "$free_kb" ] || return 1
  if [ "$free_kb" -lt $((needed + 1024)) ]; then
    return 1
  fi
}

wings_migrate_backup() {
  local stamp backup_dir config_file
  stamp=$(date +%Y%m%d-%H%M%S)
  backup_dir=$(wings_actual "/var/backups/hydrodactyl/wings-migrate-${stamp}")
  mkdir -p "$backup_dir"
  config_file=$(wings_actual /etc/pterodactyl/config.yml)

  cp -a "$(wings_actual /usr/local/bin/wings)" "$backup_dir/wings.binary"
  mkdir -p "$backup_dir/config"
  cp -a "$config_file" "$backup_dir/config/config.yml"
  if [ -f "$(wings_actual /etc/systemd/system/wings.service)" ]; then
    cp -a "$(wings_actual /etc/systemd/system/wings.service)" "$backup_dir/wings.service"
  fi
  if [ -f "$(wings_actual /etc/hydrodactyl/wings-layout.env)" ]; then
    cp -a "$(wings_actual /etc/hydrodactyl/wings-layout.env)" "$backup_dir/wings-layout.env"
  fi
  if [ -f "$(wings_actual /etc/hydrodactyl/auto-update-wings.env)" ]; then
    cp -a "$(wings_actual /etc/hydrodactyl/auto-update-wings.env)" "$backup_dir/auto-update-wings.env"
  fi

  local old_active=0 old_enabled=0
  if wings_may_stop_service "wings" && [ "$(wings_service_unit_kind wings)" != "absent" ]; then
    if wings_unit_is_active "wings"; then
      old_active=1
    fi
    if wings_unit_is_enabled "wings"; then
      old_enabled=1
    fi
  fi

  cat > "$backup_dir/manifest.env" << EOF
SOURCE_CONFIG_SHA="$(wings_checksum "$config_file")"
SOURCE_BINARY_SHA="$(wings_checksum "$(wings_actual /usr/local/bin/wings)")"
DISABLED_OLD_SERVICE=""
STARTED_NEW_SERVICE=""
OLD_SERVICE_WAS_ACTIVE="${old_active}"
OLD_SERVICE_WAS_ENABLED="${old_enabled}"
EOF
  printf '%s\n' "$backup_dir"
}

wings_migrate_copy_tree() {
  local source_path="$1"
  local dest_path="$2"
  local source_actual dest_actual

  [ -n "$source_path" ] || return 0
  case "$dest_path" in
    /var/lib/hydrodactyl/wings|/var/lib/hydrodactyl/wings/*|\
    /var/log/hydrodactyl/wings|/var/log/hydrodactyl/wings/*|\
    /tmp/hydrodactyl-wings|/tmp/hydrodactyl-wings/*)
      ;;
    *)
      return 1
      ;;
  esac
  source_actual=$(wings_actual "$source_path")
  dest_actual=$(wings_actual "$dest_path")
  [ -d "$source_actual" ] || return 0
  mkdir -p "$(dirname "$dest_actual")"
  rm -rf "$dest_actual"
  cp -a "$source_actual" "$dest_actual"
}

wings_migrate_apply() {
  local backup_dir="$1"
  local config_src config_dest source_config
  local root_dir data_dir archive_dir backup_src log_dir tmp_dir
  local collisions=""

  wings_migrate_checkpoint "before-stop" || return 1

  if wings_may_stop_service "wings"; then
    wings_stop_owned_service "wings" || return 1
  fi
  wings_migrate_checkpoint "after-stop" || return 1

  mkdir -p "$(dirname "$(wings_actual /usr/local/bin/hydrodactyl-wings)")"
  cp -a "$(wings_actual /usr/local/bin/wings)" "$(wings_actual /usr/local/bin/hydrodactyl-wings)"
  chmod 755 "$(wings_actual /usr/local/bin/hydrodactyl-wings)"
  wings_migrate_checkpoint "after-copy-binary" || return 1

  config_src=$(wings_actual /etc/pterodactyl)
  config_dest=$(wings_actual /etc/hydrodactyl/wings)
  mkdir -p "$config_dest"
  cp -a "$config_src/." "$config_dest/"
  source_config="$config_dest/config.yml"

  root_dir=$(wings_config_get "$source_config" root_directory || true)
  data_dir=$(wings_config_get "$source_config" data || true)
  archive_dir=$(wings_config_get "$source_config" archive_directory || true)
  backup_src=$(wings_config_get "$source_config" backup_directory || true)
  log_dir=$(wings_config_get "$source_config" log_directory || true)
  tmp_dir=$(wings_config_get "$source_config" tmp_directory || true)

  unset WINGS_DOCKER_NETWORK WINGS_DOCKER_SUBNET WINGS_DOCKER_GATEWAY WINGS_DOCKER_INTERFACE
  unset WINGS_DOCKER_V6_SUBNET WINGS_DOCKER_V6_GATEWAY
  wings_layout_apply namespaced
  wings_choose_docker_network || return 1
  wings_apply_namespaced_runtime "$source_config" || return 1
  wings_migrate_checkpoint "after-copy-config" || return 1

  wings_migrate_copy_tree "$data_dir" "$WINGS_DATA_DIR/volumes" || return 1
  wings_migrate_copy_tree "$archive_dir" "$WINGS_DATA_DIR/archives" || return 1
  wings_migrate_copy_tree "$backup_src" "$WINGS_DATA_DIR/backups" || return 1
  if [ -n "$root_dir" ] && [ -d "$(wings_actual "$root_dir/diffs")" ]; then
    wings_migrate_copy_tree "$root_dir/diffs" "$WINGS_DATA_DIR/diffs" || return 1
  fi
  if [ -n "$root_dir" ] && [ -d "$(wings_actual "$root_dir/vmounts")" ]; then
    wings_migrate_copy_tree "$root_dir/vmounts" "$WINGS_DATA_DIR/vmounts" || return 1
  fi
  wings_migrate_copy_tree "$log_dir" "$WINGS_LOG_DIR" || return 1
  wings_migrate_copy_tree "$tmp_dir" "$WINGS_TMP_DIR" || return 1
  wings_migrate_checkpoint "after-copy-data" || return 1

  local template="${WINGS_SERVICE_TEMPLATE:-}"
  if [ ! -f "$template" ]; then
    template=$(wings_actual /tmp/wings-service.template)
  fi
  [ -n "$template" ] && [ -f "$template" ] || return 1
  wings_install_service_unit "$template" || return 1
  wings_save_layout || return 1
  if [ -f "$(wings_actual /etc/hydrodactyl/auto-update-wings.env)" ]; then
    wings_sync_update_env_paths || return 1
  fi
  wings_migrate_checkpoint "after-write-unit" || return 1

  collisions=$(wings_config_collisions "$source_config" namespaced || true)
  [ -z "$collisions" ] || return 1
  [ "$(wings_checksum "$(wings_actual /etc/pterodactyl/config.yml)")" = "$(grep '^SOURCE_CONFIG_SHA=' "$backup_dir/manifest.env" | cut -d= -f2- | tr -d '"')" ] || return 1
  [ -f "$(wings_actual /usr/local/bin/wings)" ] || return 1
  grep -q -- '--config /etc/hydrodactyl/wings/config.yml' "$(wings_actual /etc/systemd/system/hydrodactyl-wings.service)" || return 1
  wings_migrate_checkpoint "after-verify" || return 1

  if wings_foreign_blocks_start; then
    printf '%s\n' "STARTED_NEW_SERVICE=\"\"" >> "$backup_dir/manifest.env"
  else
    if wings_start_owned_service; then
      printf '%s\n' "STARTED_NEW_SERVICE=\"hydrodactyl-wings\"" >> "$backup_dir/manifest.env"
    else
      return 1
    fi
  fi

  if [ "$(wings_service_unit_kind wings)" = "hydro-legacy" ]; then
    wings_systemctl disable wings || return 1
    printf '%s\n' "DISABLED_OLD_SERVICE=\"wings\"" >> "$backup_dir/manifest.env"
  fi
  return 0
}

wings_migrate_rollback() {
  local backup_dir="$1"
  local manifest disabled was_active was_enabled

  [ -d "$backup_dir" ] || return 1
  manifest="$backup_dir/manifest.env"
  [ -f "$manifest" ] || return 1

  # shellcheck disable=SC1090
  source "$manifest"
  disabled="${DISABLED_OLD_SERVICE:-}"
  was_active="${OLD_SERVICE_WAS_ACTIVE:-0}"
  was_enabled="${OLD_SERVICE_WAS_ENABLED:-0}"

  # The new unit may have been enabled before a later step failed.
  wings_systemctl stop hydrodactyl-wings || true
  wings_systemctl disable hydrodactyl-wings || true

  rm -f "$(wings_actual /usr/local/bin/hydrodactyl-wings)"
  rm -rf "$(wings_actual /etc/hydrodactyl/wings)"
  rm -rf "$(wings_actual /var/lib/hydrodactyl/wings)"
  rm -rf "$(wings_actual /var/log/hydrodactyl/wings)"
  rm -rf "$(wings_actual /tmp/hydrodactyl-wings)"
  rm -f "$(wings_actual /etc/systemd/system/hydrodactyl-wings.service)"

  if [ -f "$backup_dir/wings-layout.env" ]; then
    cp -a "$backup_dir/wings-layout.env" "$(wings_actual /etc/hydrodactyl/wings-layout.env)"
  else
    rm -f "$(wings_actual /etc/hydrodactyl/wings-layout.env)"
  fi
  if [ -f "$backup_dir/auto-update-wings.env" ]; then
    cp -a "$backup_dir/auto-update-wings.env" "$(wings_actual /etc/hydrodactyl/auto-update-wings.env)"
  fi

  if [ -n "$disabled" ] || [ "$was_enabled" = 1 ]; then
    wings_systemctl enable "${disabled:-wings}" || true
  fi
  if [ "$was_active" = 1 ]; then
    wings_systemctl start wings || true
  fi

  [ -f "$(wings_actual /etc/pterodactyl/config.yml)" ] || return 1
  [ "$(wings_checksum "$(wings_actual /etc/pterodactyl/config.yml)")" = "${SOURCE_CONFIG_SHA:-}" ] || return 1
  [ -f "$(wings_actual /usr/local/bin/wings)" ] || return 1
}

# Continue an install that replaces an owned copy. A foreign daemon is not
# stopped here; callers install beside it.
wings_confirm_replace_existing() {
  case "${WINGS_INSTALL_STATE:-}" in
    legacy|namespaced) ;;
    *)
      return 0
      ;;
  esac

  if ! wings_confirm "Continue with installation? This will replace the existing Hydrodactyl Wings installation" "n"; then
    return 1
  fi
  if [ "${WINGS_BINARY_SHARED:-}" = true ]; then
    if ! wings_confirm "Replace the shared Wings binary anyway? Another panel uses it" "n"; then
      return 1
    fi
    WINGS_ALLOW_SHARED_BINARY=1
    export WINGS_ALLOW_SHARED_BINARY
  fi
  wings_stop_owned_service "$WINGS_SERVICE" || true
  return 0
}

wings_runtime_uid() {
  local uid=""
  uid=$(id -u pterodactyl 2>/dev/null || true)
  if [ -n "$uid" ]; then
    printf '%s\n' "$uid"
  else
    printf '%s\n' "9999"
  fi
}

# Volumes stay group-writable so the daemon user can manage them. Wings then
# assigns each server directory to that server's user when it starts.
# Archives and backups are not world-accessible.
wings_apply_data_permissions() {
  local data_root="$1"
  local uid="${2:-}"
  local config_dir="${3:-}"

  [ -n "$data_root" ] || return 1
  mkdir -p "$data_root/volumes" "$data_root/archives" "$data_root/backups"
  if command -v setfacl >/dev/null 2>&1; then
    setfacl -R -b "$data_root/volumes" "$data_root/archives" "$data_root/backups" 2>/dev/null || true
  fi
  chmod 755 "$data_root" || return 1
  chmod 775 "$data_root/volumes" || return 1
  chmod 750 "$data_root/archives" || return 1
  chmod 750 "$data_root/backups" || return 1
  find "$data_root/volumes" -mindepth 1 -exec chmod o-w {} + 2>/dev/null || true
  find "$data_root/archives" "$data_root/backups" -mindepth 1 -exec chmod o-rwx {} + 2>/dev/null || true
  if [ -n "$uid" ]; then
    chown -R "${uid}:${uid}" "$data_root/volumes" "$data_root/archives" "$data_root/backups" 2>/dev/null || true
  fi
  if [ -n "$config_dir" ] && [ -d "$config_dir" ]; then
    find "$config_dir" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$config_dir" -type f -name 'config.yml' -exec chmod 600 {} \; 2>/dev/null || true
    find "$config_dir" -type f ! -name 'config.yml' -exec chmod 640 {} \; 2>/dev/null || true
  fi
}

wings_migrate_to_namespaced() {
  local backup_dir=""

  if ! wings_migrate_validate; then
    return 1
  fi
  if ! wings_confirm "Copy this Hydrodactyl Wings install to the Hydrodactyl paths? The current files stay in place." "n"; then
    return 1
  fi

  backup_dir=$(wings_migrate_backup) || return 1
  if ! wings_migrate_apply "$backup_dir"; then
    wings_migrate_rollback "$backup_dir" || return 1
    return 1
  fi
  printf '%s\n' "$backup_dir"
}
