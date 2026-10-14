#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Hydrodactyl Wings Installer                                                        #
#                                                                                    #
# Supports both Pterodactyl Wings (Go) and wings-rs (Rust)                           #
#                                                                                    #
# Copyright (C) 2026, ItzzMateo Studios                                             #
#                                                                                    #
######################################################################################

# Check if lib is loaded, load if not or fail otherwise.
fn_exists() { declare -F "$1" >/dev/null; }
if ! fn_exists lib_loaded; then
  if [ -f /tmp/hydrodactyl-lib.sh ]; then
    if ! source /tmp/hydrodactyl-lib.sh 2>/dev/null; then
      rm -f /tmp/hydrodactyl-lib.sh
    fi
  fi
  if ! fn_exists lib_loaded; then
    # shellcheck source=../lib/lib.sh
    source <(curl -sSL "${GITHUB_BASE_URL:-"https://raw.githubusercontent.com/itzzjustmateo/hydro-install"}/${GITHUB_SOURCE:-"main"}/lib/lib.sh")
  fi
  ! fn_exists lib_loaded && echo "* ERROR: Could not load lib script" && exit 1
fi

# ------------------ Command Line Arguments ----------------- #

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --fqdn|-f)
        FQDN="$2"
        shift 2
        ;;
      --panel-url|-u)
        PANEL_URL="$2"
        shift 2
        ;;
      --panel-fqdn)
        PANEL_FQDN="$2"
        FQDN="$2"
        shift 2
        ;;
      --api-key|-k)
        PANEL_API_KEY="$2"
        shift 2
        ;;
      --node-name|-n)
        NODE_NAME="$2"
        shift 2
        ;;
      --node-token|-t)
        NODE_TOKEN="$2"
        shift 2
        ;;
      --node-id|-i)
        NODE_ID="$2"
        shift 2
        ;;
      --memory|-m)
        NODE_MEMORY="$2"
        shift 2
        ;;
      --disk|-d)
        NODE_DISK="$2"
        shift 2
        ;;
      --port-start)
        GAME_PORT_START_PARAM="$2"
        GAME_PORT_START="$2"
        shift 2
        ;;
      --port-end)
        GAME_PORT_END_PARAM="$2"
        GAME_PORT_END="$2"
        shift 2
        ;;
      --variant)
        WINGS_VARIANT="$2"
        shift 2
        ;;
      --configure-firewall)
        CONFIGURE_FIREWALL="true"
        shift
        ;;
      --no-firewall)
        CONFIGURE_FIREWALL="false"
        shift
        ;;
      --behind-proxy)
        BEHIND_PROXY="true"
        shift
        ;;
      --github-token|-g)
        GITHUB_TOKEN="$2"
        shift 2
        ;;
      --wings-repo)
        WINGS_REPO="$2"
        shift 2
        ;;
      --skip-wings-setup)
        SKIP_WINGS_SETUP="true"
        shift
        ;;
      --assume-ssl)
        ASSUME_SSL="true"
        shift
        ;;
      --configure-letsencrypt)
        CONFIGURE_LETSENCRYPT="true"
        shift
        ;;
      --ssl-email)
        SSL_EMAIL="$2"
        shift 2
        ;;
      --help|-h)
        show_help
        exit 0
        ;;
      *)
        echo "Unknown option: $1"
        show_help
        exit 1
        ;;
    esac
  done
}

show_help() {
  cat << EOF
Wings Installer - Command Line Options

Usage: wings.sh [OPTIONS]

Connection (provide these or you'll be prompted):
  --fqdn, -f <fqdn>              This node's FQDN (e.g., node.example.com)
  --panel-url, -u <url>          Panel URL to connect to (e.g., https://panel.example.com)
  --api-key, -k <key>            Panel API key for automatic node setup
  --node-name, -n <name>         Node name (default: hostname)
  --node-token, -t <token>       Node token for manual setup
  --node-id, -i <id>             Node ID for manual setup

Resources (optional, auto-detected if not provided):
  --memory, -m <mb>              Memory limit in MB
  --disk, -d <mb>                Disk limit in MB
  --port-start <port>            Game port range start (default: 27015)
  --port-end <port>              Game port range end (default: 28025)

Options:
  --variant <go|rs>              Wings variant: go (Pterodactyl) or rs (wings-rs)
  --configure-firewall           Enable firewall configuration
  --no-firewall                  Disable firewall configuration
  --behind-proxy                 Node is behind a proxy
  --assume-ssl                   Assume SSL is already configured
  --configure-letsencrypt        Obtain SSL certificate via Let's Encrypt
  --ssl-email <email>            Email for Let's Encrypt registration
  --github-token, -g <token>     GitHub token for private repos
  --wings-repo <repo>            Wings repository (default: pterodactyl/wings or calagopus/wings)
  --skip-wings-setup             Skip Wings detection/setup
  --help, -h                     Show this help message

Examples:
  wings.sh --variant go --fqdn node.example.com --panel-url https://panel.example.com --api-key pte_xxx
  wings.sh --variant rs --fqdn node.example.com --panel-url https://panel.example.com --api-key pte_xxx

EOF
}

parse_arguments "$@"

# ------------------ Variables ----------------- #

# Resolved in main() from the saved layout, or the namespaced defaults.
WINGS_INSTALL_DIR=""
PANEL_CONFIG_DIR="${PANEL_CONFIG_DIR:-/etc/hydrodactyl}"
WINGS_VARIANT="${WINGS_VARIANT:-go}"
WINGS_VARIANT=$(echo "$WINGS_VARIANT" | tr '[:upper:]' '[:lower:]')
# Validate here, before install_docker/directory/user setup run, instead of
# only in wings_release_arch() deep inside install_wings() - a typo like
# "--variant Go" would otherwise waste that work before failing.
case "$WINGS_VARIANT" in
  go | rs) ;;
  *)
    error "Unsupported Wings variant: $WINGS_VARIANT (expected 'go' or 'rs')"
    exit 1
    ;;
esac
# Repo default depends on variant (pterodactyl/wings vs calagopus/wings) and
# is resolved in install_wings() - do not default it here, or a
# variant-specific default below would never apply once this is non-empty.
WINGS_REPO="${WINGS_REPO:-}"

PANEL_URL="${PANEL_URL:-}"
NODE_TOKEN="${NODE_TOKEN:-}"
NODE_ID="${NODE_ID:-}"

PANEL_API_KEY="${PANEL_API_KEY:-}"

BEHIND_PROXY="${BEHIND_PROXY:-false}"
FQDN="${FQDN:-}"

CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-false}"
GAME_PORT_START="${GAME_PORT_START:-27015}"
GAME_PORT_END="${GAME_PORT_END:-28025}"

WINGS_REPO_PRIVATE="${WINGS_REPO_PRIVATE:-false}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
WINGS_RELEASE_VERSION="${WINGS_RELEASE_VERSION:-latest}"

NODE_NAME="${NODE_NAME:-}"
NODE_MEMORY="${NODE_MEMORY:-}"
NODE_DISK="${NODE_DISK:-}"
PANEL_FQDN="${PANEL_FQDN:-}"

export SKIP_WINGS_SETUP="${SKIP_WINGS_SETUP:-false}"
export ASSUME_SSL="${ASSUME_SSL:-false}"
export CONFIGURE_LETSENCRYPT="${CONFIGURE_LETSENCRYPT:-false}"
export SSL_EMAIL="${SSL_EMAIL:-}"
export SSL_CERT_PATH="${SSL_CERT_PATH:-}"
export SSL_KEY_PATH="${SSL_KEY_PATH:-}"

missing=()
partial_creds=false

if [[ -n "$PANEL_API_KEY" ]]; then
  :
elif [[ -n "$PANEL_URL" || -n "$NODE_TOKEN" || -n "$NODE_ID" ]]; then
  for var in PANEL_URL NODE_TOKEN NODE_ID; do
    if [[ -z "${!var}" ]]; then
      missing+=("$var")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    partial_creds=true
  fi
fi

if [[ "$partial_creds" == true ]]; then
  print_header
  print_flame "Missing Required Variables"
  for m in "${missing[@]}"; do
    error "${m} is required (or provide PANEL_API_KEY for automatic setup)"
  done
  exit 1
fi

# ---------------- Installation Functions ---------------- #

check_existing() {
  if [ "$WINGS_FOREIGN_PRESENT" = true ]; then
    output "Another Wings install is already on this machine. It will not be stopped or overwritten."
    output "Hydrodactyl Wings will use:"
    output "  Binary:  ${WINGS_BINARY}"
    output "  Config:  ${WINGS_CONFIG_DIR}"
    output "  Data:    ${WINGS_DATA_DIR}"
    output "  Service: ${WINGS_SERVICE}.service"
  fi
  if ! wings_confirm_replace_existing; then
    error "Installation aborted."
    exit 1
  fi
}

install_wings() {
  print_flame "Installing Wings Daemon"

  install_docker

  if ! wings_finalize_docker_network; then
    error "Could not find a free Docker network. Existing networks could not be read, or every candidate subnet is in use."
    exit 1
  fi

  output "Creating Wings directories..."
  wings_prepare_directories || { error "Failed to create Wings directories"; return 1; }
  mkdir -p "$PANEL_CONFIG_DIR" || { error "Failed to create $PANEL_CONFIG_DIR"; return 1; }

  output "Creating pterodactyl system group..."
  if ! getent group pterodactyl >/dev/null 2>&1; then
    groupadd --gid 9999 pterodactyl 2>/dev/null || true
  fi

  output "Creating pterodactyl system user..."
  if ! id -u pterodactyl >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin --uid 9999 --gid 9999 pterodactyl 2>/dev/null || \
    useradd --system --no-create-home --shell /sbin/nologin --uid 9999 --gid 9999 pterodactyl 2>/dev/null || \
    useradd --system --no-create-home --shell /bin/false --uid 9999 --gid 9999 pterodactyl
  fi

  if getent group docker >/dev/null 2>&1; then
    output "Adding pterodactyl user to docker group..."
    usermod -aG docker pterodactyl 2>/dev/null || true
  fi

  local arch
  arch=$(wings_release_arch "$WINGS_VARIANT") || exit 1

  local asset_name
  if [ "$WINGS_VARIANT" == "go" ]; then
    asset_name="wings_linux_${arch}"
    WINGS_REPO="${WINGS_REPO:-pterodactyl/wings}"
  else
    asset_name="wings-rs-${arch}-linux"
    WINGS_REPO="${WINGS_REPO:-calagopus/wings}"
  fi

  local target_release="$WINGS_RELEASE_VERSION"
  if [ "$target_release" == "latest" ]; then
    output "Fetching latest Wings release..."
    target_release=$(get_latest_release "$WINGS_REPO" "$GITHUB_TOKEN")
  else
    output "Fetching Wings release ${WINGS_RELEASE_VERSION}..."
  fi

  if [ -z "$target_release" ] || [ "$target_release" == "null" ]; then
    error "Could not fetch release from $WINGS_REPO"
    if [ "$WINGS_RELEASE_VERSION" != "latest" ]; then
      error "Release ${WINGS_RELEASE_VERSION} may not exist."
    fi
    exit 1
  fi

  info "Installing release: $target_release"

  if ! wings_may_modify_path "$WINGS_BINARY"; then
    error "Refusing to overwrite ${WINGS_BINARY}"
    exit 1
  fi

  output "Downloading Wings binary..."
  if ! download_release_asset "$WINGS_REPO" "$asset_name" "$WINGS_BINARY" "$GITHUB_TOKEN" "$target_release"; then
    error "Failed to download Wings binary"
    exit 1
  fi

  chmod +x "$WINGS_BINARY"

  mkdir -p /etc/hydrodactyl
  echo "$target_release" > /etc/hydrodactyl/wings-version
  chmod 644 /etc/hydrodactyl/wings-version

  # Persist the installed variant/repo and the paths this install uses.
  save_wings_update_config

  if "$WINGS_BINARY" --version >/dev/null 2>&1; then
    info "Wings binary verified: $("$WINGS_BINARY" --version 2>/dev/null || echo 'unknown')"
  fi

  success "Wings installed to ${WINGS_BINARY}"
}

ask_skip_auto_config() {
  local skip_auto=""

  echo ""
  output "Auto-configuration will:"
  output "  • Create a new location (or use existing) in your panel"
  output "  • Create a new node in your panel"
  output "  • Automatically configure Wings with the new node"
  echo ""

  bool_input skip_auto "Would you like to skip auto-configuration and configure manually?" "n"

  if [ "$skip_auto" == "y" ]; then
    return 0
  else
    return 1
  fi
}

auto_configure_wings() {
  print_flame "Auto-Configuring Wings via API"

  local api_key="$1"
  local panel_url="$2"
  local node_name="${3:-}"
  [ -z "$node_name" ] && node_name="Wings-Node-$(hostname -s)"

  output "Starting automatic Wings configuration..."
  output "Node name: ${COLOR_ORANGE}${node_name}${COLOR_NC}"

  output ""
  output "Step 1: Setting up location..."
  local country_code
  country_code=$(get_server_country_code)
  info "Detected country code: ${country_code}"

  local location_id
  if ! location_id=$(get_or_create_location "$api_key" "$panel_url" "$country_code"); then
    error "Failed to set up location"
    return 1
  fi

  output ""
  output "Step 2: Creating node..."
  local memory_mb
  local disk_mb
  memory_mb=$(get_system_memory)
  disk_mb=$(df -m / | awk 'NR==2 {print $2}')

  local node_fqdn
  if [ -n "$FQDN" ]; then
    node_fqdn="$FQDN"
    info "Using configured node FQDN: ${node_fqdn}"
  else
    node_fqdn=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "")
    if [ -z "$node_fqdn" ] || [ "$node_fqdn" == "localhost" ]; then
      error "Could not determine node FQDN"
      error "Set FQDN via --fqdn flag or FQDN environment variable"
      error "Example: wings.sh --fqdn node.example.com"
      return 1
    else
      info "Detected node FQDN from hostname: ${node_fqdn}"
    fi
  fi

  if ! NODE_ID=$(create_node_via_api "$api_key" "$panel_url" "$location_id" "$node_name" "$memory_mb" "$disk_mb" "false" "$node_fqdn" "wings" "$(daemon_scheme)"); then
    error "Failed to create node"
    return 1
  fi

  success "Node created successfully"
  info "Node ID: ${NODE_ID}"

  output ""
  output "Step 3: Configuring Wings..."
  configure_wings "${panel_url}" "${api_key}" "${NODE_ID}" || return 1

  success "Wings auto-configuration complete!"
  return 0
}

install_letsencrypt_wings() {
  local fqdn="$1"
  local email="$2"

  output "Installing Certbot and obtaining SSL certificate..."

  case "$OS" in
    ubuntu|debian)
      install_packages "certbot"
      ;;
    rocky|almalinux|fedora|rhel|centos)
      install_packages "certbot"
      ;;
  esac

  local stopped_service=""
  if ss -tlnp 2>/dev/null | grep -q ':80 '; then
    output "Port 80 is in use - attempting to free it for certbot verification..."
    local port_80_pid
    port_80_pid=$(ss -tlnp 2>/dev/null | grep ':80 ' | head -1 | grep -oP 'pid=\K[0-9]+' || true)
    if [ -n "$port_80_pid" ]; then
      local port_80_service
      port_80_service=$(systemctl status "$port_80_pid" 2>/dev/null | grep -oP '.*\.service' | head -1 || true)
      if [ -n "$port_80_service" ]; then
        output "Temporarily stopping ${port_80_service} for certbot verification..."
        if systemctl stop "$port_80_service" 2>/dev/null; then
          stopped_service="$port_80_service"
          sleep 2
        fi
      fi
    fi

    if [ -z "$stopped_service" ]; then
      for svc in nginx apache2 httpd caddy; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
          output "Temporarily stopping ${svc} for certbot verification..."
          if systemctl stop "$svc" 2>/dev/null; then
            stopped_service="$svc"
            sleep 2
            break
          fi
        fi
      done
    fi
  fi

  local certbot_args="certonly --standalone -d $fqdn --non-interactive --agree-tos"
  if [ -n "$email" ]; then
    certbot_args="$certbot_args --email $email"
  else
    certbot_args="$certbot_args --register-unsafely-without-email"
  fi

  if ! certbot $certbot_args; then
    warning "Certbot failed to obtain certificate for ${fqdn}"
    if [ -n "$stopped_service" ]; then
      output "Restarting ${stopped_service}..."
      systemctl start "$stopped_service" 2>/dev/null || true
    fi
    return 1
  fi

  if [ -n "$stopped_service" ]; then
    output "Restarting ${stopped_service}..."
    systemctl start "$stopped_service" 2>/dev/null || true
  fi

  success "SSL certificate obtained for ${fqdn}"
  setup_certbot_renewal
}

configure_wings() {
  local panel_url="${1:-$PANEL_URL}"
  local api_key="${2:-$PANEL_API_KEY}"
  local node_id="${3:-$NODE_ID}"

  if [ -z "$panel_url" ]; then
    error "Panel URL is required."
    return 1
  fi

  if [ -z "$api_key" ]; then
    error "API key is required."
    return 1
  fi

  if [ -z "$node_id" ]; then
    error "Node ID is required."
    return 1
  fi

  print_flame "Configuring Wings"

  output "Creating Wings config directory at ${WINGS_INSTALL_DIR}..."
  mkdir -p "${WINGS_INSTALL_DIR}"
  if [ ! -d "${WINGS_INSTALL_DIR}" ]; then
    error "Failed to create Wings config directory at ${WINGS_INSTALL_DIR}"
    return 1
  fi

  local node_fqdn
  if [ -n "$FQDN" ]; then
    node_fqdn="$FQDN"
  else
    if [ "$CONFIGURE_LETSENCRYPT" == true ]; then
      warning "Let's Encrypt requested but node FQDN not set"
    fi
    node_fqdn=""
  fi

  output "Configuring Wings..."
  output "Panel URL: ${panel_url}"
  output "Node ID: ${node_id}"

  if [ "$WINGS_VARIANT" == "go" ]; then
    output "Using Wings configure command..."
  else
    output "wings-rs uses panel-based configuration..."
  fi
  if ! wings_run_configure "${panel_url}" "${api_key}" "${node_id}"; then
    return 1
  fi

  output "Wings configured successfully"

  output "Configuring SSL for Wings..."

  if [ "$CONFIGURE_LETSENCRYPT" == true ]; then
    if [ -n "$node_fqdn" ]; then
      output "Obtaining Let's Encrypt certificate for ${node_fqdn}..."
      install_letsencrypt_wings "$node_fqdn" "${SSL_EMAIL:-}"
    else
      warning "Cannot obtain Let's Encrypt certificate - node FQDN not configured"
    fi
  fi

  local ssl_cert_path=""
  local ssl_key_path=""

  if [ -n "$SSL_CERT_PATH" ] && [ -n "$SSL_KEY_PATH" ] && [ -f "$SSL_CERT_PATH" ] && [ -f "$SSL_KEY_PATH" ]; then
    ssl_cert_path="$SSL_CERT_PATH"
    ssl_key_path="$SSL_KEY_PATH"
    output "Using custom SSL certificate: ${ssl_cert_path}"
  elif [ -n "$node_fqdn" ] && [ -f "/etc/letsencrypt/live/${node_fqdn}/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/${node_fqdn}/privkey.pem" ]; then
    ssl_cert_path="/etc/letsencrypt/live/${node_fqdn}/fullchain.pem"
    ssl_key_path="/etc/letsencrypt/live/${node_fqdn}/privkey.pem"
    output "Found Let's Encrypt certificates at /etc/letsencrypt/live/${node_fqdn}/"
  fi

  if [ -f "${WINGS_INSTALL_DIR}/config.yml" ]; then
    if [ -n "$ssl_cert_path" ] && [ -n "$ssl_key_path" ]; then
      # A real cert is available - make sure config.yml actually uses it,
      # regardless of what 'wings configure' assumed from the node's scheme.
      # The "enabled:" flip is scoped to the api.ssl block (the /ssl:/,/certificate:/
      # address range) - a bare `s/enabled: false/enabled: true/` would also
      # match unrelated "enabled:" keys elsewhere in config.yml (e.g.
      # throttles.enabled).
      sed -i '/ssl:/,/certificate:/{s/enabled: false/enabled: true/}' "${WINGS_INSTALL_DIR}/config.yml" 2>/dev/null || true
      sed -i "s|certificate: .*|certificate: ${ssl_cert_path}|" "${WINGS_INSTALL_DIR}/config.yml" 2>/dev/null || true
      sed -i "s|key: .*|key: ${ssl_key_path}|" "${WINGS_INSTALL_DIR}/config.yml" 2>/dev/null || true
      success "SSL configured for Wings"
    else
      # No usable cert - force SSL off regardless of what 'wings configure'
      # defaulted to, so Wings never tries to load a certificate that
      # doesn't exist (defense in depth alongside the daemon_scheme() fix
      # in create_node_via_api()). Same api.ssl-scoped range as above.
      sed -i '/ssl:/,/certificate:/{s/enabled: true/enabled: false/}' "${WINGS_INSTALL_DIR}/config.yml" 2>/dev/null || true
      if [ -z "$node_fqdn" ]; then
        warning "Skipping SSL - node FQDN not configured"
      else
        warning "SSL certificates not found for ${node_fqdn}"
      fi
    fi
  fi

  if [ -n "$ssl_cert_path" ] && [ -n "$ssl_key_path" ]; then
    ASSUME_SSL="true"
  fi

  output ""
  output "Creating allocations..."
  create_node_allocations "$api_key" "$panel_url" "$node_id" "${GAME_PORT_START:-25565}" "${GAME_PORT_END:-25665}" || true

  success "Wings configured"
}

setup_systemd_service() {
  print_flame "Setting up Systemd Service"

  output "Setting up ${WINGS_SERVICE}.service..."

  if ! install_wings_systemd_unit; then
    exit 1
  fi

  success "Wings service created"
}

start_wings() {
  print_flame "Starting Wings"

  output "Starting Wings service..."
  local start_status=0
  wings_start_owned_service || start_status=$?

  if [ "$start_status" -eq 2 ]; then
    warning "Another Wings service is running and has the API port, so ${WINGS_SERVICE} was not started."
    warning "Stop that service, then run: systemctl enable --now ${WINGS_SERVICE}"
    WINGS_START_RESULT=blocked
    export WINGS_START_RESULT
    return 2
  fi

  sleep 3

  if [ "$start_status" -eq 0 ] && systemctl is-active --quiet "$WINGS_SERVICE"; then
    success "Wings is running"
    if wings_foreign_reboot_conflict; then
      warning "Another Wings service is enabled. Both use ports 8080 and 2022, so only one stays up after a reboot."
    fi
    WINGS_START_RESULT=started
  else
    warning "Wings service may not have started properly"
    warning "Check status with: systemctl status ${WINGS_SERVICE}"
    WINGS_START_RESULT=uncertain
  fi
  export WINGS_START_RESULT
}

verify_connection() {
  print_flame "Verifying Connection"

  output "Waiting for Wings to initialize..."
  sleep 5

  if ! systemctl is-active --quiet "$WINGS_SERVICE"; then
    warning "Wings service is not running"
    warning "Check logs with: journalctl -u ${WINGS_SERVICE} -f"
    return 1
  fi

  output "Checking connection to panel..."

  if curl -s -o /dev/null -w "%{http_code}" "${PANEL_URL}/api/health" | grep -qE "200|204"; then
    success "Successfully connected to panel"
  else
    warning "Could not verify connection to panel"
    warning "The node may still be initializing"
  fi

  if curl -s -o /dev/null -w "%{http_code}" "http://localhost:8080/api/system" | grep -qE "200"; then
    success "Wings API is responding"
  else
    info "Wings API is not yet responding (this is normal during first start)"
  fi
}

configure_firewall() {
  if [ "$CONFIGURE_FIREWALL" == true ]; then
    print_flame "Configuring Firewall"

    if [ -z "${GAME_PORT_START_PARAM:-}" ] || [ -z "${GAME_PORT_END_PARAM:-}" ]; then
      ask_game_ports GAME_PORT_START GAME_PORT_END
    fi

    output "Opening ports for Wings daemon and game servers..."
    output "  • 22 (SSH)"
    output "  • 80 (HTTP - needed for certbot renewal)"
    if [ "$CONFIGURE_LETSENCRYPT" == true ] || [ "$ASSUME_SSL" == true ] || [ -n "$SSL_CERT_PATH" ]; then
      output "  • 443 (HTTPS/SSL)"
    fi
    output "  • 8080 (Wings API)"
    output "  • 2022 (SFTP)"
    output "  • 25565-25665 (Minecraft)"
    output "  • 27015-27150 (Source Engine - CS:GO, TF2, GMod)"
    output "  • 7777-8000 (Unreal Engine - ARK, Satisfactory)"
    output "  • 28015-28025 (Rust)"
    output "  • 2456-2466 (Valheim)"
    output "  • 30120-30130 (FiveM/GTA)"
    output "  • ${GAME_PORT_START}-${GAME_PORT_END} (Additional range)"

    configure_firewall_rules true true true "$GAME_PORT_START" "$GAME_PORT_END"
  fi
}

# ---------------- Main ---------------- #

main() {
  print_header
  print_flame "Starting Wings Installation"

  if ! wings_preflight_os; then
    error "Wings installation requires Linux with systemd."
    exit 1
  fi
  if ! wings_resolve_for_action install; then
    error "Could not choose a safe Wings install layout."
    exit 1
  fi

  check_existing
  install_wings

  if [ -n "$PANEL_API_KEY" ] && [ -n "$PANEL_URL" ]; then
    if ask_skip_auto_config; then
      output ""
      output "Skipping auto-configuration."
      output ""
      output "You chose to manually configure Wings. To configure later, run:"
      output "  ${COLOR_ORANGE}${WINGS_BINARY} --config ${WINGS_CONFIG_FILE} configure \\"
      output "    --panel-url 'https://your-panel.com' \\"
      output "    --token 'your-api-key' \\"
      output "    --node 'your-node-id'${COLOR_NC}"
      output ""
      output "Press Enter to continue with installation (Wings will not be fully configured)..."
      read -r
    else
      local _node_name="${NODE_NAME:-}"
      [ -z "$_node_name" ] && _node_name="Wings-Node-$(hostname -s)"
      if auto_configure_wings "$PANEL_API_KEY" "$PANEL_URL" "$_node_name"; then
        success "Wings auto-configured via API"
      else
        error "Auto-configuration failed."
        error ""
        error "You can manually configure Wings later by running:"
        error "  ${WINGS_BINARY} --config ${WINGS_CONFIG_FILE} configure \\"
        error "    --panel-url '${PANEL_URL}' \\"
        error "    --token '<your-api-key>' \\"
        error "    --node '<node-id>'"
        exit 1
      fi
    fi
  elif [ -n "$PANEL_URL" ] && [ -n "$PANEL_API_KEY" ] && [ -n "$NODE_ID" ]; then
    output "Manual configuration credentials detected."
    configure_wings "${PANEL_URL}" "${PANEL_API_KEY}" "${NODE_ID}"
  else
    output ""
    output "No API credentials provided."
    output ""
    output "To configure Wings, you need:"
    output "  1. Panel URL (e.g., https://panel.example.com)"
    output "  2. Panel API Key"
    output "  3. Node ID (create a node in your panel first)"
    output "  4. This node's FQDN (for SSL certificate setup)"
    output ""

    local do_manual=""
    bool_input do_manual "Would you like to enter configuration details now?" "y"

    if [ "$do_manual" == "y" ]; then
      echo ""
      read -rp "* Enter Panel URL: " PANEL_URL
      read -rp "* Enter Panel API Key: " PANEL_API_KEY
      read -rp "* Enter Node ID: " NODE_ID
      echo ""

      if [ -z "$FQDN" ]; then
        output ""
        output "Enter the FQDN for this node (e.g., node.example.com)"
        read -rp "* Node FQDN: " FQDN
      fi
      echo ""

      configure_wings "${PANEL_URL}" "${PANEL_API_KEY}" "${NODE_ID}"
    else
      output ""
      output "Skipping configuration. Wings is installed but not configured."
      output ""
      output "To configure later, run:"
      output "  ${COLOR_ORANGE}${WINGS_BINARY} --config ${WINGS_CONFIG_FILE} configure \\"
      output "    --panel-url 'https://your-panel.com' \\"
      output "    --token 'your-api-key' \\"
      output "    --node 'your-node-id'${COLOR_NC}"
    fi
  fi

  if [ -f "${WINGS_INSTALL_DIR}/config.yml" ]; then
    install_rustic
    setup_systemd_service
    start_wings

    configure_firewall
    verify_connection
  fi

  print_header
  print_flame "Installation Complete!"

  echo ""
  case "${WINGS_START_RESULT:-}" in
    blocked|uncertain)
      output "Wings is installed, but the service is not running."
      ;;
    started)
      output "Wings has been installed and the service is running."
      ;;
    *)
      output "Wings has been installed."
      ;;
  esac
  echo ""

  if [ -f "${WINGS_INSTALL_DIR}/config.yml" ]; then
    output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    output "  Connection Details"
    output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    output "Panel URL: ${COLOR_ORANGE}${PANEL_URL:-Not configured}${COLOR_NC}"
    output "Node ID: ${COLOR_ORANGE}${NODE_ID:-Not configured}${COLOR_NC}"
    if [ -n "$PANEL_API_KEY" ]; then
      output "Setup Method: ${COLOR_ORANGE}Automatic (via API)${COLOR_NC}"
    else
      output "Setup Method: ${COLOR_ORANGE}Manual${COLOR_NC}"
    fi
    output "Configuration: ${COLOR_ORANGE}${WINGS_INSTALL_DIR}/config.yml${COLOR_NC}"
    output "Node FQDN: ${COLOR_ORANGE}${FQDN:-Not configured}${COLOR_NC}"
    if [ "$CONFIGURE_LETSENCRYPT" == true ]; then
      output "SSL: ${COLOR_ORANGE}Let's Encrypt${COLOR_NC}"
    elif [ -n "$SSL_CERT_PATH" ] && [ -n "$SSL_KEY_PATH" ]; then
      output "SSL: ${COLOR_ORANGE}Custom Certificate${COLOR_NC}"
    elif [ "$ASSUME_SSL" == true ]; then
      output "SSL: ${COLOR_ORANGE}Assumed (external)${COLOR_NC}"
    else
      output "SSL: ${COLOR_ORANGE}None${COLOR_NC}"
    fi
    echo ""

    if [ "$CONFIGURE_FIREWALL" == "true" ]; then
      output "Game Server Ports Configured (TCP & UDP):"
      output "  ${COLOR_ORANGE}25565-25665${COLOR_NC}: Minecraft"
      output "  ${COLOR_ORANGE}27015-27150${COLOR_NC}: Source Engine (CS:GO, TF2, GMod)"
      output "  ${COLOR_ORANGE}7777-8000${COLOR_NC}: ARK, Satisfactory, etc."
      output "  ${COLOR_ORANGE}28015-28025${COLOR_NC}: Rust"
      output "  ${COLOR_ORANGE}2456-2466${COLOR_NC}: Valheim"
      output "  ${COLOR_ORANGE}30120-30130${COLOR_NC}: FiveM/GTA"
      output "  ${COLOR_ORANGE}$GAME_PORT_START-$GAME_PORT_END${COLOR_NC}: General range"
      echo ""
    fi

    output "Service Commands:"
    output "  ${COLOR_ORANGE}systemctl status ${WINGS_SERVICE}${COLOR_NC}    - Check service status"
    output "  ${COLOR_ORANGE}systemctl restart ${WINGS_SERVICE}${COLOR_NC}   - Restart service"
    output "  ${COLOR_ORANGE}journalctl -u ${WINGS_SERVICE} -f${COLOR_NC}   - View logs"
    echo ""
  else
    output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    output "  Configuration Required"
    output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    output "Wings is installed but NOT configured."
    output ""
    output "The config directory has been created at ${WINGS_INSTALL_DIR}."
    output "To complete setup, run:"
    output ""
    output "  ${COLOR_ORANGE}${WINGS_BINARY} --config ${WINGS_CONFIG_FILE} configure \\"
    output "    --panel-url 'https://your-panel.com' \\"
    output "    --token 'your-api-key' \\"
    output "    --node 'your-node-id'${COLOR_NC}"
    output ""
    output "Then enable the service:"
    output "  ${COLOR_ORANGE}systemctl enable --now ${WINGS_SERVICE}${COLOR_NC}"
    echo ""
  fi


  print_brake 70

  save_wings_install_info "install"

  echo ""
  output "Installation finished, press Enter to view details..."
  read -r

  show_wings_completion "install"

  if [ -f "${WINGS_INSTALL_DIR}/config.yml" ]; then
    echo ""
    output "Running post-installation health check..."
    check_wings_health
  fi
}

main
