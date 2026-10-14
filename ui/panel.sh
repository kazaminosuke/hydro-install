#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Hydrodactyl Panel Installation UI                                                   #
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

PANEL_REPO=""
PANEL_REPO_PRIVATE=false
GITHUB_TOKEN=""
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

# ------------------ Repository Configuration ----------------- #

configure_github_repository() {
  print_header
  print_flame "GitHub Repository Configuration"

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
    bool_input is_private "Is this a private repository?" "n"
    PANEL_REPO_PRIVATE=$([ "$is_private" == "y" ] && echo "true" || echo "false")

    if [ "$PANEL_REPO_PRIVATE" == "true" ]; then
      echo ""
      output "A GitHub Personal Access Token is required for private repositories."
      output "Create one at: $(hyperlink "https://github.com/settings/tokens")"
      output "Required scopes: ${COLOR_ORANGE}repo${COLOR_NC}"
      echo ""

      local token_valid=false
      while [ "$token_valid" == false ]; do
        password_input GITHUB_TOKEN "Enter your GitHub token: " "Token cannot be empty"

        output "Validating token..."
        if validate_github_token "$GITHUB_TOKEN" "$PANEL_REPO"; then
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
  if ! check_releases_exist "$PANEL_REPO" "$GITHUB_TOKEN"; then
    echo ""
    error "No releases found in repository: ${PANEL_REPO}"
    warning "You must publish a release before using this installer."
    exit 1
  fi

  local latest_release
  latest_release=$(get_latest_release "$PANEL_REPO" "$GITHUB_TOKEN")
  success "Found releases in repository (latest: ${latest_release})"
}

# ------------------ Release Version Selection ----------------- #

configure_release_version() {
  print_header
  print_flame "Release Version Selection"

  local selected_version
  selected_version=$(select_release_version "$PANEL_REPO" "panel" "$GITHUB_TOKEN")

  if [ -z "$selected_version" ]; then
    error "Failed to select release version"
    exit 1
  fi

  PANEL_RELEASE_VERSION="$selected_version"

  if [ "$PANEL_RELEASE_VERSION" == "latest" ]; then
    local latest
    latest=$(get_latest_release "$PANEL_REPO" "$GITHUB_TOKEN")
    success "Will install latest release: ${latest}"
  else
    success "Will install release: ${PANEL_RELEASE_VERSION}"
  fi
}

# ------------------ Installation Method ----------------- #

configure_installation_method() {
  print_header
  print_flame "Installation Method"

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
    output "Will download release tarball"
    # Configure which release version to use
    configure_release_version
  else
    PANEL_INSTALL_METHOD="clone"
    output "Will clone from Git repository"
  fi
}

# ------------------ Domain Configuration ----------------- #

configure_fqdn() {
  print_header
  print_flame "Domain Configuration"

  output "Please enter the domain or subdomain for your panel."
  output "Example: ${COLOR_ORANGE}panel.example.com${COLOR_NC}"
  output "An IP address (e.g., ${COLOR_ORANGE}192.168.1.10${COLOR_NC}) is also accepted, but SSL will not be available."
  echo ""

  local valid_fqdn=false
  PANEL_IS_IP=false
  while [ "$valid_fqdn" == false ]; do
    required_input PANEL_FQDN "Domain/Subdomain/IP: " "Domain is required"

    if is_ip_address "$PANEL_FQDN"; then
      PANEL_IS_IP=true
      warning "You entered an IP address. Let's Encrypt will not be available for IP addresses."
      valid_fqdn=true
    elif check_fqdn "$PANEL_FQDN"; then
      # Verify DNS resolution
      output "Verifying DNS for ${PANEL_FQDN}..."
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

  output "Domain set to: ${COLOR_ORANGE}${PANEL_FQDN}${COLOR_NC}"
}

# ------------------ SSL Configuration ----------------- #

configure_ssl() {
  print_header
  print_flame "SSL/TLS Configuration"

  if [ "$PANEL_IS_IP" == true ]; then
    warning "Let's Encrypt will not be available for IP addresses (${PANEL_FQDN})."
    output "SSL will not be configured. Use a domain name instead if you need HTTPS."
    CONFIGURE_LETSENCRYPT=false
    SSL_CERT_PATH=""
    SSL_KEY_PATH=""
    return
  fi

  local use_ssl=""
  bool_input use_ssl "Would you like to use SSL/HTTPS?" "y"

  if [ "$use_ssl" == "y" ]; then
    echo ""
    output "[${COLOR_ORANGE}0${COLOR_NC}] Let's Encrypt (auto-generated, requires domain to point to this server)"
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
  fi
}

# ------------------ Database Configuration ----------------- #

configure_database() {
  print_header
  print_flame "Database Configuration"

  local use_local_db=""
  bool_input use_local_db "Use local database?" "y"

  if [ "$use_local_db" == "n" ]; then
    required_input DB_HOST "Database host: " "Host is required"
    required_input DB_PORT "Database port [3306]: " "" "3306"
  fi

  required_input DB_NAME "Database name [panel]: " "" "panel"
  required_input DB_USER "Database username [hydrodactyl]: " "" "hydrodactyl"
  password_input DB_PASSWORD "Database password: " "Password cannot be empty"
}

# ------------------ Timezone Configuration ----------------- #

configure_timezone() {
  print_header
  print_flame "Timezone Configuration"

  local sys_tz
  sys_tz=$(detect_system_timezone)
  output "This timezone setting is used by PHP for all date/time functions."
  echo ""

  output "Detected system timezone: ${COLOR_ORANGE}${sys_tz}${COLOR_NC}"
  local use_sys=""
  bool_input use_sys "Use system timezone (${sys_tz})?" "y"

  if [ "$use_sys" != "y" ]; then
    echo ""
    output "Pick a region to browse available timezones:"

    local regions
    regions=$(list_timezone_regions)
    local region_list=()
    while IFS= read -r region; do
      region_list+=("$region")
    done <<< "$regions"

    for i in "${!region_list[@]}"; do
      echo -e "  [${COLOR_ORANGE}$i${COLOR_NC}] ${region_list[$i]}"
    done
    echo ""
    echo -n "* Select region [0-$((${#region_list[@]} - 1))]: "
    read -r region_idx

    local selected_region=""
    if [[ "$region_idx" =~ ^[0-9]+$ ]] && [ "$region_idx" -ge 0 ] && [ "$region_idx" -lt "${#region_list[@]}" ]; then
      selected_region="${region_list[$region_idx]}"
    fi

    if [ -n "$selected_region" ] && [ "$selected_region" != "UTC" ]; then
      echo ""
      output "Available cities in ${COLOR_ORANGE}${selected_region}${COLOR_NC}:"
      echo ""

      local cities
      if [ -d "/usr/share/zoneinfo/$selected_region" ]; then
        cities=$(ls /usr/share/zoneinfo/"$selected_region"/ 2>/dev/null | sort)
      fi
      if [ -z "$cities" ]; then
        cities=$(grep "^$selected_region/" "$(dirname "$0")/../configs/valid_timezones.txt" 2>/dev/null | cut -d/ -f2 | sort -u)
      fi
      if [ -z "$cities" ]; then
        cities=$(php -r "echo implode(PHP_EOL, timezone_identifiers_list(DateTimeZone::$selected_region));" 2>/dev/null | cut -d/ -f2- | sort)
      fi

      if [ -n "$cities" ]; then
        echo "$cities" | head -30 | while IFS= read -r city; do
          [ -n "$city" ] && echo "    - ${selected_region}/${city}"
        done
        echo "    ..."
      fi
    fi

    echo ""
    output "Format: Continent/City (e.g., Europe/Berlin, America/New_York)"
    output "Full list: $(hyperlink "https://www.php.net/manual/en/timezones.php")"
    echo ""

    local tz_valid=false
    while [ "$tz_valid" == false ]; do
      if [ -n "$selected_region" ] && [ "$selected_region" != "UTC" ]; then
        required_input PANEL_TIMEZONE "Timezone [${selected_region}/]: " "" "${selected_region}/"
        if [ "$PANEL_TIMEZONE" = "${selected_region}/" ]; then
          PANEL_TIMEZONE="${selected_region}/UTC"
        fi
      else
        required_input PANEL_TIMEZONE "Timezone [UTC]: " "" "UTC"
      fi

      if validate_timezone "$PANEL_TIMEZONE"; then
        tz_valid=true
      else
        warning "Timezone '${PANEL_TIMEZONE}' is not recognized"
        output "Enter a valid timezone (e.g., Continent/City) or type 'list' to see options"
        if [ "$PANEL_TIMEZONE" = "list" ]; then
          php -r "
            \$tzs = timezone_identifiers_list();
            foreach (\$tzs as \$tz) echo \$tz . PHP_EOL;
          " 2>/dev/null | head -50 || cat "$(dirname "$0")/../configs/valid_timezones.txt" 2>/dev/null | head -50
        fi
      fi
    done
  else
    PANEL_TIMEZONE="$sys_tz"
  fi

  output "Timezone set to: ${COLOR_ORANGE}${PANEL_TIMEZONE}${COLOR_NC}"
}

# ------------------ Admin Account ----------------- #

configure_admin_account() {
  print_header
  print_flame "Admin Account Configuration"

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

# ------------------ Auto-Updater ----------------- #

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
  echo -e "  ${COLOR_ORANGE}Repository:${COLOR_NC}        ${PANEL_REPO} $([ "$PANEL_REPO_PRIVATE" == "true" ] && echo '(private)' || echo '(public)')"
  echo -e "  ${COLOR_ORANGE}Install Method:${COLOR_NC}    ${PANEL_INSTALL_METHOD}"
  echo -e "  ${COLOR_ORANGE}Domain:${COLOR_NC}            ${PANEL_FQDN}"
  echo -e "  ${COLOR_ORANGE}SSL:${COLOR_NC}               $([ "$CONFIGURE_LETSENCRYPT" == "true" ] && echo 'Let'\''s Encrypt' || ([ -n "$SSL_CERT_PATH" ] && echo 'Custom' || echo 'None'))"
  echo -e "  ${COLOR_ORANGE}Database:${COLOR_NC}          ${DB_NAME}@${DB_HOST}:${DB_PORT}"
  echo -e "  ${COLOR_ORANGE}Timezone:${COLOR_NC}          ${PANEL_TIMEZONE}"
  echo -e "  ${COLOR_ORANGE}Admin Email:${COLOR_NC}       ${PANEL_ADMIN_EMAIL}"
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
  export PANEL_REPO
  export PANEL_REPO_PRIVATE
  export GITHUB_TOKEN
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
}

# ------------------ Main ----------------- #

main() {
  print_flame "Welcome to the Hydrodactyl Panel Installer"

  configure_github_repository
  configure_installation_method
  # Note: configure_release_version is called within configure_installation_method when release method is selected
  configure_fqdn
  configure_ssl
  configure_database
  configure_timezone
  configure_admin_account
  configure_firewall
  show_summary

  export_variables

  output "Starting installation..."
  run_installer "panel"
}

main
