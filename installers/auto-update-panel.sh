#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Hydrodactyl Panel Auto-Updater                                                      #
#                                                                                    #
# Advanced auto-updater with cron support, dry-run mode, backups, and notifications  #
#                                                                                    #
# Usage:                                                                             #
#   auto-update-panel.sh                    # Interactive mode with colors           #
#   auto-update-panel.sh --cron             # Cron mode (no colors, log to file)     #
#   auto-update-panel.sh --dry-run          # Check only, don't actually update       #
#   auto-update-panel.sh --notify-only      # Only send notification if update avail  #
#   auto-update-panel.sh --force            # Force update even if versions match     #
#                                                                                    #
######################################################################################

# ------------------ Configuration ----------------- #

# Load environment file if it exists (for systemd service)
if [ -f /etc/hydrodactyl/auto-update-panel.env ]; then
  # shellcheck source=/dev/null
  source /etc/hydrodactyl/auto-update-panel.env
fi

# Default config (can be overridden by /etc/hydrodactyl/auto-update-panel.env)
PANEL_REPO="${PANEL_REPO:-BlueprintFramework/hydrodactyl}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
INSTALL_DIR="${INSTALL_DIR:-/var/www/hydrodactyl}"
LOG_FILE="${LOG_FILE:-/var/log/hydrodactyl-panel-auto-update.log}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/hydrodactyl}"
LOCK_FILE="${LOCK_FILE:-/var/run/hydrodactyl-panel-update.lock}"
CONFIG_FILE="${CONFIG_FILE:-/etc/hydrodactyl/auto-update-panel.env}"
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"
AUTO_UPDATE="${AUTO_UPDATE:-true}"
CHECK_INTERVAL="${CHECK_INTERVAL:-3600}"
UPDATE_METHOD="${UPDATE_METHOD:-releases}"
PANEL_REPO_PRIVATE="${PANEL_REPO_PRIVATE:-false}"
PANEL_CONFIG_DIR="${PANEL_CONFIG_DIR:-/etc/hydrodactyl}"
GITHUB_BASE_URL="${GITHUB_BASE_URL:-https://raw.githubusercontent.com/itzzjustmateo/hydro-install}"
GITHUB_SOURCE="${GITHUB_SOURCE:-main}"

# ------------------ Runtime Flags ----------------- #

CRON_MODE=false
DRY_RUN=false
NOTIFY_ONLY=false
FORCE_UPDATE=false
VERBOSE=false

# ------------------ Exit Codes ----------------- #

EXIT_SUCCESS=0          # Update successful or no update needed
EXIT_ERROR=1            # General error
EXIT_LOCKED=2           # Another instance is running
EXIT_NO_RELEASE=3       # Could not fetch release info
EXIT_BACKUP_FAILED=4    # Backup failed
EXIT_UPDATE_FAILED=5    # Update failed

# ------------------ Color Setup ----------------- #

setup_colors() {
  if [ "$CRON_MODE" == true ] || [ ! -t 1 ]; then
    COLOR_GREEN=''
    COLOR_YELLOW=''
    COLOR_RED=''
    COLOR_BLUE=''
    COLOR_ORANGE=''
    COLOR_NC=''
  else
    COLOR_GREEN='\033[0;32m'
    COLOR_YELLOW='\033[1;33m'
    COLOR_RED='\033[0;31m'
    COLOR_BLUE='\033[0;34m'
    COLOR_ORANGE='\033[38;5;214m'
    COLOR_NC='\033[0m'
  fi
}

# ------------------ Logging Functions ----------------- #

log() {
  local msg
  msg="[$(date '+%Y-%m-%d %H:%M:%S' || true)] $1"
  echo -e "$msg"

  # Log to file if in cron mode or if LOG_TO_FILE is set
  if [[ "$CRON_MODE" == true ]] || [[ "${LOG_TO_FILE:-}" == true ]]; then
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
  fi
}

output() {
  log "* $1"
}

success() {
  log "${COLOR_GREEN}SUCCESS${COLOR_NC}: $1"
}

error() {
  log "${COLOR_RED}ERROR${COLOR_NC}: $1" >&2
}

warning() {
  log "${COLOR_YELLOW}WARNING${COLOR_NC}: $1"
}

info() {
  log "${COLOR_BLUE}INFO${COLOR_NC}: $1"
}

debug() {
  if [ "$VERBOSE" == true ]; then
    log "${COLOR_ORANGE}DEBUG${COLOR_NC}: $1"
  fi
}

# ------------------ Lock Functions ----------------- #

acquire_lock() {
  mkdir -p "$(dirname "$LOCK_FILE")"

  if [ -f "$LOCK_FILE" ]; then
    local pid
    pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      error "Another update process is already running (PID: $pid)"
      exit $EXIT_LOCKED
    else
      warning "Removing stale lock file (PID $pid not running)"
      rm -f "$LOCK_FILE"
    fi
  fi

  echo $$ > "$LOCK_FILE"
}

release_lock() {
  rm -f "$LOCK_FILE"
}

# ------------------ Configuration Loading ----------------- #

load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    debug "Loading configuration from $CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
  fi
}

# ------------------ Version Functions ----------------- #

get_current_version() {
  # Primary: Read from version file (written by installer from GitHub release tag)
  if [ -f "/etc/hydrodactyl/panel-version" ]; then
    local version
    version=$(cat "/etc/hydrodactyl/panel-version" 2>/dev/null)
    if [ -n "$version" ]; then
      echo "$version"
      return 0
    fi
  fi

  # Fallback: Extract from panel config
  if [ -f "${INSTALL_DIR}/config/app.php" ]; then
    grep "'version'" "${INSTALL_DIR}/config/app.php" 2>/dev/null | \
      head -1 | \
      sed -E "s/.*'version' => '([^']+)'.*/\1/" || \
      echo "unknown"
    return 0
  fi

  echo "unknown"
}

get_latest_release() {
  # Ensure jq is available
  if ! command -v jq >/dev/null 2>&1; then
    log "ERROR: jq is required but not installed"
    return 1
  fi

  local curl_opts=("-sL" "--max-time" "30")

  if [ -n "$GITHUB_TOKEN" ]; then
    curl_opts+=("-H" "Authorization: Bearer $GITHUB_TOKEN")
  fi

  local release_json
  release_json=$(curl "${curl_opts[@]}" \
    "https://api.github.com/repos/$PANEL_REPO/releases/latest" 2>/dev/null)

  if [ -z "$release_json" ] || echo "$release_json" | grep -q '"message":"Not Found"'; then
    return 1
  fi

  echo "$release_json" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'
}

# ------------------ Git-based Update Functions ----------------- #

get_remote_commit_hash() {
  # Use http.extraHeader for auth to avoid persisting token in .git/config
  local git_cmd=("git")
  if [ "$PANEL_REPO_PRIVATE" == "true" ] && [ -n "$GITHUB_TOKEN" ]; then
    git_cmd=("git" "-c" "http.extraHeader=Authorization: Bearer $GITHUB_TOKEN")
  fi

  local remote_hash
  remote_hash=$("${git_cmd[@]}" ls-remote --exit-code "https://github.com/${PANEL_REPO}.git" HEAD 2>/dev/null | awk '{print $1}')

  if [ -z "$remote_hash" ]; then
    error "Failed to fetch remote commit hash"
    return 1
  fi

  echo "$remote_hash"
}

get_local_commit_hash() {
  if [ -d "${INSTALL_DIR}/.git" ]; then
    cd "$INSTALL_DIR"
    git rev-parse HEAD 2>/dev/null || echo "unknown"
  else
    echo "not-a-git-repo"
  fi
}

# ------------------ Update Method Functions ----------------- #

check_for_updates_git() {
  info "Checking for git updates..."

  local local_hash
  local_hash=$(get_local_commit_hash)

  local remote_hash
  remote_hash=$(get_remote_commit_hash)

  if [ $? -ne 0 ] || [ -z "$remote_hash" ]; then
    error "Could not fetch latest commit hash"
    return $EXIT_NO_RELEASE
  fi

  info "Local commit: ${local_hash:0:8}"
  info "Remote commit: ${remote_hash:0:8}"

  if [ "$local_hash" == "$remote_hash" ]; then
    info "Already up to date!"
    return $EXIT_SUCCESS
  fi

  # Update available
  success "Update available: new commits on remote"

  if [ "$NOTIFY_ONLY" == true ]; then
    send_notification "UPDATE_AVAILABLE" "Panel update available: new commits"
    return $EXIT_SUCCESS
  fi

  if [ "$AUTO_UPDATE" != true ] && [ "$DRY_RUN" != true ]; then
    warning "Auto-update is disabled. Set AUTO_UPDATE=true to enable."
    return $EXIT_SUCCESS
  fi

  # Perform update
  if perform_update_git; then
    send_notification "UPDATE_SUCCESS" "Panel updated to latest commit"
    return $EXIT_SUCCESS
  else
    send_notification "UPDATE_FAILED" "Failed to update panel from git"
    return $EXIT_UPDATE_FAILED
  fi
}

check_for_updates_releases() {
  info "Checking for updates..."
  debug "Repository: $PANEL_REPO"
  debug "Install directory: $INSTALL_DIR"

  local current_version
  current_version=$(get_current_version)

  local latest_version
  latest_version=$(get_latest_release)

  if [ -z "$latest_version" ] || [ "$latest_version" == "null" ]; then
    error "Could not fetch latest version"
    return $EXIT_NO_RELEASE
  fi

  info "Current version: $current_version"
  info "Latest version: $latest_version"

  if [ "$current_version" == "$latest_version" ]; then
    info "Already up to date!"
    return $EXIT_SUCCESS
  fi

  if [ "$FORCE_UPDATE" != true ] && ! version_gt "$latest_version" "$current_version"; then
    warning "Current version ($current_version) is newer than latest ($latest_version)"
    warning "This may be a development build"
    return $EXIT_SUCCESS
  fi

  # Update available
  success "Update available: $latest_version"

  if [ "$NOTIFY_ONLY" == true ]; then
    send_notification "UPDATE_AVAILABLE" "Panel update available: $latest_version"
    return $EXIT_SUCCESS
  fi

  if [ "$AUTO_UPDATE" != true ] && [ "$DRY_RUN" != true ]; then
    warning "Auto-update is disabled. Set AUTO_UPDATE=true to enable."
    return $EXIT_SUCCESS
  fi

  # Perform update
  if perform_update "$latest_version"; then
    send_notification "UPDATE_SUCCESS" "Panel updated to $latest_version"
    return $EXIT_SUCCESS
  else
    send_notification "UPDATE_FAILED" "Failed to update panel"
    return $EXIT_UPDATE_FAILED
  fi
}

get_release_notes() {
  local version="$1"
  local curl_opts=("-sL" "--max-time" "30")

  if [ -n "$GITHUB_TOKEN" ]; then
    curl_opts+=("-H" "Authorization: Bearer $GITHUB_TOKEN")
  fi

  curl "${curl_opts[@]}" \
    "https://api.github.com/repos/$PANEL_REPO/releases/tags/$version" 2>/dev/null | \
    jq -r '.body' 2>/dev/null | \
    head -20 || \
    echo "No release notes available"
}

# Version comparison
# Returns 0 if $1 > $2, 1 otherwise
version_gt() {
  test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"
}

# ------------------ Backup Functions ----------------- #

create_backup() {
  info "Creating backup before update..."

  mkdir -p "$BACKUP_DIR"

  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  local backup_name="panel-backup-${timestamp}"
  local backup_path="${BACKUP_DIR}/${backup_name}"

  # Backup files
  debug "Backing up panel files..."
  if ! tar -czf "${backup_path}.tar.gz" -C "$INSTALL_DIR" . 2>/dev/null; then
    error "Failed to create file backup"
    return 1
  fi

  # Backup database
  debug "Backing up database..."
  local db_root_pass=""
  if [ -f /root/.config/hydrodactyl/db-credentials ]; then
    db_root_pass=$(grep '^root:' /root/.config/hydrodactyl/db-credentials 2>/dev/null | cut -d':' -f2)
  fi

  if [ -n "$db_root_pass" ]; then
    # Keep the root password off the command line and the dump private.
    local db_cnf escaped_pass
    db_cnf=$(umask 077 && mktemp)
    escaped_pass=${db_root_pass//\\/\\\\}
    escaped_pass=${escaped_pass//\"/\\\"}
    printf '[client]\nuser=root\npassword="%s"\n' "$escaped_pass" > "$db_cnf"
    ( umask 077 && mysqldump --defaults-extra-file="$db_cnf" --single-transaction \
      --quick --lock-tables=false panel > "${backup_path}.sql" 2>/dev/null ) || {
      warning "Database backup failed (this is non-fatal)"
    }
    rm -f "$db_cnf"
  fi

  # Backup .env file separately to env-backups folder
  debug "Backing up .env file..."
  mkdir -p "${BACKUP_DIR}/env-backups"
  local env_backup="${BACKUP_DIR}/env-backups/env-${timestamp}"
  if [ -f "$INSTALL_DIR/.env" ]; then
    cp "$INSTALL_DIR/.env" "${env_backup}" 2>/dev/null || warning "Failed to backup .env file"
  fi

  # Create restore info
  cat > "${backup_path}.info" << EOF
Backup created: $(date)
Panel version: $(get_current_version)
Backup type: pre-update
EOF

  # Cleanup old backups
  cleanup_old_backups

  success "Backup created: ${backup_name}"
  return 0
}

cleanup_old_backups() {
  debug "Cleaning up old backups (keeping last $KEEP_BACKUPS)"

  # Keep only the most recent env backups
  ls -t ${BACKUP_DIR}/env-backups/env-* 2>/dev/null | \
    tail -n +$((KEEP_BACKUPS + 1)) | \
    xargs -r rm -f 2>/dev/null || true

  # Keep only the most recent backups
  ls -t ${BACKUP_DIR}/panel-backup-*.tar.gz 2>/dev/null | \
    tail -n +$((KEEP_BACKUPS + 1)) | \
    xargs -r rm -f 2>/dev/null || true

  ls -t ${BACKUP_DIR}/panel-backup-*.sql 2>/dev/null | \
    tail -n +$((KEEP_BACKUPS + 1)) | \
    xargs -r rm -f 2>/dev/null || true

  ls -t ${BACKUP_DIR}/panel-backup-*.info 2>/dev/null | \
    tail -n +$((KEEP_BACKUPS + 1)) | \
    xargs -r rm -f 2>/dev/null || true
}

# ------------------ Update Functions ----------------- #

download_release() {
  local version="$1"
  local output_file="$2"

  local download_url="https://github.com/${PANEL_REPO}/releases/download/${version}/panel.tar.gz"
  local curl_opts=("-fsSL" "--max-time" "300")

  if [ -n "$GITHUB_TOKEN" ]; then
    curl_opts+=("-H" "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  debug "Downloading from: $download_url"

  if ! curl "${curl_opts[@]}" -o "$output_file" "$download_url" 2>/dev/null; then
    error "Failed to download release"
    return 1
  fi

  return 0
}

perform_update() {
  local new_version="$1"

  info "Starting update to $new_version..."

  if [ "$DRY_RUN" == true ]; then
    info "DRY RUN: Would update to $new_version"
    return 0
  fi

  # Create backup
  if ! create_backup; then
    error "Backup failed, aborting update"
    return $EXIT_BACKUP_FAILED
  fi

  # Put panel in maintenance mode
  info "Enabling maintenance mode..."
  cd "$INSTALL_DIR"
  php artisan down 2>/dev/null || true

  # Download new version
  local temp_dir
  temp_dir=$(mktemp -d)
  local download_file="${temp_dir}/panel-${new_version}.tar.gz"

  info "Downloading panel $new_version..."
  if ! download_release "$new_version" "$download_file"; then
    error "Download failed"
    php artisan up 2>/dev/null || true
    rm -rf "$temp_dir"
    return $EXIT_NO_RELEASE
  fi

  # Extract update
  info "Extracting update..."
  if ! tar -xzf "$download_file" -C "$temp_dir" 2>/dev/null; then
    error "Extraction failed"
    php artisan up 2>/dev/null || true
    rm -rf "$temp_dir"
    return $EXIT_UPDATE_FAILED
  fi

  # Apply update
  info "Applying update..."
  local extract_dir="${temp_dir}"
  if [ -d "${temp_dir}/panel" ]; then
    extract_dir="${temp_dir}/panel"
  fi

  # Preserve critical files and directories
  info "Preserving existing data..."

  # Backup .env file
  cp "$INSTALL_DIR/.env" "${temp_dir}/.env.backup" 2>/dev/null || true

  # Backup storage directory (contains uploads, logs, sessions)
  if [ -d "$INSTALL_DIR/storage" ]; then
    cp -a "$INSTALL_DIR/storage" "${temp_dir}/storage.backup" 2>/dev/null || true
  fi

  # Copy new files (rsync with excludes, fallback to cp)
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude='.env' --exclude='storage' \
      "$extract_dir/" "$INSTALL_DIR/" 2>/dev/null || {
      error "Failed to copy new files"
      php artisan up 2>/dev/null || true
      rm -rf "$temp_dir"
      return $EXIT_UPDATE_FAILED
    }
  else
    # Fallback: copy then restore preserved items
    cp -r "$extract_dir"/* "$INSTALL_DIR/" 2>/dev/null || {
      error "Failed to copy new files"
      php artisan up 2>/dev/null || true
      rm -rf "$temp_dir"
      return $EXIT_UPDATE_FAILED
    }
  fi

  # Restore .env file
  if [ -f "${temp_dir}/.env.backup" ]; then
    cp "${temp_dir}/.env.backup" "$INSTALL_DIR/.env"
  fi

  # Restore storage directory (atomic rename-then-rename to prevent data loss)
  if [ -d "${temp_dir}/storage.backup" ]; then
    # Copy to temporary location first, then swap atomically
    if cp -a "${temp_dir}/storage.backup" "$INSTALL_DIR/storage.new"; then
      # Atomic swap: rename old to .old, then new to storage
      # mv on same filesystem is atomic (single rename(2) syscall)
      mv "$INSTALL_DIR/storage" "$INSTALL_DIR/storage.old"
      mv "$INSTALL_DIR/storage.new" "$INSTALL_DIR/storage"
      rm -rf "$INSTALL_DIR/storage.old"
    else
      error "Failed to restore storage directory - original preserved"
      php artisan up 2>/dev/null || true
      rm -rf "$temp_dir"
      return $EXIT_UPDATE_FAILED
    fi
  fi

  # Install composer dependencies
  info "Installing composer dependencies..."
  cd "$INSTALL_DIR"
  if ! COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction 2>/dev/null; then
    warning "Composer install may have failed, continuing..."
  fi

  # Build frontend assets
  info "Building frontend assets..."
  if ! pnpm install 2>/dev/null; then
    warning "pnpm install may have failed, continuing..."
  fi
  if ! pnpm build 2>/dev/null; then
    warning "pnpm build may have failed, continuing..."
  fi

  # Set permissions
  info "Setting permissions..."
  chown -R www-data:www-data "$INSTALL_DIR" 2>/dev/null || \
  chown -R nginx:nginx "$INSTALL_DIR" 2>/dev/null || true

  # Ensure storage and bootstrap/cache exist before chmod
  if [ -d "$INSTALL_DIR/storage" ]; then
    find "$INSTALL_DIR/storage" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$INSTALL_DIR/storage" -type f -exec chmod 644 {} \; 2>/dev/null || true
  fi
  if [ -d "$INSTALL_DIR/bootstrap/cache" ]; then
    find "$INSTALL_DIR/bootstrap/cache" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$INSTALL_DIR/bootstrap/cache" -type f -exec chmod 644 {} \; 2>/dev/null || true
  fi

  # Secure .env file
  if [ -f "$INSTALL_DIR/.env" ]; then
    chmod 640 "$INSTALL_DIR/.env" 2>/dev/null || true
    chown www-data:www-data "$INSTALL_DIR/.env" 2>/dev/null || \
    chown nginx:nginx "$INSTALL_DIR/.env" 2>/dev/null || true
  fi

  # Run migrations
  info "Running database migrations..."
  cd "$INSTALL_DIR"
  if ! php artisan migrate --force 2>/dev/null; then
    warning "Migration may have failed, continuing..."
  fi

  # Clear and rebuild caches
  info "Clearing caches..."
  php artisan config:clear 2>/dev/null || true
  php artisan cache:clear 2>/dev/null || true
  php artisan view:clear 2>/dev/null || true

  info "Rebuilding caches..."
  php artisan config:cache 2>/dev/null || true
  php artisan route:cache 2>/dev/null || true
  php artisan view:cache 2>/dev/null || true

  # Disable maintenance mode first
  info "Disabling maintenance mode..."
  php artisan up 2>/dev/null || true

  # Restart queue workers
  info "Restarting queue workers..."
  php artisan queue:restart 2>/dev/null || true

  # Cleanup
  rm -rf "$temp_dir"

  # Run post-update health check with auto-fix
  info "Running post-update health check..."
  if ! post_update_health_check; then
    warning "Health check detected issues, attempting auto-fix..."
    auto_fix_panel_issues

    # Run second health check after auto-fix
    info "Running second health check after auto-fix..."
    if ! post_update_health_check; then
      error "Auto-fix failed to resolve all issues"

      # Log failure information
      mkdir -p "$PANEL_CONFIG_DIR"
      cat > "$PANEL_CONFIG_DIR/update-health-check-failure.log" << EOF
[$(date)] Panel Update Health Check Failed
Version: ${new_version}
Status: Auto-fix applied but issues persist

Failed Checks:
EOF

      # Append specific failed checks to log
      if [ ! -d "$INSTALL_DIR" ]; then
        echo "- Panel directory not found" >> "$PANEL_CONFIG_DIR/update-health-check-failure.log"
      fi

      if [ -d "$INSTALL_DIR/storage" ]; then
        local storage_owner
        storage_owner=$(stat -c '%U' "$INSTALL_DIR/storage" 2>/dev/null)
        if [ "$storage_owner" != "www-data" ] && [ "$storage_owner" != "nginx" ]; then
          echo "- Storage directory has incorrect ownership: $storage_owner" >> "$PANEL_CONFIG_DIR/update-health-check-failure.log"
        fi
      fi

      if [ -d "$INSTALL_DIR/bootstrap/cache" ]; then
        local cache_owner
        cache_owner=$(stat -c '%U' "$INSTALL_DIR/bootstrap/cache" 2>/dev/null)
        if [ "$cache_owner" != "www-data" ] && [ "$cache_owner" != "nginx" ]; then
          echo "- Cache directory has incorrect ownership: $cache_owner" >> "$PANEL_CONFIG_DIR/update-health-check-failure.log"
        fi
      fi

      if ! systemctl is-active --quiet nginx 2>/dev/null; then
        echo "- nginx is not running" >> "$PANEL_CONFIG_DIR/update-health-check-failure.log"
      fi

      local php_fpm_running=false
      for version in 8.4 8.3 8.2 8.1 8.0; do
        if systemctl is-active --quiet "php${version}-fpm" 2>/dev/null; then
          php_fpm_running=true
          break
        fi
      done
      if [ "$php_fpm_running" == false ] && systemctl is-active --quiet php-fpm 2>/dev/null; then
        php_fpm_running=true
      fi
      if [ "$php_fpm_running" == false ]; then
        echo "- PHP-FPM is not running" >> "$PANEL_CONFIG_DIR/update-health-check-failure.log"
      fi

      if ! systemctl is-active --quiet hydroq 2>/dev/null; then
        echo "- Queue worker (hydroq) is not running" >> "$PANEL_CONFIG_DIR/update-health-check-failure.log"
      fi

      echo "" >> "$PANEL_CONFIG_DIR/update-health-check-failure.log"
      echo "Please run the Repair Tool or check manually:" >> "$PANEL_CONFIG_DIR/update-health-check-failure.log"
      echo "bash <(curl -sSL $GITHUB_BASE_URL/$GITHUB_SOURCE/install.sh)" >> "$PANEL_CONFIG_DIR/update-health-check-failure.log"
      echo "And select option [6] Repair / Fix Common Issues" >> "$PANEL_CONFIG_DIR/update-health-check-failure.log"

      error "Update completed but health check failed. See: $PANEL_CONFIG_DIR/update-health-check-failure.log"
      return $EXIT_UPDATE_FAILED
    fi
  fi

  # Save new version to version file
  mkdir -p /etc/hydrodactyl
  echo "$new_version" > /etc/hydrodactyl/panel-version
  chmod 644 /etc/hydrodactyl/panel-version

  # Log update
  echo "[$(date)] Updated to ${new_version}" >> "${BACKUP_DIR}/update-history.log"

  success "Update to $new_version completed successfully!"
  return 0
}

# ------------------ Git-Based Update Functions ----------------- #

perform_update_git() {
  info "Starting git-based update..."

  if [ "$DRY_RUN" == true ]; then
    info "DRY RUN: Would pull latest commits from git"
    return 0
  fi

  # Create backup first
  if ! create_backup; then
    error "Backup failed, aborting update"
    return $EXIT_BACKUP_FAILED
  fi

  # Put panel in maintenance mode
  info "Enabling maintenance mode..."
  cd "$INSTALL_DIR"
  php artisan down 2>/dev/null || true

  # Check if this is a git repo or needs to be converted
  if [ ! -d "${INSTALL_DIR}/.git" ]; then
    info "Converting existing installation to git repository..."

    # Initialize git repo
    cd "$INSTALL_DIR"
    git init

    # Add remote (tokenless URL - auth via http.extraHeader)
    local git_url="https://github.com/${PANEL_REPO}.git"
    git remote add origin "$git_url"

    # Fetch and checkout (use http.extraHeader for private repos)
    local git_fetch_cmd=("git")
    if [ "$PANEL_REPO_PRIVATE" == "true" ] && [ -n "$GITHUB_TOKEN" ]; then
      git_fetch_cmd=("git" "-c" "http.extraHeader=Authorization: Bearer $GITHUB_TOKEN")
    fi
    "${git_fetch_cmd[@]}" fetch origin
    git checkout -f -B main origin/HEAD || git checkout -f -B master origin/HEAD || {
      error "Failed to checkout from git repository"
      php artisan up 2>/dev/null || true
      return $EXIT_UPDATE_FAILED
    }
  else
    # Already a git repo, just pull
    info "Pulling latest changes from git..."
    cd "$INSTALL_DIR"

    # Keep local edits. A failed stash must not continue into reset --hard.
    local stashed=0
    if ! git diff --quiet || ! git diff --cached --quiet; then
      if ! git stash push -m "auto-update-stash-$(date +%Y%m%d-%H%M%S)"; then
        error "Could not save local changes. The update was aborted and the working tree was left unchanged."
        php artisan up 2>/dev/null || true
        return $EXIT_UPDATE_FAILED
      fi
      stashed=1
    fi

    # Fetch and pull
    # Use http.extraHeader for private repos to avoid persisting token in .git/config
    local git_fetch_cmd=("git")
    if [ "$PANEL_REPO_PRIVATE" == "true" ] && [ -n "$GITHUB_TOKEN" ]; then
      git_fetch_cmd=("git" "-c" "http.extraHeader=Authorization: Bearer $GITHUB_TOKEN")
    fi

    if ! "${git_fetch_cmd[@]}" fetch origin; then
      error "Failed to fetch from git repository"
      php artisan up 2>/dev/null || true
      return $EXIT_UPDATE_FAILED
    fi

    # Reset to latest (cleaner than merge for auto-updates)
    local remote_branch
    remote_branch=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "origin/main")
    [ "$remote_branch" == "origin/HEAD" ] && remote_branch="origin/main"

    if ! git reset --hard "$remote_branch"; then
      error "Failed to reset to latest commit"
      if [ "$stashed" = 1 ]; then
        git stash pop || warning "Local changes were stashed but could not be restored automatically."
      fi
      php artisan up 2>/dev/null || true
      return $EXIT_UPDATE_FAILED
    fi
  fi

  # Install composer dependencies
  info "Installing composer dependencies..."
  cd "$INSTALL_DIR"
  if ! COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction 2>/dev/null; then
    warning "Composer install may have failed, continuing..."
  fi

  # Build frontend assets (pnpm only)
  info "Building frontend assets..."
  if ! pnpm install 2>/dev/null; then
    warning "pnpm install may have failed, continuing..."
  fi
  if ! pnpm build 2>/dev/null; then
    warning "pnpm build may have failed, continuing..."
  fi

  # Set permissions
  info "Setting permissions..."
  chown -R www-data:www-data "$INSTALL_DIR" 2>/dev/null || \
  chown -R nginx:nginx "$INSTALL_DIR" 2>/dev/null || true

  # Ensure storage and bootstrap/cache exist before chmod
  if [ -d "$INSTALL_DIR/storage" ]; then
    find "$INSTALL_DIR/storage" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$INSTALL_DIR/storage" -type f -exec chmod 644 {} \; 2>/dev/null || true
  fi
  if [ -d "$INSTALL_DIR/bootstrap/cache" ]; then
    find "$INSTALL_DIR/bootstrap/cache" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$INSTALL_DIR/bootstrap/cache" -type f -exec chmod 644 {} \; 2>/dev/null || true
  fi

  # Secure .env file
  if [ -f "$INSTALL_DIR/.env" ]; then
    chmod 640 "$INSTALL_DIR/.env" 2>/dev/null || true
    chown www-data:www-data "$INSTALL_DIR/.env" 2>/dev/null || \
    chown nginx:nginx "$INSTALL_DIR/.env" 2>/dev/null || true
  fi

  # Run migrations
  info "Running database migrations..."
  cd "$INSTALL_DIR"
  if ! php artisan migrate --force 2>/dev/null; then
    warning "Migration may have failed, continuing..."
  fi

  # Clear and rebuild caches
  info "Clearing caches..."
  php artisan config:clear 2>/dev/null || true
  php artisan cache:clear 2>/dev/null || true
  php artisan view:clear 2>/dev/null || true

  info "Rebuilding caches..."
  php artisan config:cache 2>/dev/null || true
  php artisan route:cache 2>/dev/null || true
  php artisan view:cache 2>/dev/null || true

  # Disable maintenance mode first
  info "Disabling maintenance mode..."
  php artisan up 2>/dev/null || true

  # Restart queue workers after maintenance mode is disabled
  info "Restarting queue workers..."
  php artisan queue:restart 2>/dev/null || true

  # Log update with git commit info
  local new_commit
  new_commit=$(get_local_commit_hash)
  echo "[$(date)] Updated via git to commit ${new_commit:0:8}" >> "${BACKUP_DIR}/update-history.log"

  # Run post-update health check with auto-fix
  info "Running post-update health check..."
  if ! post_update_health_check; then
    warning "Health check detected issues, attempting auto-fix..."
    auto_fix_panel_issues

    # Run second health check after auto-fix
    info "Running second health check after auto-fix..."
    if ! post_update_health_check; then
      error "Auto-fix failed to resolve all issues"

      # Log failure information
      mkdir -p "$PANEL_CONFIG_DIR"
      cat > "$PANEL_CONFIG_DIR/update-health-check-failure.log" << EOF
[$(date)] Panel Update Health Check Failed
Commit: ${new_commit:0:8}
Status: Auto-fix applied but issues persist

Failed Checks:
EOF

      # Append specific failed checks to log
      if [ ! -d "$INSTALL_DIR" ]; then
        echo "- Panel directory not found" >> "$PANEL_CONFIG_DIR/update-health-check-failure.log"
      fi

      if [ -d "$INSTALL_DIR/storage" ]; then
        local storage_owner
        storage_owner=$(stat -c '%U' "$INSTALL_DIR/storage" 2>/dev/null)
        if [ "$storage_owner" != "www-data" ] && [ "$storage_owner" != "nginx" ]; then
          echo "- Storage directory has incorrect ownership: $storage_owner" >> "$PANEL_CONFIG_DIR/update-health-check-failure.log"
        fi
      fi

      if [ -d "$INSTALL_DIR/bootstrap/cache" ]; then
        local cache_owner
        cache_owner=$(stat -c '%U' "$INSTALL_DIR/bootstrap/cache" 2>/dev/null)
        if [ "$cache_owner" != "www-data" ] && [ "$cache_owner" != "nginx" ]; then
          echo "- Cache directory has incorrect ownership: $cache_owner" >> "$PANEL_CONFIG_DIR/update-health-check-failure.log"
        fi
      fi

      if ! systemctl is-active --quiet nginx 2>/dev/null; then
        echo "- nginx is not running" >> "$PANEL_CONFIG_DIR/update-health-check-failure.log"
      fi

      local php_fpm_running=false
      for version in 8.4 8.3 8.2 8.1 8.0; do
        if systemctl is-active --quiet "php${version}-fpm" 2>/dev/null; then
          php_fpm_running=true
          break
        fi
      done
      if [ "$php_fpm_running" == false ] && systemctl is-active --quiet php-fpm 2>/dev/null; then
        php_fpm_running=true
      fi
      if [ "$php_fpm_running" == false ]; then
        echo "- PHP-FPM is not running" >> "$PANEL_CONFIG_DIR/update-health-check-failure.log"
      fi

      if ! systemctl is-active --quiet hydroq 2>/dev/null; then
        echo "- Queue worker (hydroq) is not running" >> "$PANEL_CONFIG_DIR/update-health-check-failure.log"
      fi

      echo "" >> "$PANEL_CONFIG_DIR/update-health-check-failure.log"
      echo "Please run the Repair Tool or check manually:" >> "$PANEL_CONFIG_DIR/update-health-check-failure.log"
      echo "bash <(curl -sSL $GITHUB_BASE_URL/$GITHUB_SOURCE/install.sh)" >> "$PANEL_CONFIG_DIR/update-health-check-failure.log"
      echo "And select option [6] Repair / Fix Common Issues" >> "$PANEL_CONFIG_DIR/update-health-check-failure.log"

      error "Update completed but health check failed. See: $PANEL_CONFIG_DIR/update-health-check-failure.log"
      return $EXIT_UPDATE_FAILED
    fi
  fi

  # Save git commit hash as version
  local new_commit
  new_commit=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
  mkdir -p /etc/hydrodactyl
  echo "git:${new_commit}" > /etc/hydrodactyl/panel-version
  chmod 644 /etc/hydrodactyl/panel-version

  success "Update to latest git commit completed successfully!"
  return 0
}

# ------------------ Post-Update Health Check & Auto-Fix ----------------- #

post_update_health_check() {
  local has_errors=false

  debug "Checking panel directory..."
  if [ ! -d "$INSTALL_DIR" ]; then
    error "Panel directory not found"
    return 1
  fi

  debug "Checking storage permissions..."
  if [ -d "$INSTALL_DIR/storage" ]; then
    local storage_owner
    storage_owner=$(stat -c '%U' "$INSTALL_DIR/storage" 2>/dev/null)
    if [ "$storage_owner" != "www-data" ] && [ "$storage_owner" != "nginx" ]; then
      warning "Storage directory has incorrect ownership: $storage_owner"
      has_errors=true
    fi
  fi

  debug "Checking bootstrap/cache permissions..."
  if [ -d "$INSTALL_DIR/bootstrap/cache" ]; then
    local cache_owner
    cache_owner=$(stat -c '%U' "$INSTALL_DIR/bootstrap/cache" 2>/dev/null)
    if [ "$cache_owner" != "www-data" ] && [ "$cache_owner" != "nginx" ]; then
      warning "Cache directory has incorrect ownership: $cache_owner"
      has_errors=true
    fi
  fi

  debug "Checking nginx status..."
  if ! systemctl is-active --quiet nginx 2>/dev/null; then
    warning "nginx is not running"
    has_errors=true
  fi

  debug "Checking PHP-FPM status..."
  local php_fpm_running=false
  for version in 8.4 8.3 8.2 8.1 8.0; do
    if systemctl is-active --quiet "php${version}-fpm" 2>/dev/null; then
      php_fpm_running=true
      break
    fi
  done
  if [ "$php_fpm_running" == false ] && systemctl is-active --quiet php-fpm 2>/dev/null; then
    php_fpm_running=true
  fi
  if [ "$php_fpm_running" == false ]; then
    warning "PHP-FPM is not running"
    has_errors=true
  fi

  debug "Checking queue worker..."
  if ! systemctl is-active --quiet hydroq 2>/dev/null; then
    warning "Queue worker (hydroq) is not running"
    has_errors=true
  fi

  if [ "$has_errors" == true ]; then
    return 1
  fi

  info "Health check passed"
  return 0
}

auto_fix_panel_issues() {
  info "Attempting to auto-fix issues..."

  # Fix permissions
  info "Fixing file permissions..."
  chown -R www-data:www-data "$INSTALL_DIR" 2>/dev/null || \
  chown -R nginx:nginx "$INSTALL_DIR" 2>/dev/null || true

  # Apply correct permissions: 755 for directories, 644 for files
  if [ -d "$INSTALL_DIR/storage" ]; then
    find "$INSTALL_DIR/storage" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$INSTALL_DIR/storage" -type f -exec chmod 644 {} \; 2>/dev/null || true
  fi
  if [ -d "$INSTALL_DIR/bootstrap/cache" ]; then
    find "$INSTALL_DIR/bootstrap/cache" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$INSTALL_DIR/bootstrap/cache" -type f -exec chmod 644 {} \; 2>/dev/null || true
  fi

  # Clear caches
  info "Clearing Laravel caches..."
  cd "$INSTALL_DIR"
  php artisan config:clear 2>/dev/null || true
  php artisan cache:clear 2>/dev/null || true
  php artisan view:clear 2>/dev/null || true

  # Restart services
  info "Restarting services..."
  systemctl restart nginx 2>/dev/null || true

  for version in 8.4 8.3 8.2 8.1 8.0; do
    if systemctl is-active --quiet "php${version}-fpm" 2>/dev/null; then
      systemctl restart "php${version}-fpm" 2>/dev/null || true
      break
    fi
  done
  systemctl restart php-fpm 2>/dev/null || true

  systemctl restart hydroq 2>/dev/null || true

  # Rebuild caches
  info "Rebuilding caches..."
  php artisan config:cache 2>/dev/null || true
  php artisan route:cache 2>/dev/null || true
  php artisan view:cache 2>/dev/null || true

  success "Auto-fix completed"
}

send_notification() {
  local status="$1"
  local message="$2"

  # TODO: Implement notification methods (email, webhook, etc.)
  # For now, just log
  info "NOTIFICATION [$status]: $message"
}

# ------------------ Main Check Function ----------------- #

check_for_updates() {
  debug "Update method: $UPDATE_METHOD"

  if [ "$UPDATE_METHOD" == "git" ]; then
    check_for_updates_git
  else
    check_for_updates_releases
  fi
}

# ------------------ Argument Parsing ----------------- #

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --cron)
        CRON_MODE=true
        LOG_TO_FILE=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --notify-only)
        NOTIFY_ONLY=true
        shift
        ;;
      --force)
        FORCE_UPDATE=true
        shift
        ;;
      --verbose|-v)
        VERBOSE=true
        shift
        ;;
      --config)
        CONFIG_FILE="$2"
        shift 2
        ;;
      --help|-h)
        show_help
        exit 0
        ;;
      *)
        error "Unknown option: $1"
        show_help
        exit 1
        ;;
    esac
  done
}

show_help() {
  cat << EOF
Hydrodactyl Panel Auto-Updater

Usage: $(basename "$0") [OPTIONS]

Options:
  --cron          Run in cron mode (no colors, log to file)
  --dry-run       Check for updates but don't install
  --notify-only   Only send notification if update is available
  --force         Force update even if versions match
  --verbose, -v   Enable verbose output
  --config FILE   Use alternative config file
  --help, -h      Show this help message

Configuration file: $CONFIG_FILE
Log file: $LOG_FILE
Update method: $UPDATE_METHOD (releases|git)
EOF
}

# ------------------ Main ----------------- #

main() {
  parse_arguments "$@"

  # Setup
  setup_colors
  load_config

  # Ensure directories exist
  mkdir -p "$(dirname "$LOG_FILE")"
  mkdir -p "$BACKUP_DIR"

  # Check if running as root
  if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit $EXIT_ERROR
  fi

  # Check if panel is installed
  if [ ! -d "$INSTALL_DIR" ]; then
    error "Panel not found at $INSTALL_DIR"
    exit $EXIT_ERROR
  fi

  # Acquire lock
  acquire_lock

  info "Starting panel auto-update check"
  info "Mode: $([ "$DRY_RUN" == true ] && echo "DRY RUN" || echo "LIVE")"

  local exit_code
  if check_for_updates; then
    exit_code=$EXIT_SUCCESS
  else
    exit_code=$?
    [ $exit_code -eq 0 ] && exit_code=$EXIT_ERROR
  fi

  # Cleanup
  release_lock

  debug "Exit code: $exit_code"
  exit $exit_code
}

# Handle signals
trap release_lock EXIT INT TERM

main "$@"
