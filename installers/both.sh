#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Hydrodactyl + Wings Combined Installer                                             #
#                                                                                    #
# Installs both Panel and Wings on the same machine with automatic configuration     #
#                                                                                    #
######################################################################################

# Check if lib is loaded, load if not or fail otherwise.
fn_exists() { declare -F "$1" >/dev/null; }
if ! fn_exists lib_loaded; then
  # Try temp file first (when run through install.sh)
  if [ -f /tmp/hydrodactyl-lib.sh ]; then
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

# Panel configuration
PANEL_REPO="${PANEL_REPO:-BlueprintFramework/hydrodactyl}"
PANEL_INSTALL_METHOD="${PANEL_INSTALL_METHOD:-release}"
PANEL_RELEASE_VERSION="${PANEL_RELEASE_VERSION:-latest}"
PANEL_FQDN="${PANEL_FQDN:-}"
PANEL_TIMEZONE="${PANEL_TIMEZONE:-UTC}"
PANEL_ADMIN_EMAIL="${PANEL_ADMIN_EMAIL:-}"
PANEL_ADMIN_USERNAME="${PANEL_ADMIN_USERNAME:-}"
PANEL_ADMIN_FIRSTNAME="${PANEL_ADMIN_FIRSTNAME:-}"
PANEL_ADMIN_LASTNAME="${PANEL_ADMIN_LASTNAME:-}"
PANEL_ADMIN_PASSWORD="${PANEL_ADMIN_PASSWORD:-$(gen_passwd 32)}"
ASSUME_SSL="${ASSUME_SSL:-false}"
CONFIGURE_LETSENCRYPT="${CONFIGURE_LETSENCRYPT:-false}"
SSL_CERT_PATH="${SSL_CERT_PATH:-}"
SSL_KEY_PATH="${SSL_KEY_PATH:-}"

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

# Wings configuration
WINGS_VARIANT="${WINGS_VARIANT:-go}"
WINGS_VARIANT=$(echo "$WINGS_VARIANT" | tr '[:upper:]' '[:lower:]')
# Validate here, before install_docker/panel/daemon setup run, instead of
# only in wings_release_arch() deep inside install_wings_daemon() - a typo
# in the WINGS_VARIANT env var would otherwise waste that work before failing.
case "$WINGS_VARIANT" in
  go | rs) ;;
  *)
    error "Unsupported Wings variant: $WINGS_VARIANT (expected 'go' or 'rs')"
    exit 1
    ;;
esac
# Repo default depends on variant (pterodactyl/wings vs calagopus/wings) and
# is resolved in install_wings_daemon() - do not default it here, or a
# variant-specific default below would never apply once this is non-empty.
WINGS_REPO="${WINGS_REPO:-}"
WINGS_RELEASE_VERSION="${WINGS_RELEASE_VERSION:-latest}"
NODE_NAME="${NODE_NAME:-local}"
NODE_DESCRIPTION="${NODE_DESCRIPTION:-Local Node}"
NODE_TOKEN="${NODE_TOKEN:-$(gen_passwd 32)}"
BEHIND_PROXY="${BEHIND_PROXY:-false}"

# General
CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-false}"
GAME_PORT_START="${GAME_PORT_START:-27015}"
GAME_PORT_END="${GAME_PORT_END:-28025}"

# GitHub
PANEL_REPO_PRIVATE="${PANEL_REPO_PRIVATE:-false}"
WINGS_REPO_PRIVATE="${WINGS_REPO_PRIVATE:-false}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
# Panel and Wings can be hosted in different repos with different tokens
# (e.g. a public panel fork + a private custom Wings repo); GITHUB_TOKEN is
# kept as a single-value fallback for direct CLI/env-var usage.
GITHUB_TOKEN_PANEL="${GITHUB_TOKEN_PANEL:-$GITHUB_TOKEN}"
GITHUB_TOKEN_WINGS="${GITHUB_TOKEN_WINGS:-$GITHUB_TOKEN}"

# Paths
INSTALL_DIR="${INSTALL_DIR:-/var/www/hydrodactyl}"
# This script only ever installs Wings, never legacy Elytra.
# Resolved in main() from the saved layout, or the namespaced defaults.
WINGS_INSTALL_DIR=""
PANEL_CONFIG_DIR="${PANEL_CONFIG_DIR:-/etc/hydrodactyl}"

# Node ID (will be set during installation)
NODE_ID=""

# Validation
missing=()

for var in PANEL_FQDN PANEL_ADMIN_EMAIL PANEL_ADMIN_USERNAME PANEL_ADMIN_FIRSTNAME PANEL_ADMIN_LASTNAME; do
  if [[ -z "${!var}" ]]; then
    missing+=("$var")
  fi
done

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

# Inline validation for backwards compatibility
if (( ${#missing[@]} > 0 )); then
  print_header
  print_flame "Missing Required Variables"
  for m in "${missing[@]}"; do
    error "${m} is required"
  done
  exit 1
fi

# Validate FQDN
if ! check_fqdn "$PANEL_FQDN" && ! is_ip_address "$PANEL_FQDN"; then
  error "Invalid FQDN: $PANEL_FQDN"
  error "FQDN must be a valid domain name or IP address"
  exit 1
fi

if is_ip_address "$PANEL_FQDN" && { [ "$CONFIGURE_LETSENCRYPT" == true ] || [ -n "$SSL_CERT_PATH" ]; }; then
  warning "Let's Encrypt/custom SSL cannot be used with an IP address ($PANEL_FQDN). Disabling SSL."
  CONFIGURE_LETSENCRYPT=false
  SSL_CERT_PATH=""
  SSL_KEY_PATH=""
fi

# ---------------- Installation Functions ---------------- #

check_existing() {
  local panel_exists=false
  local wings_exists=false

  if check_existing_installation "panel"; then
    panel_exists=true
  fi

  if [ "$WINGS_INSTALL_STATE" = "legacy" ] || [ "$WINGS_INSTALL_STATE" = "namespaced" ]; then
    wings_exists=true
    warning "Existing Hydrodactyl Wings installation detected at ${WINGS_BINARY}"
  fi

  if [ "$WINGS_FOREIGN_PRESENT" = true ]; then
    output "Another Wings install is already on this machine. It will not be stopped or overwritten."
    output "Hydrodactyl Wings will use ${WINGS_BINARY} and ${WINGS_CONFIG_DIR}."
  fi

  if [ "$panel_exists" = true ] || [ "$wings_exists" = true ]; then
    echo ""
    local confirm_replace=""
    bool_input confirm_replace "Continue with installation? This may overwrite existing files" "n"
    if [ "$confirm_replace" != "y" ]; then
      error "Installation aborted."
      exit 1
    fi
  fi

  if [ "$wings_exists" = true ] && [ "$WINGS_BINARY_SHARED" = true ]; then
    if ! wings_confirm "Replace the shared Wings binary anyway? Another panel uses it" "n"; then
      error "Installation aborted."
      exit 1
    fi
    export WINGS_ALLOW_SHARED_BINARY=1
  fi

  if [ "$wings_exists" = true ]; then
    wings_stop_owned_service "$WINGS_SERVICE" || true
  fi

  if [ "$panel_exists" = true ]; then
    systemctl stop hydroq 2>/dev/null || true
  fi
}

# ---------------- Panel Installation ---------------- #

install_panel_dependencies() {
  print_flame "Installing Panel Dependencies"

  update_repos true

  case "$OS" in
    ubuntu|debian)
      configure_php_apt_repo
      install_packages "php${PHP_VERSION}-fpm php${PHP_VERSION}-cli php${PHP_VERSION}-gd php${PHP_VERSION}-mysql php${PHP_VERSION}-pdo php${PHP_VERSION}-mbstring php${PHP_VERSION}-tokenizer php${PHP_VERSION}-bcmath php${PHP_VERSION}-xml php${PHP_VERSION}-curl php${PHP_VERSION}-zip php${PHP_VERSION}-intl php${PHP_VERSION}-redis php${PHP_VERSION}-sqlite3"

      ensure_php_default
      ;;

    rocky|almalinux)
      output "Setting up RHEL repositories..."
      install_packages "epel-release"
      dnf install -y "https://rpms.remirepo.net/enterprise/remi-release-${OS_VER_MAJOR}.rpm"
      dnf module reset php -y
      dnf module enable php:remi-${PHP_VERSION} -y
      install_packages "php-fpm php-cli php-gd php-mysqlnd php-pdo php-mbstring php-tokenizer php-bcmath php-xml php-curl php-zip php-intl php-redis php-sqlite3"
      php_fpm_conf
      ;;
  esac

  # Install common packages
  install_packages "nginx mariadb-server redis-server curl tar unzip git certbot python3-certbot-nginx jq"

  # Enable Redis now - configure_panel_environment() runs artisan commands
  # with --cache=redis/--session=redis/--queue=redis and needs a live
  # connection well before setup_panel_services() (which used to be the
  # only place this was enabled) ever runs.
  enable_redis

  success "Panel dependencies installed"
}

install_panel_release() {
  print_flame "Downloading Panel Release"

  # Ensure jq is installed for JSON parsing
  if ! cmd_exists jq; then
    output "Installing jq for JSON parsing..."
    install_packages "jq" true
  fi

  # Only require token for private repos
  if [ "$PANEL_REPO_PRIVATE" == "true" ] && [ -z "$GITHUB_TOKEN_PANEL" ]; then
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

  if [ -n "$GITHUB_TOKEN_PANEL" ]; then
    curl_headers+=("--header" "Authorization: Bearer $GITHUB_TOKEN_PANEL")
  fi

  # Get the release info from GitHub API
  local release_data
  release_data=$(curl -sS "${curl_headers[@]}" \
    "https://api.github.com/repos/${PANEL_REPO}/releases/${release_endpoint}")

  # Check if we got a valid response
  if echo "$release_data" | grep -q '"message"'; then
    error "Failed to fetch release data from ${PANEL_REPO}"
    error "API Response: $(echo "$release_data" | jq -r '.message' 2>/dev/null || echo "$release_data")"
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

  if [ -n "$GITHUB_TOKEN_PANEL" ]; then
    download_headers+=("--header" "Authorization: Bearer $GITHUB_TOKEN_PANEL")
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

    if [ -n "$GITHUB_TOKEN_PANEL" ]; then
      curl -fsSL \
        --header "Authorization: Bearer $GITHUB_TOKEN_PANEL" \
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
  print_flame "Cloning Panel Repository"

  if [ -d "$INSTALL_DIR" ] && [ "$(ls -A "$INSTALL_DIR")" ]; then
    error "Directory $INSTALL_DIR already exists and is not empty"
    exit 1
  fi

  mkdir -p "$(dirname "$INSTALL_DIR")"

  # Simple token-based auth: embed token in URL if provided
  local git_url="https://github.com/${PANEL_REPO}.git"
  [ -n "$GITHUB_TOKEN_PANEL" ] && git_url="https://${GITHUB_TOKEN_PANEL}@github.com/${PANEL_REPO}.git"

  output "Cloning from https://github.com/${PANEL_REPO}.git"
  if ! git clone "$git_url" "$INSTALL_DIR"; then
    error "Failed to clone repository"
    exit 1
  fi

  cd "$INSTALL_DIR"
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

  # Save commit hash for auto-updater tracking
  # Git installs use commit hash as version identifier
  local commit_hash
  commit_hash=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
  output "Recording git commit hash: ${commit_hash:0:8}"
  mkdir -p /etc/hydrodactyl
  echo "git:${commit_hash}" > /etc/hydrodactyl/panel-version
  chmod 644 /etc/hydrodactyl/panel-version

  # Persist the repo/token/method for the manual update menu
  save_panel_update_config "git"

  success "Panel cloned to $INSTALL_DIR"
}

configure_mariadb() {
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
    # Try to set root password (may fail if already secured differently)
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
  mysql_root "${MYSQL_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME};" || { error "Could not create the panel database"; return 1; }

  # Check if user exists, create or update password
  local user_exists
  user_exists=$(mysql_root "${MYSQL_ROOT_PASSWORD}" -N -B -e "SELECT COUNT(*) FROM mysql.user WHERE user='${DB_USER}' AND host='${DB_HOST}';" 2>/dev/null || echo "0")

  if [ "$user_exists" == "0" ]; then
    mysql_root "${MYSQL_ROOT_PASSWORD}" -e "CREATE USER '${DB_USER}'@'${DB_HOST}' IDENTIFIED BY '${DB_PASSWORD}';" || { error "Could not create the panel database user"; return 1; }
  else
    mysql_root "${MYSQL_ROOT_PASSWORD}" -e "ALTER USER '${DB_USER}'@'${DB_HOST}' IDENTIFIED BY '${DB_PASSWORD}';" || { error "Could not update the panel database user"; return 1; }
  fi

  mysql_root "${MYSQL_ROOT_PASSWORD}" -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'${DB_HOST}';" || { error "Could not grant the panel database user access"; return 1; }
  mysql_root "${MYSQL_ROOT_PASSWORD}" -e "FLUSH PRIVILEGES;" || { error "Could not reload MariaDB privileges"; return 1; }

  success "MariaDB configured"
}

configure_panel_environment() {
  print_flame "Configuring Panel Environment"

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

  # Setup environment using artisan commands
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
  output "Configuring database..."
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

  success "Environment configured"
}

setup_panel_services() {
  print_flame "Setting up Panel Services"

  # Set permissions
  output "Setting ownership to $WEBUSER:$WEBGROUP..."
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
    # Install nginx config
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

  success "Panel services configured"
}

# ---------------- Node Creation ---------------- #

create_node_in_panel() {
  print_flame "Creating Node in Panel via API"

  # Check if we have API key for API-based creation
  if [ -n "$PANEL_API_KEY" ] && [ -n "$PANEL_FQDN" ]; then
    local panel_url
    panel_url="$(panel_scheme)://$(panel_url_host "$PANEL_FQDN")"

    # Step 1: Detect country and get/create location
    output "Detecting server location..."
    local country_code
    country_code=$(get_server_country_code)
    info "Detected country code: ${COLOR_ORANGE}${country_code}${COLOR_NC}"

    local location_id
    if ! location_id=$(get_or_create_location "$PANEL_API_KEY" "$panel_url" "$country_code"); then
      error "Failed to set up location via API, falling back to manual method"
      # Fall through to manual method below
    else
      # Step 2: Create node via API
      output "Creating node via API: ${COLOR_ORANGE}${NODE_NAME}${COLOR_NC}" >&2
      local memory_mb
      local disk_mb
      memory_mb=$(get_system_memory)
      disk_mb=$(df -m / | awk 'NR==2 {print $2}')

      if ! NODE_ID=$(create_node_via_api "$PANEL_API_KEY" "$panel_url" "$location_id" "$NODE_NAME" "$memory_mb" "$disk_mb" "$BEHIND_PROXY" "$PANEL_FQDN" "wings" "$(panel_scheme)"); then
        error "Failed to create node via API, falling back to manual method"
        # Fall through to manual method below
      else
        output "DEBUG: Node created via API with NODE_ID=${NODE_ID}"
        success "Node created successfully via API"
        info "Node ID: ${NODE_ID}"
        return 0
      fi
    fi
  fi

  # Fallback: Manual creation using artisan/MySQL
  output "Using manual node creation method..."
  cd "$INSTALL_DIR"

  # Detect system specs
  output "Detecting system specifications..."
  local system_memory
  local system_disk
  system_memory=$(get_system_memory)
  system_disk=$(df -m / | awk 'NR==2 {print $2}')

  # Use detected values or defaults if detection failed
  local max_memory="${system_memory:-8192}"
  local max_disk="${system_disk:-32768}"

  info "Detected Memory: ${max_memory} MB"
  info "Detected Disk: ${max_disk} MB"

  # Create location first
  output "Creating location..."
  php artisan p:location:make -n --short=local --long="Local Location" 2>/dev/null || true

  # Get location ID
  local location_id
  location_id=$(mysql_root "${MYSQL_ROOT_PASSWORD}" -D panel -N -B -e "SELECT id FROM locations WHERE short='local' LIMIT 1;" 2>/dev/null || echo "1")

  # Create node with actual system specs
  output "Creating node: $NODE_NAME..."
  php artisan p:node:make -n \
    --name="$NODE_NAME" \
    --description="$NODE_DESCRIPTION" \
    --locationId="$location_id" \
    --fqdn="$PANEL_FQDN" \
    --public=1 \
    --scheme="$(panel_scheme)" \
    --proxy="$([ "$BEHIND_PROXY" == "true" ] && echo "yes" || echo "no")" \
    --maxMemory="$max_memory" \
    --overallocateMemory=0 \
    --maxDisk="$max_disk" \
    --overallocateDisk=0 \
    --uploadSize=100 </dev/null 2>/dev/null || true

  # Get the node ID
  NODE_ID=$(mysql_root "${MYSQL_ROOT_PASSWORD}" -D panel -N -B -e "SELECT id FROM nodes WHERE name='${NODE_NAME}' LIMIT 1;" 2>/dev/null || echo "1")

  if [ -z "$NODE_ID" ] || [ "$NODE_ID" == "NULL" ]; then
    NODE_ID="1"
  fi

  output "Node ID: $NODE_ID"

  success "Node created in panel (ID: ${NODE_ID})"
}

# ---------------- Wings Installation ---------------- #

install_wings_daemon() {
  print_flame "Installing Wings Daemon"

  # Install Docker using shared function from lib.sh
  install_docker

  if ! wings_finalize_docker_network; then
    error "Could not find a free Docker network. Existing networks could not be read, or every candidate subnet is in use."
    exit 1
  fi

  # Create directories for the selected layout.
  wings_prepare_directories || { error "Failed to create Wings directories"; exit 1; }
  mkdir -p "$PANEL_CONFIG_DIR"

  # Create pterodactyl group first (required for user creation)
  output "Creating pterodactyl system group..."
  if ! getent group pterodactyl >/dev/null 2>&1; then
    groupadd --gid 9999 pterodactyl 2>/dev/null || true
  fi

  # Create pterodactyl user for Wings (UID/GID 9999) if it doesn't exist
  output "Creating pterodactyl system user..."
  if ! id -u pterodactyl >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin --uid 9999 --gid 9999 pterodactyl 2>/dev/null || \
    useradd --system --no-create-home --shell /sbin/nologin --uid 9999 --gid 9999 pterodactyl 2>/dev/null || \
    useradd --system --no-create-home --shell /bin/false --uid 9999 --gid 9999 pterodactyl
  fi

  # Add pterodactyl user to docker group for container management
  if getent group docker >/dev/null 2>&1; then
    output "Adding pterodactyl user to docker group..."
    usermod -aG docker pterodactyl 2>/dev/null || true
  fi

  # Determine architecture and asset name based on the selected Wings variant
  local arch
  arch=$(wings_release_arch "$WINGS_VARIANT") || exit 1

  local asset_name
  if [ "$WINGS_VARIANT" == "rs" ]; then
    asset_name="wings-rs-${arch}-linux"
    WINGS_REPO="${WINGS_REPO:-calagopus/wings}"
  else
    asset_name="wings_linux_${arch}"
    WINGS_REPO="${WINGS_REPO:-pterodactyl/wings}"
  fi

  # Get the release to install - respects WINGS_RELEASE_VERSION if the user
  # selected a specific version in ui/both.sh, otherwise fetches latest.
  local target_release="$WINGS_RELEASE_VERSION"
  if [ "$target_release" == "latest" ]; then
    output "Fetching latest Wings release..."
    target_release=$(get_latest_release "$WINGS_REPO" "$GITHUB_TOKEN_WINGS")
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

  # Download binary
  output "Downloading Wings binary..."
  if ! download_release_asset "$WINGS_REPO" "$asset_name" "$WINGS_BINARY" "$GITHUB_TOKEN_WINGS" "$target_release"; then
    error "Failed to download Wings binary"
    exit 1
  fi

  chmod +x "$WINGS_BINARY"

  # Save version from GitHub release tag for auto-updater tracking
  mkdir -p /etc/hydrodactyl
  echo "$target_release" > /etc/hydrodactyl/wings-version
  chmod 644 /etc/hydrodactyl/wings-version

  # Persist the installed variant/repo for the manual update menu
  save_wings_update_config

  # Create Wings config directory
  output "Creating Wings config directory at ${WINGS_INSTALL_DIR}..."
  mkdir -p "${WINGS_INSTALL_DIR}"
  if [ ! -d "${WINGS_INSTALL_DIR}" ]; then
    error "Failed to create Wings config directory at ${WINGS_INSTALL_DIR}"
    exit 1
  fi

  # Determine panel URL based on configured SSL/TLS
  local panel_url
  panel_url="$(panel_scheme)://$(panel_url_host "$PANEL_FQDN")"

  # Debug output
  output "DEBUG: Wings configuration values:"
  output "DEBUG: NODE_ID=${NODE_ID}"
  output "DEBUG: PANEL_FQDN=${PANEL_FQDN}"
  output "DEBUG: WINGS_INSTALL_DIR=${WINGS_INSTALL_DIR}"

  # Configure Wings using the official configure command
  output "Configuring Wings using 'wings configure' command..."
  if ! wings_run_configure "${panel_url}" "${PANEL_API_KEY}" "${NODE_ID}"; then
    exit 1
  fi

  output "DEBUG: Wings configured successfully"

  # Update container limits for better game server compatibility
  output "Updating container limits in Wings config..."
  sed -i 's/container_pid_limit: 512/container_pid_limit: 2048/' "${WINGS_INSTALL_DIR}/config.yml" 2>/dev/null || true
  # Update installer_limits memory and cpu values
  sed -i 's/memory: 1024/memory: 2048/' "${WINGS_INSTALL_DIR}/config.yml" 2>/dev/null || true
  sed -i 's/cpu: 100/cpu: 200/' "${WINGS_INSTALL_DIR}/config.yml" 2>/dev/null || true

  # Configure SSL for Wings using Let's Encrypt certificates
  output "Configuring SSL for Wings..."
  if [ -f "/etc/letsencrypt/live/${PANEL_FQDN}/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/${PANEL_FQDN}/privkey.pem" ]; then
    # Enable SSL and set certificate paths
    sed -i '/ssl:/,/certificate:/{s/enabled: false/enabled: true/}' "${WINGS_INSTALL_DIR}/config.yml"
    sed -i "s|certificate: .*|certificate: /etc/letsencrypt/live/${PANEL_FQDN}/fullchain.pem|" "${WINGS_INSTALL_DIR}/config.yml"
    sed -i "s|key: .*|key: /etc/letsencrypt/live/${PANEL_FQDN}/privkey.pem|" "${WINGS_INSTALL_DIR}/config.yml"
    success "SSL configured for Wings using Let's Encrypt certificates"
  else
    warning "Let's Encrypt certificates not found, SSL may need manual configuration"
  fi

  # Step 4: Create allocations via API (after Wings configure)
  output "Creating allocations via API..."
  create_node_allocations "$PANEL_API_KEY" "$panel_url" "$NODE_ID" "$GAME_PORT_START" "$GAME_PORT_END" || true

  # Install rustic using shared function from lib.sh
  install_rustic

  # Get systemd service
  output "Setting up Wings service..."
  if ! install_wings_systemd_unit; then
    error "Failed to get Wings service file"
    exit 1
  fi

  local start_status=0
  wings_start_owned_service || start_status=$?

  # Wait for service to start
  sleep 3

  if [ "$start_status" -eq 2 ]; then
    warning "Another Wings service is running and has the API port, so ${WINGS_SERVICE} was not started."
    warning "Stop that service, then run: systemctl enable --now ${WINGS_SERVICE}"
    WINGS_START_RESULT=blocked
  elif [ "$start_status" -eq 0 ] && systemctl is-active --quiet "$WINGS_SERVICE"; then
    success "Wings is running"
    if wings_foreign_reboot_conflict; then
      warning "Another Wings service is enabled. Both use ports 8080 and 2022, so only one stays up after a reboot."
    fi
    WINGS_START_RESULT=started
  else
    warning "Wings service may not have started properly"
    WINGS_START_RESULT=uncertain
  fi
  export WINGS_START_RESULT

  # Set proper ownership and permissions on Wings data directories (after service starts)
  output "Setting Wings data directory permissions..."
  local wings_uid
  wings_uid=$(wings_runtime_uid)
  wings_apply_data_permissions "$WINGS_DATA_DIR" "$wings_uid" "$WINGS_INSTALL_DIR" || warning "Could not set Wings data permissions"

  # Run auto-fix to ensure proper permissions (fixes container access issues)
  output "Running Wings permission fix..."
  auto_fix_wings_issues || true

  case "${WINGS_START_RESULT:-uncertain}" in
    started)
      success "Wings installed and started"
      ;;
    *)
      warning "Wings is installed, but it is not running."
      ;;
  esac
}

# ---------------- Final Configuration ---------------- #

configure_firewall() {
  if [ "$CONFIGURE_FIREWALL" == true ]; then
    print_flame "Configuring Firewall"

    install_firewall

    output "Opening ports for panel and game servers..."
    output "  • 22 (SSH)"
    output "  • 80, 443 (HTTP/HTTPS)"
    output "  • 8080 (Wings API)"
    output "  • 2022 (SFTP)"
    output "  • 25565-25665 (Minecraft)"
    output "  • 27015-27150 (Source Engine - CS:GO, TF2, GMod)"
    output "  • 7777-8000 (Unreal Engine - ARK, Satisfactory)"
    output "  • 28015-28025 (Rust)"
    output "  • 2456-2466 (Valheim)"
    output "  • 30120-30130 (FiveM/GTA)"
    output "  • ${GAME_PORT_START}-${GAME_PORT_END} (Additional range)"

    # 443, Wings, and SFTP stay open. 3306 is added only for DB_REMOTE_HOSTS.
    # phpMyAdmin stays on 127.0.0.1 and is not published.
    local ports
    ports=$(panel_firewall_ports "${DB_REMOTE_HOSTS:-}" true "8080 2022")
    ports="$ports 25565:25665 27015:27150 7777:8000 28015:28025 2456:2466 30120:30130"
    ports="$ports ${GAME_PORT_START}:${GAME_PORT_END}"

    # Allow SSH
    case "$OS" in
      ubuntu|debian)
        ufw allow ssh
        ;;
      rocky|almalinux)
        firewall-cmd --permanent --add-service=ssh
        ;;
    esac

    firewall_allow_ports "$ports"
    success "Firewall configured"
  fi
}

# ---------------- Main ---------------- #

main() {
  print_header
  print_flame "Starting Combined Installation"
  output "This will install Hydrodactyl Panel and Wings on the same machine."
  echo ""

  validate_configuration

  if ! wings_preflight_os; then
    error "Wings installation requires Linux with systemd."
    exit 1
  fi
  if ! wings_resolve_for_action install; then
    error "Could not choose a safe Wings install layout."
    exit 1
  fi

  check_existing

  # Panel installation
  install_panel_dependencies
  configure_mariadb

  if [ "$PANEL_INSTALL_METHOD" == "release" ]; then
    install_panel_release
  else
    install_panel_clone
  fi


  configure_panel_environment
  setup_panel_services
  install_phpmyadmin

  # Generate API key for automated operations
  output "Generating Application API Key..."
  PANEL_API_KEY=$(generate_api_key "$INSTALL_DIR" || echo "")
  if [ -n "$PANEL_API_KEY" ]; then
    success "API Key generated successfully"
    # Save API key to credentials file for later use
    mkdir -p /root/.config/hydrodactyl
    echo "api_key:${PANEL_API_KEY}" >> /root/.config/hydrodactyl/db-credentials
    chmod 600 /root/.config/hydrodactyl/db-credentials
  else
    warning "Failed to generate API key - automated server creation will be skipped"
  fi

  # Create node in panel (uses API key if available)
  create_node_in_panel

  # Configure MariaDB for TCP connections
  configure_mariadb_tcp

  # Setup database host for the panel
  setup_database_host "$PANEL_FQDN"

  # Wings installation
  install_wings_daemon

  # Create Minecraft server if requested and API key is available
  if [ "$CREATE_MINECRAFT_SERVER" == "true" ] && [ -n "$PANEL_API_KEY" ]; then
    print_flame "Creating Minecraft Server"

    # Get the first allocation for this node
    ALLOCATION_ID=$(mysql_root "${MYSQL_ROOT_PASSWORD}" -D panel -N -B -e "SELECT id FROM allocations WHERE node_id=${NODE_ID} LIMIT 1;" 2>/dev/null || echo "")

    if [ -n "$ALLOCATION_ID" ]; then
      # Determine panel URL based on configured SSL/TLS
      PANEL_URL="$(panel_scheme)://$(panel_url_host "$PANEL_FQDN")"

      # Create the server
      if create_minecraft_server "$PANEL_URL" "$PANEL_API_KEY" "$NODE_ID" "$LOCATION_ID" "$ALLOCATION_ID"; then
        CREATED_SERVER_ID=$CREATED_SERVER_ID
        CREATED_SERVER_UUID=$CREATED_SERVER_UUID
        success "Minecraft server created successfully"
      else
        warning "Failed to create Minecraft server automatically"
      fi
    else
      warning "No allocations found for node, skipping server creation"
    fi
  fi

  # Firewall
  configure_firewall

  # Pause to let user review logs before showing completion screen
  echo ""
  output "Installation finished, press Enter to view details..."
  read -r

  print_header
  print_flame "Installation Complete!"

  echo ""
  output "🎉 Hydrodactyl Panel and Wings have been successfully installed!"
  echo ""
  output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  output "  Panel Information"
  output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  output "Panel URL:      ${COLOR_ORANGE}$(panel_scheme)://$(panel_url_host "$PANEL_FQDN")${COLOR_NC}"
  output "Admin Email:    ${COLOR_ORANGE}${PANEL_ADMIN_EMAIL}${COLOR_NC}"
  output "Admin Username: ${COLOR_ORANGE}${PANEL_ADMIN_USERNAME}${COLOR_NC}"
  output "Admin Password: ${COLOR_ORANGE}${PANEL_ADMIN_PASSWORD}${COLOR_NC}"
  echo ""
  if [ -n "$PANEL_API_KEY" ]; then
    output "API Key:        ${COLOR_ORANGE}${PANEL_API_KEY}${COLOR_NC}"
    echo ""
  fi
  output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  output "  phpMyAdmin Database Access"
  output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  output "URL:      ${COLOR_ORANGE}http://127.0.0.1:8081${COLOR_NC} (this machine only)"
  output "Username: ${COLOR_ORANGE}phpmyadmin${COLOR_NC}"
  output "Password: ${COLOR_ORANGE}${PHPMYADMIN_PASSWORD}${COLOR_NC}"
  output "Alternative Logins:"
  output "  - root / ${MYSQL_ROOT_PASSWORD}"
  output "  - ${DB_USER} / ${DB_PASSWORD}"
  echo ""
  output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  output "  Node & Database Host Information"
  output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  output "Node Name:        ${COLOR_ORANGE}${NODE_NAME}${COLOR_NC}"
  output "Node ID:          ${COLOR_ORANGE}${NODE_ID}${COLOR_NC}"
  output "Node Description: ${COLOR_ORANGE}${NODE_DESCRIPTION}${COLOR_NC}"
  if [ -n "${DB_REMOTE_HOSTS:-}" ]; then
    output "Database Host:    ${COLOR_ORANGE}$(panel_url_host "$PANEL_FQDN"):3306${COLOR_NC}"
    output "Remote Clients:   ${COLOR_ORANGE}${DB_REMOTE_HOSTS}${COLOR_NC}"
  else
    output "Database Host:    ${COLOR_ORANGE}127.0.0.1:3306${COLOR_NC}"
  fi
  output "Database User:    ${COLOR_ORANGE}${DB_HOST_USER:-dbhost}${COLOR_NC}"
  if [ -n "${DB_HOST_PASSWORD:-}" ]; then
    output "Database Password:${COLOR_ORANGE}${DB_HOST_PASSWORD}${COLOR_NC}"
  fi
  echo ""
  if [ -n "$CREATED_SERVER_ID" ]; then
    output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    output "  Created Minecraft Server"
    output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    output "Server ID:    ${COLOR_ORANGE}${CREATED_SERVER_ID}${COLOR_NC}"
    output "Server UUID:  ${COLOR_ORANGE}${CREATED_SERVER_UUID}${COLOR_NC}"
    output "Name:         ${COLOR_ORANGE}Minecraft Vanilla Server${COLOR_NC}"
    echo ""
  fi
  output "Game Server Ports Configured (TCP & UDP):"
  output "  • 25565-25665: Minecraft"
  output "  • 27015-27150: Source Engine (CS:GO, TF2, GMod)"
  output "  • 7777-8000: Unreal Engine (ARK, Satisfactory)"
  output "  • 28015-28025: Rust"
  output "  • 2456-2466: Valheim"
  output "  • 30120-30130: FiveM/GTA"
  output "  • ${GAME_PORT_START}-${GAME_PORT_END}: General range"
  echo ""
  output "Both components are configured to work together on this machine!"
  echo ""

  output "Service Commands:"
  output "  ${COLOR_ORANGE}systemctl status hydroq${COLOR_NC}    - Panel queue worker"
  output "  ${COLOR_ORANGE}systemctl status ${WINGS_SERVICE}${COLOR_NC}     - Wings daemon"
  output "  ${COLOR_ORANGE}journalctl -u ${WINGS_SERVICE} -f${COLOR_NC}    - View Wings logs"
  echo ""

  output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  output "  Manual Reconfiguration"
  output "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  output "If you need to reconfigure Wings manually, run:"
  output ""
  output "  ${COLOR_ORANGE}${WINGS_BINARY} --config ${WINGS_CONFIG_FILE} configure \\"
  output "    --panel-url '$(panel_scheme)://$(panel_url_host "$PANEL_FQDN")' \\"
  output "    --token '<your-api-key>' \\"
  output "    --node '${NODE_ID}'${COLOR_NC}"
  echo ""

  print_brake 70

  # Save panel installation information
  save_panel_install_info "install"

  # Save Wings installation information
  save_wings_install_info "install"

  # Show completion screen
  show_both_completion

  # Run health checks
  echo ""
  output "Running post-installation health checks..."
  check_both_health
}

main
