#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Hydrodactyl Panel Installer                                                         #
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

# ------------------ Variables ----------------- #

PANEL_REPO="${PANEL_REPO:-BlueprintFramework/hydrodactyl}"
PANEL_INSTALL_METHOD="${PANEL_INSTALL_METHOD:-release}"
PANEL_FQDN="${PANEL_FQDN:-}"
PANEL_TIMEZONE="${PANEL_TIMEZONE:-UTC}"
PANEL_ADMIN_EMAIL="${PANEL_ADMIN_EMAIL:-}"
PANEL_ADMIN_USERNAME="${PANEL_ADMIN_USERNAME:-}"
PANEL_ADMIN_FIRSTNAME="${PANEL_ADMIN_FIRSTNAME:-}"
PANEL_ADMIN_LASTNAME="${PANEL_ADMIN_LASTNAME:-}"
PANEL_ADMIN_PASSWORD="${PANEL_ADMIN_PASSWORD:-}"
PANEL_RELEASE_VERSION="${PANEL_RELEASE_VERSION:-latest}"
ASSUME_SSL="${ASSUME_SSL:-false}"
CONFIGURE_LETSENCRYPT="${CONFIGURE_LETSENCRYPT:-false}"
SSL_CERT_PATH="${SSL_CERT_PATH:-}"
SSL_KEY_PATH="${SSL_KEY_PATH:-}"
CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-false}"
PANEL_REPO_PRIVATE="${PANEL_REPO_PRIVATE:-false}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# Database
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-panel}"
DB_USER="${DB_USER:-hydrodactyl}"
# Load existing credentials or generate new ones
if saved_pass=$(load_existing_db_credentials); then
  MYSQL_ROOT_PASSWORD="${saved_pass}"
else
  DB_PASSWORD="${DB_PASSWORD:-$(gen_passwd 64)}"
  MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-$(gen_passwd 64)}"
fi

# ------------------ Validation ----------------- #

validate_configuration() {
  print_flame "Validating Configuration"

  local missing=()

  [ -z "$PANEL_FQDN" ] && missing+=("PANEL_FQDN")
  [ -z "$PANEL_ADMIN_EMAIL" ] && missing+=("PANEL_ADMIN_EMAIL")
  [ -z "$PANEL_ADMIN_USERNAME" ] && missing+=("PANEL_ADMIN_USERNAME")
  [ -z "$PANEL_ADMIN_FIRSTNAME" ] && missing+=("PANEL_ADMIN_FIRSTNAME")
  [ -z "$PANEL_ADMIN_LASTNAME" ] && missing+=("PANEL_ADMIN_LASTNAME")

  if [ ${#missing[@]} -gt 0 ]; then
    error "Missing required configuration variables:"
    for var in "${missing[@]}"; do
      output "  - $var"
    done
    exit 1
  fi

  if ! check_fqdn "$PANEL_FQDN" && ! is_ip_address "$PANEL_FQDN"; then
    error "Invalid FQDN: $PANEL_FQDN"
    exit 1
  fi

  if is_ip_address "$PANEL_FQDN" && { [ "$CONFIGURE_LETSENCRYPT" == true ] || [ -n "$SSL_CERT_PATH" ]; }; then
    warning "Let's Encrypt/custom SSL cannot be used with an IP address ($PANEL_FQDN). Disabling SSL."
    CONFIGURE_LETSENCRYPT=false
    SSL_CERT_PATH=""
    SSL_KEY_PATH=""
  fi

  success "Configuration valid"
}

# ------------------ Dependencies ----------------- #

install_dependencies() {
  print_flame "Installing Dependencies"

  update_repos true

  case "$OS" in
    ubuntu|debian)
      configure_php_apt_repo

      install_packages "php${PHP_VERSION}-fpm php${PHP_VERSION}-cli php${PHP_VERSION}-gd php${PHP_VERSION}-mysql php${PHP_VERSION}-pdo php${PHP_VERSION}-mbstring php${PHP_VERSION}-tokenizer php${PHP_VERSION}-bcmath php${PHP_VERSION}-xml php${PHP_VERSION}-curl php${PHP_VERSION}-zip php${PHP_VERSION}-intl php${PHP_VERSION}-redis"

      ensure_php_default
      ;;

    rocky|almalinux|fedora|rhel|centos)
      output "Configuring RHEL repositories..."
      install_packages "epel-release"
      dnf install -y "https://rpms.remirepo.net/enterprise/remi-release-${OS_VER_MAJOR}.rpm"
      dnf module reset php -y
      dnf module enable php:remi-${PHP_VERSION} -y

      install_packages "php php-fpm php-cli php-gd php-mysqlnd php-pdo php-mbstring php-tokenizer php-bcmath php-xml php-curl php-zip php-intl php-redis"
      php_fpm_conf
      ;;
  esac

  # Install common packages
  install_packages "nginx mariadb-server redis-server curl tar unzip git jq"

  if [ "$CONFIGURE_LETSENCRYPT" == true ]; then
    install_packages "certbot python3-certbot-nginx"
  fi

  # Enable Redis now - configure_panel() runs artisan commands with
  # --cache=redis/--session=redis/--queue=redis and needs a live
  # connection well before setup_services() (which used to be the only
  # place this was enabled) ever runs.
  enable_redis

  success "Dependencies installed"
}

# ------------------ MariaDB ----------------- #

setup_database() {
  print_flame "Setting up MariaDB"

  output "Starting MariaDB service..."
  systemctl start mariadb
  systemctl enable mariadb



  # Check if MariaDB is accessible with current credentials
  if mysql_root "${MYSQL_ROOT_PASSWORD}" -e "SELECT 1" >/dev/null 2>&1; then
    output "MariaDB connection successful with existing credentials"
  # Check if MariaDB has no root password set (fresh install)
  elif mysql -u root -e "SELECT 1" >/dev/null 2>&1; then
    output "Securing MariaDB with new credentials..."
    mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';" 2>/dev/null || true

    # Verify the new password works
    if ! mysql_root "${MYSQL_ROOT_PASSWORD}" -e "SELECT 1" >/dev/null 2>&1; then
      error "Failed to set MariaDB root password"
      exit 1
    fi

    # Remove anonymous users and test database
    mysql_root "${MYSQL_ROOT_PASSWORD}" -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null || true
    mysql_root "${MYSQL_ROOT_PASSWORD}" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" 2>/dev/null || true
    mysql_root "${MYSQL_ROOT_PASSWORD}" -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
    mysql_root "${MYSQL_ROOT_PASSWORD}" -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';" 2>/dev/null || true
    mysql_root "${MYSQL_ROOT_PASSWORD}" -e "FLUSH PRIVILEGES;" 2>/dev/null || true
  else
    # Cannot connect - MariaDB is secured with unknown password
    error "Cannot connect to MariaDB"
    error "MariaDB appears to be secured with a password that doesn't match our records"
    error "Please either:"
    error "  1. Set MYSQL_ROOT_PASSWORD environment variable to the correct password"
    error "  2. Reset MariaDB root password manually"
    error "  3. Remove /root/.config/hydrodactyl/db-credentials if you want to start fresh"
    exit 1
  fi

  # Save credentials
  mkdir -p /root/.config/hydrodactyl
  echo "root:${MYSQL_ROOT_PASSWORD}" > /root/.config/hydrodactyl/db-credentials
  chmod 600 /root/.config/hydrodactyl/db-credentials

  # Create panel database and user
  output "Creating panel database..."
  mysql_root "${MYSQL_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME};" 2>/dev/null || true

  # Check if user exists, create or update password
  local user_exists
  user_exists=$(mysql_root "${MYSQL_ROOT_PASSWORD}" -N -B -e "SELECT COUNT(*) FROM mysql.user WHERE user='${DB_USER}' AND host='${DB_HOST}';" 2>/dev/null || echo "0")

  if [ "$user_exists" == "0" ]; then
    mysql_root "${MYSQL_ROOT_PASSWORD}" -e "CREATE USER '${DB_USER}'@'${DB_HOST}' IDENTIFIED BY '${DB_PASSWORD}';" 2>/dev/null || true
  else
    mysql_root "${MYSQL_ROOT_PASSWORD}" -e "ALTER USER '${DB_USER}'@'${DB_HOST}' IDENTIFIED BY '${DB_PASSWORD}';" 2>/dev/null || true
  fi

  mysql_root "${MYSQL_ROOT_PASSWORD}" -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'${DB_HOST}';" 2>/dev/null || true
  mysql_root "${MYSQL_ROOT_PASSWORD}" -e "FLUSH PRIVILEGES;" 2>/dev/null || true

  success "Database configured"
}

# ------------------ Panel Installation ----------------- #

install_panel_release() {
  print_flame "Installing Panel from Release"

  # Ensure jq is installed for JSON parsing
  if ! cmd_exists jq; then
    output "Installing jq for JSON parsing..."
    install_packages "jq" true
  fi

  # Only require token for private repos
  if [ "$PANEL_REPO_PRIVATE" == "true" ] && [ -z "$GITHUB_TOKEN" ]; then
    error "GitHub token is required to download the panel from the private repository."
    error "Please provide a token using --github-token or set the GITHUB_TOKEN environment variable."
    exit 1
  fi

  # Determine which release to fetch
  local release_endpoint="latest"
  if [ "$PANEL_RELEASE_VERSION" != "latest" ]; then
    # URL-encode the version tag for the API path (handles special characters like +, spaces, etc.)
    local encoded_version
    encoded_version=$(printf '%s' "$PANEL_RELEASE_VERSION" | jq -sRr @uri 2>/dev/null || echo "$PANEL_RELEASE_VERSION")
    release_endpoint="tags/${encoded_version}"
    output "Fetching release ${PANEL_RELEASE_VERSION} from ${PANEL_REPO}..."
  else
    output "Fetching latest release from ${PANEL_REPO}..."
  fi

  # Build curl headers based on whether we have a token
  local curl_headers=(
    "--header" "Accept: application/vnd.github+json"
    "--header" "X-GitHub-Api-Version: 2022-11-28"
  )

  if [ -n "$GITHUB_TOKEN" ]; then
    curl_headers+=("--header" "Authorization: Bearer $GITHUB_TOKEN")
  fi

  # Get the release info from GitHub API
  local release_data
  release_data=$(curl -sS "${curl_headers[@]}" \
    "https://api.github.com/repos/${PANEL_REPO}/releases/${release_endpoint}")

  # Check if we got a valid response
  if echo "$release_data" | grep -q '"message"'; then
    error "Failed to fetch release data from ${PANEL_REPO}"
    error "API Response: $(echo "$release_data" | jq -r '.message' 2>/dev/null || echo "$release_data")"
    if [ "$PANEL_REPO_PRIVATE" != "true" ]; then
      error "If this is a private repository, please set PANEL_REPO_PRIVATE=true and provide a GITHUB_TOKEN"
    fi
    exit 1
  fi

  # Get the asset API URL
  local asset_api_url
  asset_api_url=$(echo "$release_data" | jq -r ".assets[] | select(.name == \"panel.tar.gz\") | .url")

  if [ -z "$asset_api_url" ] || [ "$asset_api_url" == "null" ]; then
    error "Could not find asset 'panel.tar.gz' in latest release"
    error "Available assets: $(echo "$release_data" | jq -r '.assets[].name' 2>/dev/null || echo "(failed to parse)")"
    exit 1
  fi

  local release_tag
  release_tag=$(echo "$release_data" | jq -r '.tag_name')
  info "Installing release: $release_tag"

  # Save version from GitHub release tag to persistent location
  output "Recording version from GitHub: $release_tag"
  mkdir -p /etc/hydrodactyl
  echo "$release_tag" > /etc/hydrodactyl/panel-version
  chmod 644 /etc/hydrodactyl/panel-version

  # Persist the repo/token/method for the manual update menu
  save_panel_update_config "releases"

  output "Creating installation directory..."
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  output "Downloading panel.tar.gz..."

  # Build download headers - token optional for public repos
  local download_headers=(
    "--header" "Accept: application/octet-stream"
    "--header" "X-GitHub-Api-Version: 2022-11-28"
  )

  if [ -n "$GITHUB_TOKEN" ]; then
    download_headers+=("--header" "Authorization: Bearer $GITHUB_TOKEN")
  fi

  # Download using the asset API URL
  if ! curl --location --fail --silent --show-error "${download_headers[@]}" \
    --output panel.tar.gz \
    "$asset_api_url"; then
    error "Failed to download panel from repository"
    if [ "$PANEL_RELEASE_VERSION" != "latest" ]; then
      error "Release ${PANEL_RELEASE_VERSION} may not exist or the asset 'panel.tar.gz' is not available."
    fi
    if [ "$PANEL_REPO_PRIVATE" == "true" ]; then
      error "Please check that your GitHub token has 'repo' scope and the release exists."
    else
      error "Please check that the release exists and is accessible."
    fi
    exit 1
  fi

  output "Extracting files..."
  tar -xzf panel.tar.gz
  rm -f panel.tar.gz

  # Check if .env.example exists, if not download from repo
  if [ ! -f ".env.example" ]; then
    output ".env.example not found in release, downloading from repository..."
    local env_url="https://raw.githubusercontent.com/${PANEL_REPO}/main/.env.example"

    if [ -n "$GITHUB_TOKEN" ]; then
      curl -fsSL \
        --header "Authorization: Bearer $GITHUB_TOKEN" \
        --header "Accept: application/vnd.github.v3.raw" \
        -o .env.example \
        "$env_url" || warning "Failed to download .env.example from repository"
    else
      curl -fsSL -o .env.example "$env_url" || warning "Failed to download .env.example from repository"
    fi

    if [ ! -f ".env.example" ]; then
      error "Could not obtain .env.example file"
      error "The release package may be incomplete or the repository may be inaccessible"
      exit 1
    fi
  fi

  cp .env.example .env

  # Match the official install docs: set storage/bootstrap-cache permissions
  # right after getting the source, before composer/artisan touch them.
  chmod -R 755 storage/* bootstrap/cache/

  # Install composer and dependencies
  install_composer

  [ "$OS" == "rocky" ] || [ "$OS" == "almalinux" ] && export PATH=/usr/local/bin:$PATH

  output "Installing composer dependencies..."
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction

  # Build frontend assets
  build_panel_assets "$INSTALL_DIR"

  success "Panel downloaded to $INSTALL_DIR"
}

install_panel_clone() {
  print_flame "Installing Panel from Git Repository"

  if [ -d "$INSTALL_DIR" ] && [ "$(ls -A "$INSTALL_DIR")" ]; then
    error "Directory $INSTALL_DIR already exists and is not empty"
    exit 1
  fi

  mkdir -p "$(dirname "$INSTALL_DIR")"

  # Simple token-based auth: embed token in URL if provided
  local git_url="https://github.com/${PANEL_REPO}.git"
  [ -n "$GITHUB_TOKEN" ] && git_url="https://${GITHUB_TOKEN}@github.com/${PANEL_REPO}.git"

  output "Cloning from https://github.com/${PANEL_REPO}.git"
  if ! git clone "$git_url" "$INSTALL_DIR"; then
    error "Failed to clone repository"
    exit 1
  fi

  cd "$INSTALL_DIR"

  # Save commit hash for auto-updater tracking
  local commit_hash
  commit_hash=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
  output "Recording git commit hash: ${commit_hash:0:8}"
  mkdir -p /etc/hydrodactyl
  echo "git:${commit_hash}" > /etc/hydrodactyl/panel-version
  chmod 644 /etc/hydrodactyl/panel-version

  # Persist the repo/token/method for the manual update menu
  save_panel_update_config "git"

  cp .env.example .env

  # Match the official install docs: set storage/bootstrap-cache permissions
  # right after getting the source, before composer/artisan touch them.
  chmod -R 755 storage/* bootstrap/cache/

  # Install composer and dependencies
  install_composer

  [ "$OS" == "rocky" ] || [ "$OS" == "almalinux" ] && export PATH=/usr/local/bin:$PATH

  output "Installing composer dependencies..."
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction

  # Build frontend assets
  build_panel_assets "$INSTALL_DIR"

  success "Panel cloned to $INSTALL_DIR"
}

# ------------------ Panel Configuration ----------------- #

configure_panel() {
  print_flame "Configuring Panel"

  cd "$INSTALL_DIR"

  # Clear any bootstrap cache baked into the release tarball or created by
  # composer's post-install scripts (e.g. package:discover/optimize running
  # against the still-default .env we just copied). A stale cached config
  # makes Laravel ignore .env entirely - including the key we're about to
  # generate - and "php artisan key:generate" itself fails with
  # "No application encryption key has been specified" before writing
  # anything. `artisan config:clear` can't fix this (it needs the framework
  # to boot too), so remove the cache files directly.
  rm -f bootstrap/cache/*.php

  # p:environment:setup never touches APP_KEY, so "key:generate" has to be
  # the thing that sets it - but Laravel boots EncryptionServiceProvider
  # (which requires app.key to already be non-empty) before any console
  # command runs, including key:generate itself. With a fresh .env (APP_KEY
  # empty), that boot step throws "No application encryption key has been
  # specified" before key:generate ever gets a chance to write a new one.
  # Seed a throwaway key first so boot succeeds; key:generate --force then
  # overwrites it with the real one.
  if grep -q "^APP_KEY=" .env; then
    sed -i "s|^APP_KEY=.*$|APP_KEY=base64:$(head -c 32 /dev/urandom | base64 | tr -d '\n')|g" .env
  else
    echo "APP_KEY=base64:$(head -c 32 /dev/urandom | base64 | tr -d '\n')" >> .env
  fi

  # Generate application key
  output "Generating application key..."
  php artisan key:generate --force

  # Determine app URL - panel_scheme() also accounts for a custom SSL
  # certificate (SSL_CERT_PATH), unlike checking ASSUME_SSL/CONFIGURE_LETSENCRYPT
  # alone, which left APP_URL on http while nginx actually served https.
  local panel_url_host_part
  panel_url_host_part=$(panel_url_host "$PANEL_FQDN")
  local app_url
  app_url="$(panel_scheme)://${panel_url_host_part}"

  # Setup environment
  output "Configuring environment..."
  php artisan p:environment:setup -n \
    --author="$PANEL_ADMIN_EMAIL" \
    --url="$app_url" \
    --timezone="$PANEL_TIMEZONE" \
    --cache="redis" \
    --session="redis" \
    --queue="redis" \
    --redis-host="localhost" \
    --redis-pass="null" \
    --redis-port="6379" \
    --settings-ui=true </dev/null

  # Configure database
  output "Configuring database connection..."
  php artisan p:environment:database -n \
    --host="$DB_HOST" \
    --port="$DB_PORT" \
    --database="$DB_NAME" \
    --username="$DB_USER" \
    --password="$DB_PASSWORD" </dev/null

  # Run migrations
  output "Running database migrations..."
  php artisan migrate --seed --force </dev/null

  # Create admin user
  output "Creating admin user..."
  php artisan p:user:make -n \
    --email="$PANEL_ADMIN_EMAIL" \
    --username="$PANEL_ADMIN_USERNAME" \
    --name-first="$PANEL_ADMIN_FIRSTNAME" \
    --name-last="$PANEL_ADMIN_LASTNAME" \
    --password="$PANEL_ADMIN_PASSWORD" \
    --admin </dev/null

  success "Panel configured"
}

# ------------------ Services ----------------- #

setup_services() {
  print_flame "Setting up Services"

  # Set permissions
  output "Setting file permissions..."
  chown -R "$WEBUSER":"$WEBGROUP" "$INSTALL_DIR"

  # Apply correct permissions: 755 for directories, 644 for files
  if [ -d "$INSTALL_DIR/storage" ]; then
    find "$INSTALL_DIR/storage" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$INSTALL_DIR/storage" -type f -exec chmod 644 {} \; 2>/dev/null || true
  fi
  if [ -d "$INSTALL_DIR/bootstrap/cache" ]; then
    find "$INSTALL_DIR/bootstrap/cache" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$INSTALL_DIR/bootstrap/cache" -type f -exec chmod 644 {} \; 2>/dev/null || true
  fi

  # Enable nginx
  systemctl enable nginx

  # Enable MariaDB
  systemctl enable mariadb

  # SELinux configuration for RHEL
  selinux_allow

  # Check for port conflicts before nginx setup
  if ! check_port_conflicts; then
    warning "Skipping nginx configuration due to port conflict"
  else
    # Setup nginx
    local php_socket
    php_socket=$(get_php_socket)

    local use_ssl=false
    has_custom_ssl_cert && use_ssl=true

    install_nginx_config "$PANEL_FQDN" "$php_socket" "$use_ssl" "$SSL_CERT_PATH" "$SSL_KEY_PATH"
  fi

  # Setup SSL if requested
  if [ "$CONFIGURE_LETSENCRYPT" == true ]; then
    install_letsencrypt "$PANEL_FQDN" "$PANEL_ADMIN_EMAIL"
  fi

  # Setup cron
  insert_cronjob

  # Install queue worker
  install_hydroq

  # Ensure PHP 8.4 is the default (in case other packages changed it)
  ensure_php_default true

  # Reload nginx to apply any config changes
  systemctl reload nginx 2>/dev/null || true

  success "Services configured"
}

# ------------------ Firewall ----------------- #

configure_firewall() {
  if [ "$CONFIGURE_FIREWALL" != true ]; then
    return 0
  fi

  print_flame "Configuring Firewall"

  install_firewall

  # 3306 is opened only when DB_REMOTE_HOSTS names the clients that may connect.
  # phpMyAdmin listens on 127.0.0.1 and does not need a public port.
  local include_https=false
  [ "$CONFIGURE_LETSENCRYPT" == true ] || [ -n "$SSL_CERT_PATH" ] && include_https=true
  local ports
  ports=$(panel_firewall_ports "${DB_REMOTE_HOSTS:-}" "$include_https")

  firewall_allow_ports "$ports"

  success "Firewall configured"
}

# ------------------ Main ----------------- #

main() {
  print_header
  print_flame "Starting Hydrodactyl Panel Installation"

  validate_configuration

  # Check for existing installation
  if check_existing_installation "panel"; then
    warning "Existing panel installation detected"
    local confirm_overwrite=""
    bool_input confirm_overwrite "Continue and overwrite existing installation?" "n"
    if [ "$confirm_overwrite" != "y" ]; then
      error "Installation aborted"
      exit 1
    fi
  fi

  # Install
  install_dependencies
  setup_database

  if [ "$PANEL_INSTALL_METHOD" == "release" ]; then
    install_panel_release
  else
    install_panel_clone
  fi

  configure_panel
  setup_services
  install_phpmyadmin
  configure_mariadb_tcp
  setup_database_host "$PANEL_FQDN"

  # Generate API key for node (Wings/Wings-RS/Elytra) setup
  output "Generating Application API Key for node automation..."
  PANEL_API_KEY=$(generate_api_key "$INSTALL_DIR" 2>/dev/null || echo "")
  if [ -n "$PANEL_API_KEY" ]; then
    success "API Key generated successfully"
    # Save API key to credentials file for later use
    mkdir -p /root/.config/hydrodactyl
    echo "api_key:${PANEL_API_KEY}" >> /root/.config/hydrodactyl/db-credentials
    chmod 600 /root/.config/hydrodactyl/db-credentials
  else
    warning "Failed to generate API key - you will need to create one manually for node setup"
    warning "You can create one in Admin > API Keys after installation"
  fi

  configure_firewall

  # Final output
  print_header
  print_flame "Installation Complete!"

  echo ""
  output "🎉 Your Hydrodactyl Panel has been installed successfully!"
  echo ""
  output "Panel URL: ${COLOR_ORANGE}$(panel_scheme)://$(panel_url_host "$PANEL_FQDN")${COLOR_NC}"
  output "Admin Email: ${COLOR_ORANGE}${PANEL_ADMIN_EMAIL}${COLOR_NC}"
  output "Admin Username: ${COLOR_ORANGE}${PANEL_ADMIN_USERNAME}${COLOR_NC}"
  output "Admin Password: ${COLOR_ORANGE}**hidden** (hope you remember it!)${COLOR_NC}"
  echo ""
  output "Database credentials saved to: ${COLOR_ORANGE}/root/.config/hydrodactyl/db-credentials${COLOR_NC}"
  echo ""
  output "phpMyAdmin Access (this machine only):"
  output "  URL: ${COLOR_ORANGE}http://127.0.0.1:8081${COLOR_NC}"
  output "  Username: ${COLOR_ORANGE}phpmyadmin${COLOR_NC}"
  output "  Password: ${COLOR_ORANGE}${PHPMYADMIN_PASSWORD}${COLOR_NC}"
  echo ""
  if [ -n "$PANEL_API_KEY" ]; then
    output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    output "  API Key for Node Setup"
    output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    output "API Key: ${COLOR_ORANGE}${PANEL_API_KEY}${COLOR_NC}"
    echo ""
    output "Save this API key! You can use it to automatically configure"
    output "your daemon without manually entering node ID and token."
    output "When running wings.sh (or elytra.sh for legacy installs),"
    output "enter this API key when prompted."
    echo ""
  fi

  output "Service Commands:"
  output "  ${COLOR_ORANGE}systemctl status hydroq${COLOR_NC}    - Panel queue worker"
  output "  ${COLOR_ORANGE}systemctl status nginx${COLOR_NC}    - Web server"
  output "  ${COLOR_ORANGE}systemctl status mariadb${COLOR_NC}  - Database"
  echo ""

  print_brake 70

  # Save installation information
  save_panel_install_info "install"

  # Pause to let user review logs before showing completion screen
  echo ""
  output "Installation finished, press Enter to view details..."
  read -r

  # Show completion screen
  show_panel_completion "install"

  # Run health check
  echo ""
  output "Running post-installation health check..."
  check_panel_health "$INSTALL_DIR"
}

main "$@"
