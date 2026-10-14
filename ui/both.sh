#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Hydrodactyl Panel + Wings Combined Installation UI                                 #
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

# Panel Configuration
PANEL_REPO=""
PANEL_REPO_PRIVATE=false
GITHUB_TOKEN_PANEL=""
PANEL_INSTALL_METHOD="release"
PANEL_RELEASE_VERSION="${PANEL_RELEASE_VERSION:-latest}"
PANEL_FQDN=""
PANEL_IS_IP=false
PANEL_TIMEZONE="UTC"
PANEL_ADMIN_EMAIL=""
PANEL_ADMIN_USERNAME=""
PANEL_ADMIN_FIRSTNAME=""
PANEL_ADMIN_LASTNAME=""
PANEL_ADMIN_PASSWORD=""
CONFIGURE_LETSENCRYPT=false
CONFIGURE_FIREWALL=false
SSL_CERT_PATH=""
SSL_KEY_PATH=""
DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_NAME="panel"
DB_USER="hydrodactyl"
DB_PASSWORD=""

# Wings Configuration
WINGS_VARIANT=""
WINGS_REPO=""
WINGS_REPO_PRIVATE=false
GITHUB_TOKEN_WINGS=""
WINGS_RELEASE_VERSION="${WINGS_RELEASE_VERSION:-latest}"
NODE_NAME="local"
NODE_DESCRIPTION="Local Node"
BEHIND_PROXY=false

# ------------------ Panel Repository ----------------- #

configure_panel_repository() {
  print_header
  print_flame "Panel Repository Configuration"

  output "The default Hydrodactyl Panel repository is:"
  output "  ${COLOR_ORANGE}${DEFAULT_PANEL_REPO}${COLOR_NC}"
  echo ""

  local use_default=""
  bool_input use_default "Use default repository?" "y"

  if [ "$use_default" == "y" ]; then
    PANEL_REPO="$DEFAULT_PANEL_REPO"
  else
    required_input PANEL_REPO "Enter the GitHub repository (format: owner/repo): " "Repository cannot be empty"

    if [[ ! "$PANEL_REPO" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]]; then
      error "Invalid repository format. Must be 'owner/repo'"
      exit 1
    fi
  fi

  echo ""
  output "Repository: ${COLOR_ORANGE}${PANEL_REPO}${COLOR_NC}"

  # Only ask about private repo if not using default (default is public)
  if [ "$use_default" == "n" ]; then
    local is_private=""
    bool_input is_private "Is this a private repository?" "n" || true
    if [ "$is_private" == "y" ]; then
      PANEL_REPO_PRIVATE="true"
    else
      PANEL_REPO_PRIVATE="false"
    fi

    if [ "$PANEL_REPO_PRIVATE" == "true" ]; then
      echo ""
      output "A GitHub Personal Access Token is required for private repositories."
      output "Create one at: https://github.com/settings/tokens"
      output "Required scopes: ${COLOR_ORANGE}repo${COLOR_NC}"
      echo ""

      local token_valid=false
      while [ "$token_valid" == false ]; do
        password_input GITHUB_TOKEN_PANEL "Enter your GitHub token: " "Token cannot be empty"

        output "Validating token..."
        if validate_github_token "$GITHUB_TOKEN_PANEL" "$PANEL_REPO"; then
          success "Token validated successfully"
          token_valid=true
        else
          warning "Token validation failed. Please check your token and try again."
        fi
      done
    fi
  else
    PANEL_REPO_PRIVATE="false"
  fi

  output "Checking for releases in repository..."
  if ! check_releases_exist "$PANEL_REPO" "$GITHUB_TOKEN_PANEL"; then
    echo ""
    error "No releases found in repository: ${PANEL_REPO}"
    warning "You must publish a release before using this installer."
    exit 1
  fi

  local latest_release
  latest_release=$(get_latest_release "$PANEL_REPO" "$GITHUB_TOKEN_PANEL")
  success "Found releases in repository"
}

# ------------------ Panel Settings ----------------- #

configure_panel_settings() {
  print_header
  print_flame "Panel Configuration"

  output "How would you like to install the panel?"
  echo ""
  output "[${COLOR_ORANGE}0${COLOR_NC}] Download latest release tarball (recommended)"
  output "[${COLOR_ORANGE}1${COLOR_NC}] Clone from Git repository (development)"
  echo ""

  local method_choice=""
  while [[ "$method_choice" != "0" && "$method_choice" != "1" ]]; do
    echo -n "* Select [0-1]: "
    read -r method_choice
  done

  if [ "$method_choice" == "0" ]; then
    PANEL_INSTALL_METHOD="release"
    # Select release version (skip interactive if already set via env)
    local selected_version
    if [ "$PANEL_RELEASE_VERSION" != "latest" ]; then
      selected_version="$PANEL_RELEASE_VERSION"
      info "Using panel release version from environment: $selected_version"
    else
      echo ""
      selected_version=$(select_release_version "$PANEL_REPO" "panel" "$GITHUB_TOKEN_PANEL")
      if [ -z "$selected_version" ]; then
        error "Failed to select release version"
        exit 1
      fi
    fi
    PANEL_RELEASE_VERSION="$selected_version"
    if [ "$PANEL_RELEASE_VERSION" == "latest" ]; then
      local latest
      latest=$(get_latest_release "$PANEL_REPO" "$GITHUB_TOKEN_PANEL")
      success "Will install latest release: ${latest}"
    else
      success "Will install release: ${PANEL_RELEASE_VERSION}"
    fi
    echo ""
  else
    PANEL_INSTALL_METHOD="clone"
  fi

  echo ""

  local valid_fqdn=false
  PANEL_IS_IP=false
  while [ "$valid_fqdn" == false ]; do
    required_input PANEL_FQDN "Enter the domain or IP for your panel (e.g., panel.example.com): " "Domain is required"

    if is_ip_address "$PANEL_FQDN"; then
      PANEL_IS_IP=true
      warning "You entered an IP address. Let's Encrypt will not be available for IP addresses."
      valid_fqdn=true
    elif check_fqdn "$PANEL_FQDN"; then
      # Verify DNS resolution
      local verify_result=1
      bash <(curl -sSL "$GITHUB_URL/lib/verify-fqdn.sh") "$PANEL_FQDN" && verify_result=0

      if [ $verify_result -eq 0 ]; then
        valid_fqdn=true
      else
        # DNS verification failed and user chose not to continue
        error "Please fix your DNS configuration or enter a different domain."
      fi
    else
      error "Invalid format. Must be a valid domain name or IP address."
    fi
  done

  echo ""
  if [ "$PANEL_IS_IP" == true ]; then
    warning "Let's Encrypt will not be available for IP addresses (${PANEL_FQDN})."
    output "SSL will not be configured. Use a domain name instead if you need HTTPS."
    CONFIGURE_LETSENCRYPT=false
    SSL_CERT_PATH=""
    SSL_KEY_PATH=""
  else
    local use_ssl=""
    bool_input use_ssl "Would you like to use SSL/HTTPS?" "y"

    if [ "$use_ssl" == "y" ]; then
      echo ""
      output "[${COLOR_ORANGE}0${COLOR_NC}] Let's Encrypt (auto-generated)"
      output "[${COLOR_ORANGE}1${COLOR_NC}] Use existing SSL certificate"
      output "[${COLOR_ORANGE}2${COLOR_NC}] No SSL (not recommended)"
      echo ""

      local ssl_choice=""
      while [[ "$ssl_choice" != "0" && "$ssl_choice" != "1" && "$ssl_choice" != "2" ]]; do
        echo -n "* Select [0-2]: "
        read -r ssl_choice
      done

      case "$ssl_choice" in
        0)
          CONFIGURE_LETSENCRYPT=true
          ;;
        1)
          required_input SSL_CERT_PATH "Path to SSL certificate: " "Path is required"
          required_input SSL_KEY_PATH "Path to SSL key: " "Path is required"
          ;;
        2)
          output "SSL will not be configured"
          ;;
      esac
    fi
  fi

  echo ""
  local sys_tz
  sys_tz=$(detect_system_timezone)
  output "This timezone setting is used by PHP for all date/time functions."
  output "Detected system timezone: ${COLOR_ORANGE}${sys_tz}${COLOR_NC}"
  echo ""

  local use_sys=""
  bool_input use_sys "Use system timezone (${sys_tz})?" "y"

  if [ "$use_sys" != "y" ]; then
    echo ""
    output "Format: Continent/City (e.g., Europe/Berlin, America/New_York)"
    output "Examples:"
    output "  Europe/Berlin       - Central European Time"
    output "  Europe/London       - Greenwich Mean Time / British Summer Time"
    output "  America/New_York    - Eastern Time (US)"
    output "  America/Los_Angeles - Pacific Time (US)"
    output "  Asia/Tokyo          - Japan Standard Time"
    output "  Australia/Sydney    - Australian Eastern Time"
    output "  UTC                 - Coordinated Universal Time"
    echo ""
    output "Full list: $(hyperlink "https://www.php.net/manual/en/timezones.php")"
    echo ""

    local tz_valid=false
    while [ "$tz_valid" == false ]; do
      required_input PANEL_TIMEZONE "Timezone [UTC]: " "" "UTC"
      if validate_timezone "$PANEL_TIMEZONE"; then
        tz_valid=true
      else
        warning "Timezone '${PANEL_TIMEZONE}' is not recognized"
        output "Enter a valid timezone (e.g., Continent/City)"
      fi
    done
  else
    PANEL_TIMEZONE="$sys_tz"
  fi

  output "Timezone set to: ${COLOR_ORANGE}${PANEL_TIMEZONE}${COLOR_NC}"

  echo ""
  email_input PANEL_ADMIN_EMAIL "Admin email: " "Invalid email address"
  required_input PANEL_ADMIN_USERNAME "Admin username: " "Username is required"
  required_input PANEL_ADMIN_FIRSTNAME "First name: " "First name is required"
  required_input PANEL_ADMIN_LASTNAME "Last name: " "Last name is required"

  local password_match=false
  while [ "$password_match" == false ]; do
    password_input PANEL_ADMIN_PASSWORD "Admin password: " "Password cannot be empty"
    local password_confirm=""
    password_input password_confirm "Confirm password: " "Confirmation is required"

    if [ "$PANEL_ADMIN_PASSWORD" == "$password_confirm" ]; then
      password_match=true
    else
      error "Passwords do not match. Please try again."
    fi
  done

}

# ------------------ Wings Variant Selection ----------------- #

configure_wings_variant() {
  print_header
  print_flame "Wings Daemon Variant Selection"

  output "Which daemon would you like to install to run game servers?"
  output "(Elytra is no longer supported - migrate to Wings or Wings-RS instead.)"
  echo ""
  output "[${COLOR_ORANGE}0${COLOR_NC}] Wings (pterodactyl/wings)"
  output "    The official Pterodactyl server daemon, written in Go."
  output "    Most stable, widely used, and battle-tested in production."
  echo ""
  output "[${COLOR_ORANGE}1${COLOR_NC}] Wings-RS (calagopus/wings)"
  output "    A lightweight Rust reimplementation of Wings."
  output "    Lower memory usage, faster startup, additional features."
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

# ------------------ Wings Configuration ----------------- #

configure_wings_settings() {
  configure_wings_variant

  print_header
  print_flame "Wings Daemon Repository Configuration"

  output "The default repository for this variant is:"
  output "  ${COLOR_ORANGE}${WINGS_REPO}${COLOR_NC}"
  echo ""

  local use_default=""
  bool_input use_default "Use default repository?" "y"

  if [ "$use_default" == "y" ]; then
    : # Keep the repository selected by configure_wings_variant
  else
    required_input WINGS_REPO "Enter the GitHub repository (format: owner/repo): " "Repository cannot be empty"

    if [[ ! "$WINGS_REPO" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]]; then
      error "Invalid repository format. Must be 'owner/repo'"
      exit 1
    fi
  fi

  echo ""
  output "Repository: ${COLOR_ORANGE}${WINGS_REPO}${COLOR_NC}"

  # Only ask about private repo if not using default (default is public)
  if [ "$use_default" == "n" ]; then
    local is_private=""
    bool_input is_private "Is this a private repository?" "n" || true
    if [ "$is_private" == "y" ]; then
      WINGS_REPO_PRIVATE="true"
    else
      WINGS_REPO_PRIVATE="false"
    fi

    if [ "$WINGS_REPO_PRIVATE" == "true" ]; then
      echo ""
      output "A GitHub Personal Access Token is required for private repositories."
      output "Create one at: https://github.com/settings/tokens"
      echo ""

      local token_valid=false
      while [ "$token_valid" == false ]; do
        password_input GITHUB_TOKEN_WINGS "Enter your GitHub token: " "Token cannot be empty"

        output "Validating token..."
        if validate_github_token "$GITHUB_TOKEN_WINGS" "$WINGS_REPO"; then
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
  if ! check_releases_exist "$WINGS_REPO" "$GITHUB_TOKEN_WINGS"; then
    echo ""
    error "No releases found in repository: ${WINGS_REPO}"
    warning "Wings must be installed from a release."
    exit 1
  fi

  local latest_release
  latest_release=$(get_latest_release "$WINGS_REPO" "$GITHUB_TOKEN_WINGS")
  success "Found releases in repository"

  # Select Wings release version (skip interactive if already set via env)
  local selected_version
  if [ "$WINGS_RELEASE_VERSION" != "latest" ]; then
    selected_version="$WINGS_RELEASE_VERSION"
    info "Using Wings release version from environment: $selected_version"
  else
    echo ""
    selected_version=$(select_release_version "$WINGS_REPO" "wings" "$GITHUB_TOKEN_WINGS")
    if [ -z "$selected_version" ]; then
      error "Failed to select release version"
      exit 1
    fi
  fi
  WINGS_RELEASE_VERSION="$selected_version"
  if [ "$WINGS_RELEASE_VERSION" == "latest" ]; then
    success "Will install latest Wings release: ${latest_release}"
  else
    success "Will install Wings release: ${WINGS_RELEASE_VERSION}"
  fi

  echo ""
  print_flame "Wings Node Configuration"
  echo ""

  output "Configuring Wings to connect to the panel at: ${COLOR_ORANGE}$(panel_scheme)://$(panel_url_host "$PANEL_FQDN")${COLOR_NC}"
  output "(This will be set automatically - no panel URL input needed)"
  echo ""

  required_input NODE_NAME "Node name [local]: " "" "local"
  required_input NODE_DESCRIPTION "Node description [Local Node]: " "" "Local Node"

  local behind_proxy_input=""
  bool_input behind_proxy_input "Is this node behind a proxy (e.g., Cloudflare)?" "n" || true
  if [ "$behind_proxy_input" == "y" ]; then
    BEHIND_PROXY="true"
  else
    BEHIND_PROXY="false"
  fi
}

# ------------------ Minecraft Server Setup ----------------- #

configure_minecraft_server() {
  print_header
  print_flame "Minecraft Server Setup"

  output "Would you like to automatically create a Minecraft server on this node?"
  output "This will create a vanilla Minecraft server with 4GB RAM allocation."
  echo ""

  local create_server=""
  bool_input create_server "Create Minecraft server automatically?" "n" || true
  if [ "$create_server" == "y" ]; then
    CREATE_MINECRAFT_SERVER="true"
  else
    CREATE_MINECRAFT_SERVER="false"
  fi

  if [ "$CREATE_MINECRAFT_SERVER" == "true" ]; then
    output "A Minecraft server will be created automatically after installation."
  else
    output "No server will be created. You can create one manually later."
  fi
}

# ------------------ Firewall ----------------- #

configure_firewall_settings() {
  print_header
  print_flame "Firewall Configuration"

  ask_firewall CONFIGURE_FIREWALL
}

# ------------------ Summary ----------------- #

show_summary() {
  print_header
  print_flame "Installation Summary"

  output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  output "  Panel Configuration"
  output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "  ${COLOR_ORANGE}Repository:${COLOR_NC}        ${PANEL_REPO} $([ "$PANEL_REPO_PRIVATE" == "true" ] && echo '(private)' || echo '(public)')"
  echo -e "  ${COLOR_ORANGE}Install Method:${COLOR_NC}    ${PANEL_INSTALL_METHOD}"
  echo -e "  ${COLOR_ORANGE}Release Version:${COLOR_NC}   ${PANEL_RELEASE_VERSION}"
  echo -e "  ${COLOR_ORANGE}Domain:${COLOR_NC}            ${PANEL_FQDN}"
  echo -e "  ${COLOR_ORANGE}SSL:${COLOR_NC}               $([ "$CONFIGURE_LETSENCRYPT" == "true" ] && echo 'Let'\''s Encrypt' || ([ -n "$SSL_CERT_PATH" ] && echo 'Custom' || echo 'None'))"
  echo -e "  ${COLOR_ORANGE}Timezone:${COLOR_NC}          ${PANEL_TIMEZONE}"
  echo -e "  ${COLOR_ORANGE}Admin:${COLOR_NC}             ${PANEL_ADMIN_USERNAME} (${PANEL_ADMIN_EMAIL})"
  echo ""

  output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  output "  Wings Daemon Configuration"
  output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "  ${COLOR_ORANGE}Variant:${COLOR_NC}           $([ "$WINGS_VARIANT" == "go" ] && echo 'Pterodactyl Wings (Go)' || echo 'wings-rs (Rust)')"
  echo -e "  ${COLOR_ORANGE}Repository:${COLOR_NC}        ${WINGS_REPO} $([ "$WINGS_REPO_PRIVATE" == "true" ] && echo '(private)' || echo '(public)')"
  echo -e "  ${COLOR_ORANGE}Release Version:${COLOR_NC}   ${WINGS_RELEASE_VERSION}"
  echo -e "  ${COLOR_ORANGE}Panel URL:${COLOR_NC}         $(panel_scheme)://$(panel_url_host "$PANEL_FQDN") (auto-configured)"
  echo -e "  ${COLOR_ORANGE}Node Name:${COLOR_NC}         ${NODE_NAME}"
  echo -e "  ${COLOR_ORANGE}Node Description:${COLOR_NC}  ${NODE_DESCRIPTION}"
  echo -e "  ${COLOR_ORANGE}Behind Proxy:${COLOR_NC}      $([ "$BEHIND_PROXY" == "true" ] && echo 'Yes' || echo 'No')"
  echo ""

  output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  output "  Minecraft Server"
  output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "  ${COLOR_ORANGE}Auto-Create:${COLOR_NC}       $([ "$CREATE_MINECRAFT_SERVER" == "true" ] && echo 'Yes' || echo 'No')"
  if [ "$CREATE_MINECRAFT_SERVER" == "true" ]; then
    echo -e "  ${COLOR_ORANGE}Server Type:${COLOR_NC}       Vanilla Minecraft Java"
    echo -e "  ${COLOR_ORANGE}Memory:${COLOR_NC}            4GB"
    echo -e "  ${COLOR_ORANGE}Disk:${COLOR_NC}              32GB"
  fi
  echo ""
  output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  output "  General Settings"
  output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "  ${COLOR_ORANGE}Firewall:${COLOR_NC}          $([ "$CONFIGURE_FIREWALL" == "true" ] && echo 'Enabled' || echo 'Disabled')"
  if [ "$CONFIGURE_FIREWALL" == "true" ]; then
    echo -e "  ${COLOR_ORANGE}Game Support:${COLOR_NC}      Minecraft, CS:GO/TF2/GMod, ARK, Rust, Valheim, FiveM"
  fi
  echo ""

  local confirm=""
  bool_input confirm "Proceed with installation of both Panel and Wings?" "y"

  if [ "$confirm" != "y" ]; then
    error "Installation aborted"
    exit 1
  fi
}

# ------------------ Export and Run ----------------- #

export_variables() {
  # Panel variables
  export PANEL_REPO
  export PANEL_REPO_PRIVATE
  export GITHUB_TOKEN_PANEL
  export PANEL_INSTALL_METHOD
  export PANEL_RELEASE_VERSION
  export PANEL_FQDN
  export PANEL_TIMEZONE
  export PANEL_ADMIN_EMAIL
  export PANEL_ADMIN_USERNAME
  export PANEL_ADMIN_FIRSTNAME
  export PANEL_ADMIN_LASTNAME
  export PANEL_ADMIN_PASSWORD
  export CONFIGURE_LETSENCRYPT
  export CONFIGURE_FIREWALL
  export SSL_CERT_PATH
  export SSL_KEY_PATH
  export DB_HOST
  export DB_PORT
  export DB_NAME
  export DB_USER
  export DB_PASSWORD

  # Wings variables
  export WINGS_VARIANT
  export WINGS_REPO
  export WINGS_REPO_PRIVATE
  export GITHUB_TOKEN_WINGS
  export WINGS_RELEASE_VERSION
  export NODE_NAME
  export NODE_DESCRIPTION
  export BEHIND_PROXY

  # Minecraft server setup
  export CREATE_MINECRAFT_SERVER

  # Combined installation flag
  export BOTH_INSTALL=true
}

# ------------------ Main ----------------- #

main() {
  print_flame "Welcome to the Hydrodactyl + Wings Combined Installer"

  configure_panel_repository
  configure_panel_settings
  configure_wings_settings
  configure_minecraft_server
  configure_firewall_settings
  show_summary

  export_variables

  output "Starting installation..."
  run_installer "both"
}

main
