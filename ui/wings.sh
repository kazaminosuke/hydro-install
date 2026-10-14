#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Hydrodactyl Wings Installation UI                                                  #
#                                                                                    #
# Copyright (C) 2026, ItzzMateo Studios                                             #
#                                                                                    #
######################################################################################

# Check if lib is loaded, load if not or fail otherwise.
fn_exists() { declare -F "$1" >/dev/null; }
if ! fn_exists lib_loaded; then
  # Try temp file first (when run through install.sh)
  # Only a copy this user owns and nobody else can write; /tmp is shared.
  if [ -f /tmp/hydrodactyl-lib.sh ] && [ ! -L /tmp/hydrodactyl-lib.sh ] && [ -O /tmp/hydrodactyl-lib.sh ] \
    && [ -z "$(find /tmp/hydrodactyl-lib.sh -perm /022 2>/dev/null)" ]; then
    # shellcheck source=../lib/lib.sh
    if ! source /tmp/hydrodactyl-lib.sh 2>/dev/null; then
      # Temp file exists but failed to load (corrupt/invalid) - remove it
      rm -f /tmp/hydrodactyl-lib.sh
    fi
  fi
  # Fall back to downloading if temp file didn't load or doesn't exist
  if ! fn_exists lib_loaded; then
    # shellcheck source=../lib/lib.sh
    source <(curl -sSL "${GITHUB_BASE_URL:-"https://raw.githubusercontent.com/itzzjustmateo/hydro-install"}/${GITHUB_SOURCE:-"main"}/lib/lib.sh")
  fi
  ! fn_exists lib_loaded && echo "* ERROR: Could not load lib script" && exit 1
fi

# ------------------ Configuration Variables ----------------- #

WINGS_REPO=""
WINGS_VARIANT=""
WINGS_REPO_PRIVATE=false
GITHUB_TOKEN=""
WINGS_RELEASE_VERSION="${WINGS_RELEASE_VERSION:-latest}"
PANEL_URL=""
NODE_TOKEN=""
NODE_ID=""
CONFIGURE_FIREWALL=false
CONFIGURE_LETSENCRYPT=false
SSL_CERT_PATH=""
SSL_KEY_PATH=""
SSL_EMAIL=""
BEHIND_PROXY=false
FQDN=""
# The installer resolves the config directory. Do not export a fixed path.

# ------------------ Wings Variant Selection ----------------- #

configure_wings_variant() {
  print_header
  print_flame "Wings Variant Selection"

  output "Which Wings variant would you like to install?"
  echo ""
  output "[${COLOR_ORANGE}0${COLOR_NC}] Pterodactyl Wings (Go)"
  output "    The official Pterodactyl server daemon, written in Go."
  output "    Most stable, widely used, and battle-tested in production."
  output "    Best for: production environments, maximum compatibility."
  echo ""
  output "[${COLOR_ORANGE}1${COLOR_NC}] wings-rs (Rust)"
  output "    A lightweight Rust reimplementation of Wings."
  output "    Lower memory usage, faster startup, additional features."
  output "    Best for: resource-constrained servers, advanced users."
  echo ""

  local variant_choice=""
  while [[ "$variant_choice" != "0" && "$variant_choice" != "1" ]]; do
    echo -n "* Select [0-1]: "
    read -r variant_choice
    if [[ "$variant_choice" != "0" && "$variant_choice" != "1" ]]; then
      error "Invalid selection. Please enter 0 or 1."
    fi
  done

  if [ "$variant_choice" == "0" ]; then
    WINGS_VARIANT="go"
    WINGS_REPO="$DEFAULT_WINGS_REPO"
    output "Selected: Pterodactyl Wings (Go) - ${COLOR_ORANGE}${WINGS_REPO}${COLOR_NC}"
  else
    WINGS_VARIANT="rs"
    WINGS_REPO="$DEFAULT_WINGS_RS_REPO"
    output "Selected: wings-rs (Rust) - ${COLOR_ORANGE}${WINGS_REPO}${COLOR_NC}"
  fi
}

# ------------------ Repository Configuration ----------------- #

configure_github_repository() {
  print_header
  print_flame "GitHub Repository Configuration"

  output "The default repository for this variant is:"
  output "  ${COLOR_ORANGE}${WINGS_REPO}${COLOR_NC}"
  echo ""

  local use_default=""
  bool_input use_default "Use default repository?" "y"

  if [ "$use_default" == "y" ]; then
    WINGS_REPO="$WINGS_REPO"
  else
    required_input WINGS_REPO "Enter the GitHub repository (format: owner/repo): " "Repository cannot be empty"

    if [[ ! "$WINGS_REPO" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]]; then
      error "Invalid repository format. Must be 'owner/repo'"
      exit 1
    fi
  fi

  echo ""
  output "Repository: ${COLOR_ORANGE}${WINGS_REPO}${COLOR_NC}"

  if [ "$use_default" == "n" ]; then
    local is_private=""
    bool_input is_private "Is this a private repository?" "n"
    WINGS_REPO_PRIVATE=$([ "$is_private" == "y" ] && echo "true" || echo "false")

    if [ "$WINGS_REPO_PRIVATE" == "true" ]; then
      echo ""
      output "A GitHub Personal Access Token is required for private repositories."
      output "Create one at: $(hyperlink "https://github.com/settings/tokens")"
      output "Required scopes: ${COLOR_ORANGE}repo${COLOR_NC}"
      echo ""

      local token_valid=false
      while [ "$token_valid" == false ]; do
        password_input GITHUB_TOKEN "Enter your GitHub token: " "Token cannot be empty"

        output "Validating token..."
        if validate_github_token "$GITHUB_TOKEN" "$WINGS_REPO"; then
          success "Token validated successfully"
          token_valid=true
        else
          warning "Token validation failed. Please check your token and try again."
        fi
      done
    fi
  else
    WINGS_REPO_PRIVATE="false"
  fi

  output "Checking for releases in repository..."
  if ! check_releases_exist "$WINGS_REPO" "$GITHUB_TOKEN"; then
    echo ""
    error "No releases found in repository: ${WINGS_REPO}"
    warning "Wings must be installed from a release."
    exit 1
  fi

  local latest_release
  latest_release=$(get_latest_release "$WINGS_REPO" "$GITHUB_TOKEN")
  success "Found releases in repository (latest: ${latest_release})"
}

# ------------------ Release Version Selection ----------------- #

configure_release_version() {
  print_header
  print_flame "Release Version Selection"

  local selected_version
  selected_version=$(select_release_version "$WINGS_REPO" "wings" "$GITHUB_TOKEN")

  if [ -z "$selected_version" ]; then
    error "Failed to select release version"
    exit 1
  fi

  WINGS_RELEASE_VERSION="$selected_version"

  if [ "$WINGS_RELEASE_VERSION" == "latest" ]; then
    local latest
    latest=$(get_latest_release "$WINGS_REPO" "$GITHUB_TOKEN")
    success "Will install latest release: ${latest}"
  else
    success "Will install release: ${WINGS_RELEASE_VERSION}"
  fi
}

# ------------------ API Key Configuration ----------------- #

configure_api_key() {
  print_header
  print_flame "API Key Configuration"

  output "Do you have an API key from your panel installation?"
  output "The API key would have been displayed at the end of the panel setup."
  output "Using an API key allows automatic node configuration without manual token/ID entry."
  echo ""

  local has_api_key=""
  bool_input has_api_key "Do you have an API key?" "n"

  if [ "$has_api_key" == "y" ]; then
    password_input PANEL_API_KEY "Enter your API key: " "API key is required"

    output ""
    output "Enter your panel URL"
    output "Example: ${COLOR_ORANGE}https://panel.example.com${COLOR_NC}"
    required_input PANEL_URL "Panel URL: " "Panel URL is required"
    PANEL_URL="${PANEL_URL%/}"

    output ""
    output "Enter a name for this node"
    output "This will be used to identify the node in the panel"
    required_input NODE_NAME "Node name [Wings-Node]: " "" "Wings-Node"
    
    success "API key configured - automatic setup will be used"
    USE_API_KEY=true
  else
    output "No API key provided - manual configuration will be required"
    USE_API_KEY=false
  fi
}

# ------------------ Panel Connection ----------------- #

configure_panel_connection() {
  print_header
  print_flame "Panel Connection Configuration"

  if [ "$USE_API_KEY" == "true" ]; then
    output "Using API key for automatic configuration - manual connection details not required"
    return 0
  fi

  output "Enter the URL of your Hydrodactyl Panel"
  output "Example: ${COLOR_ORANGE}https://panel.example.com${COLOR_NC}"
  echo ""

  required_input PANEL_URL "Panel URL: " "Panel URL is required"
  PANEL_URL="${PANEL_URL%/}"

  output ""
  output "To connect this node to the panel, you need to:"
  output "1. Go to ${PANEL_URL}/admin/nodes"
  output "2. Create a new node"
  output "3. Copy the configuration token"
  echo ""

  password_input NODE_TOKEN "Node configuration token: " "Token is required"
  required_input NODE_ID "Node ID: " "Node ID is required"
}

# ------------------ Network Configuration ----------------- #

configure_network() {
  print_header
  print_flame "Network Configuration"

  local behind_proxy_input=""
  bool_input behind_proxy_input "Is this node behind a proxy (e.g., Cloudflare)?" "n"
  BEHIND_PROXY=$([ "$behind_proxy_input" == "y" ] && echo "true" || echo "false")

  if [ "$BEHIND_PROXY" == "true" ]; then
    output "Node will be configured to work behind a proxy"
  fi
}

# ------------------ SSL Configuration ----------------- #

configure_ssl() {
  print_header
  print_flame "SSL/TLS Configuration"

  output "SSL secures connections between the panel and this node."
  output "If this node's FQDN points to this server, Let's Encrypt can auto-generate a certificate."
  echo ""

  local use_ssl=""
  bool_input use_ssl "Would you like to configure SSL/HTTPS?" "y"

  if [ "$use_ssl" == "y" ]; then
    echo ""
    output "[${COLOR_ORANGE}0${COLOR_NC}] Let's Encrypt (auto-generated, requires FQDN to point to this server)"
    output "[${COLOR_ORANGE}1${COLOR_NC}] Use existing SSL certificate"
    output "[${COLOR_ORANGE}2${COLOR_NC}] No SSL (not recommended for production)"
    echo ""

    local ssl_choice=""
    while [[ "$ssl_choice" != "0" && "$ssl_choice" != "1" && "$ssl_choice" != "2" ]]; do
      echo -n "* Select [0-2]: "
      read -r ssl_choice
    done

    case "$ssl_choice" in
      0)
        CONFIGURE_LETSENCRYPT=true
        output "Will use Let's Encrypt for SSL"

        if [ -z "$FQDN" ]; then
          echo ""
          output "Let's Encrypt requires a fully qualified domain name (FQDN)."
          required_input FQDN "Enter this node's FQDN (e.g., node.example.com): " "FQDN is required for Let's Encrypt"
        fi

        echo ""
        output "An email address is recommended for Let's Encrypt (expiry notifications)."
        local ssl_email_input=""
        bool_input ssl_email_input "Provide an email for Let's Encrypt?" "y"
        if [ "$ssl_email_input" == "y" ]; then
          required_input SSL_EMAIL "Email address: " "Email is required"
        fi
        ;;
      1)
        required_input SSL_CERT_PATH "Path to SSL certificate: " "Path is required"
        required_input SSL_KEY_PATH "Path to SSL key: " "Path is required"
        output "Will use existing SSL certificate"
        ;;
      2)
        output "SSL will not be configured"
        ;;
    esac
  else
    output "SSL will not be configured"
  fi
}

# ------------------ Firewall ----------------- #

configure_firewall() {
  print_header
  print_flame "Firewall Configuration"

  ask_firewall CONFIGURE_FIREWALL
}

# ------------------ Summary ----------------- #

show_summary() {
  print_header
  print_flame "Installation Summary"

  output "Please review the following configuration:"
  echo ""
  echo -e "  ${COLOR_ORANGE}Variant:${COLOR_NC}            $([ "$WINGS_VARIANT" == "go" ] && echo 'Pterodactyl Wings (Go)' || echo 'wings-rs (Rust)')"
  echo -e "  ${COLOR_ORANGE}Repository:${COLOR_NC}        ${WINGS_REPO} $([ "$WINGS_REPO_PRIVATE" == "true" ] && echo '(private)' || echo '(public)')"
  echo -e "  ${COLOR_ORANGE}Panel URL:${COLOR_NC}         ${PANEL_URL}"
  if [ "$USE_API_KEY" == "true" ]; then
    echo -e "  ${COLOR_ORANGE}Setup Method:${COLOR_NC}      Automatic (via API key)"
    echo -e "  ${COLOR_ORANGE}Node Name:${COLOR_NC}         ${NODE_NAME}"
    echo -e "  ${COLOR_ORANGE}API Key:${COLOR_NC}         ${PANEL_API_KEY:0:20}..."
  else
    echo -e "  ${COLOR_ORANGE}Setup Method:${COLOR_NC}      Manual"
    echo -e "  ${COLOR_ORANGE}Node ID:${COLOR_NC}           ${NODE_ID}"
  fi
  echo -e "  ${COLOR_ORANGE}Behind Proxy:${COLOR_NC}      $([ "$BEHIND_PROXY" == "true" ] && echo 'Yes' || echo 'No')"
  echo -e "  ${COLOR_ORANGE}SSL:${COLOR_NC}               $([ "$CONFIGURE_LETSENCRYPT" == "true" ] && echo 'Let'\''s Encrypt' || ([ -n "$SSL_CERT_PATH" ] && echo 'Custom' || echo 'None'))"
  echo -e "  ${COLOR_ORANGE}FQDN:${COLOR_NC}              $([ -n "$FQDN" ] && echo "$FQDN" || echo 'Not set')"
  echo -e "  ${COLOR_ORANGE}Firewall:${COLOR_NC}          $([ "$CONFIGURE_FIREWALL" == "true" ] && echo 'Yes' || echo 'No')"
  echo ""

  local confirm=""
  bool_input confirm "Proceed with installation?" "y"

  if [ "$confirm" != "y" ]; then
    error "Installation aborted"
    exit 1
  fi
}

# ------------------ Export and Run ----------------- #

export_variables() {
  export WINGS_VARIANT
  export WINGS_REPO
  export WINGS_REPO_PRIVATE
  export GITHUB_TOKEN
  export WINGS_RELEASE_VERSION
  export PANEL_URL
  export PANEL_API_KEY
  export NODE_NAME
  export NODE_TOKEN
  export NODE_ID
  export CONFIGURE_FIREWALL
  export CONFIGURE_LETSENCRYPT
  export SSL_EMAIL
  export SSL_CERT_PATH
  export SSL_KEY_PATH
  export BEHIND_PROXY
  export FQDN

  if [ "$CONFIGURE_LETSENCRYPT" == true ] || { [ -n "$SSL_CERT_PATH" ] && [ -n "$SSL_KEY_PATH" ]; }; then
    export ASSUME_SSL=true
  else
    export ASSUME_SSL=false
  fi
}

# ------------------ Main ----------------- #

main() {
  print_flame "Welcome to the Wings Daemon Installer"

  configure_wings_variant
  configure_github_repository
  configure_release_version
  configure_api_key
  configure_panel_connection
  configure_network
  configure_ssl
  configure_firewall
  show_summary

  export_variables

  output "Starting installation..."
  run_installer "wings"
}

main
