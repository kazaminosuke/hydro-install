#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Hydrodactyl Wings Auto-Updater                                                     #
#                                                                                    #
# Advanced auto-updater with cron support, dry-run mode, backups, and notifications  #
#                                                                                    #
# Usage:                                                                             #
#   auto-update-wings.sh                    # Interactive mode with colors          #
#   auto-update-wings.sh --cron             # Cron mode (no colors, log to file)    #
#   auto-update-wings.sh --dry-run          # Check only, don't actually update      #
#   auto-update-wings.sh --notify-only      # Only send notification if update avail #
#   auto-update-wings.sh --force            # Force update even if versions match    #
#                                                                                    #
######################################################################################

# ------------------ Configuration ----------------- #

# Load environment file if it exists (for systemd service)
if [ -f /etc/hydrodactyl/auto-update-wings.env ]; then
  # shellcheck source=/dev/null
  source /etc/hydrodactyl/auto-update-wings.env
fi

# Default config (can be overridden by /etc/hydrodactyl/auto-update-wings.env)
WINGS_VARIANT="${WINGS_VARIANT:-go}"
WINGS_REPO="${WINGS_REPO:-pterodactyl/wings}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
# Use WINGS_INSTALL_DIR (not INSTALL_DIR) to avoid collision with lib.sh's
# exported INSTALL_DIR (/var/www/hydrodactyl, the panel's dir) - this script
# is spawned via install.sh's get_script() as a child process that inherits
# that export, so a plain INSTALL_DIR here would silently pick up the
# panel's path. prepare_wings_paths() replaces this with the saved layout.
WINGS_INSTALL_DIR="${WINGS_INSTALL_DIR:-/etc/pterodactyl}"
LOG_FILE="${LOG_FILE:-/var/log/hydrodactyl-wings-auto-update.log}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/wings}"
LOCK_FILE="${LOCK_FILE:-/var/run/hydrodactyl-wings-update.lock}"
CONFIG_FILE="${CONFIG_FILE:-/etc/hydrodactyl/auto-update-wings.env}"
VERSION_FILE="${VERSION_FILE:-/etc/hydrodactyl/wings-version}"
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"
AUTO_UPDATE="${AUTO_UPDATE:-true}"
CHECK_INTERVAL="${CHECK_INTERVAL:-3600}"
# Wings is always updated via releases (distributed as binary)
UPDATE_METHOD="releases"
WINGS_REPO_PRIVATE="${WINGS_REPO_PRIVATE:-false}"

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
EXIT_DOWNLOAD_FAILED=4  # Download failed
EXIT_BACKUP_FAILED=5    # Backup failed
EXIT_UPDATE_FAILED=6    # Update failed

# ------------------ Color Setup ----------------- #

COLOR_GREEN=''
COLOR_YELLOW=''
COLOR_RED=''
COLOR_BLUE=''
COLOR_ORANGE=''
COLOR_NC=''

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
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
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

load_wings_layout_library() {
  if declare -F wings_resolve_for_action >/dev/null 2>&1; then
    return 0
  fi

  local layout_lib=""
  layout_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/lib/wings-layout.sh"
  if [ -n "$layout_lib" ] && [ -f "$layout_lib" ]; then
    # shellcheck source=../lib/wings-layout.sh
    source "$layout_lib"
    return 0
  fi

  local url="https://raw.githubusercontent.com/itzzjustmateo/hydro-install/${GITHUB_SOURCE:-main}/lib/wings-layout.sh"
  local tmp
  tmp=$(mktemp)
  if curl -fsSL -o "$tmp" "$url"; then
    # shellcheck source=/dev/null
    source "$tmp"
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# Refuse to update a missing install or a binary shared with Pelican.
prepare_wings_paths() {
  if ! load_wings_layout_library; then
    error "Could not load the Wings layout library"
    return 1
  fi
  if ! wings_resolve_for_action update; then
    error "Hydrodactyl Wings is not installed, or it cannot be updated without touching another Wings install"
    return 1
  fi
  if ! wings_may_modify_path "$WINGS_BINARY"; then
    error "Refusing to replace ${WINGS_BINARY} because another Wings install uses it"
    return 1
  fi
  if ! wings_may_stop_service "$WINGS_SERVICE"; then
    error "Refusing to stop ${WINGS_SERVICE}"
    return 1
  fi
  WINGS_INSTALL_DIR="$WINGS_CONFIG_DIR"
  export WINGS_INSTALL_DIR WINGS_BINARY WINGS_DATA_DIR WINGS_SERVICE WINGS_CONFIG_FILE
}

# ------------------ Version Functions ----------------- #

get_current_version() {
  # First check version file
  if [ -f "$VERSION_FILE" ]; then
    local version
    version=$(cat "$VERSION_FILE" 2>/dev/null)
    if [ -n "$version" ]; then
      echo "$version"
      return 0
    fi
    # File exists but is empty, continue to fallback
  fi

  # Fall back to binary --version (for backwards compatibility)
  if [ -x "${WINGS_BINARY}" ]; then
    local binary_version
    binary_version=$("${WINGS_BINARY}" --version 2>/dev/null)
    if [ -n "$binary_version" ] && [ "$binary_version" != "unknown" ]; then
      echo "$binary_version"
      return 0
    fi
  fi

  echo "unknown"
}

save_current_version() {
  local version="$1"
  echo "$version" > "$VERSION_FILE"
  chmod 644 "$VERSION_FILE"
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
    "https://api.github.com/repos/$WINGS_REPO/releases/latest" 2>/dev/null)

  if [ -z "$release_json" ] || echo "$release_json" | grep -q '"message":"Not Found"'; then
    return 1
  fi

  echo "$release_json" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'
}

get_release_asset_info() {
  local version="$1"
  local curl_opts=("-sL" "--max-time" "30")

  if [ -n "$GITHUB_TOKEN" ]; then
    curl_opts+=("-H" "Authorization: Bearer $GITHUB_TOKEN")
  fi

  # URL-encode version for API path
  local encoded_version
  encoded_version=$(printf '%s' "$version" | jq -sRr @uri 2>/dev/null || echo "$version")

  curl "${curl_opts[@]}" \
    "https://api.github.com/repos/$WINGS_REPO/releases/tags/$encoded_version" 2>/dev/null
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
  local backup_name="wings-backup-${timestamp}"
  local backup_path="${BACKUP_DIR}/${backup_name}"

  # Backup binary
  debug "Backing up Wings binary..."
  if [ -f "${WINGS_BINARY}" ]; then
    cp "${WINGS_BINARY}" "${backup_path}.binary" 2>/dev/null || {
      warning "Failed to backup binary"
    }
  fi

  # Backup configuration
  debug "Backing up configuration..."
  if [ -d "$WINGS_INSTALL_DIR" ]; then
    tar -czf "${backup_path}.tar.gz" -C "$WINGS_INSTALL_DIR" . 2>/dev/null || {
      warning "Failed to backup configuration"
    }
  fi

  # Create restore info
  cat > "${backup_path}.info" << EOF
Backup created: $(date)
Wings version: $(get_current_version)
Backup type: pre-update
EOF

  # Cleanup old backups
  cleanup_old_backups

  success "Backup created: ${backup_name}"
  return 0
}

cleanup_old_backups() {
  debug "Cleaning up old backups (keeping last $KEEP_BACKUPS)"

  ls -t ${BACKUP_DIR}/wings-backup-*.tar.gz 2>/dev/null | \
    tail -n +$((KEEP_BACKUPS + 1)) | \
    xargs -r rm -f 2>/dev/null || true

  ls -t ${BACKUP_DIR}/wings-backup-*.binary 2>/dev/null | \
    tail -n +$((KEEP_BACKUPS + 1)) | \
    xargs -r rm -f 2>/dev/null || true

  ls -t ${BACKUP_DIR}/wings-backup-*.info 2>/dev/null | \
    tail -n +$((KEEP_BACKUPS + 1)) | \
    xargs -r rm -f 2>/dev/null || true
}

# ------------------ Service Functions ----------------- #

stop_wings() {
  info "Stopping Wings service..."
  # Always issue the stop, even if systemctl doesn't currently report the
  # unit as active - wings.service has Restart=on-failure (configs/wings.service),
  # so a crash-looping daemon can sit in a transient "activating"/"deactivating"
  # state between restart attempts that `is-active --quiet` treats as "not
  # active", which previously made this function skip the stop entirely and
  # left the binary in use. `systemctl stop` is safe/idempotent to call even
  # when the unit is already stopped.
  if ! wings_may_stop_service "${WINGS_SERVICE}"; then
    error "Refusing to stop ${WINGS_SERVICE}"
    return 1
  fi
  wings_systemctl stop "${WINGS_SERVICE}" 2>/dev/null || true
  sleep 2

  if systemctl is-active --quiet "${WINGS_SERVICE}" 2>/dev/null; then
    warning "Wings did not stop cleanly - it may still be holding its binary open"
  else
    success "Wings stopped"
  fi
}

start_wings() {
  info "Starting Wings service..."
  wings_systemctl start "${WINGS_SERVICE}"
  sleep 3

  if systemctl is-active --quiet "${WINGS_SERVICE}"; then
    success "Wings started successfully"
    return 0
  else
    error "Wings failed to start"
    return 1
  fi
}

restart_wings() {
  info "Restarting Wings service..."
  wings_systemctl restart "${WINGS_SERVICE}"
  sleep 3

  if systemctl is-active --quiet "${WINGS_SERVICE}"; then
    success "Wings restarted successfully"
    return 0
  else
    error "Wings failed to restart"
    return 1
  fi
}

# Restore the Wings binary from the most recent backup. Stops the service
# first (and waits for confirmation) so the binary isn't "Text file busy"
# while a running - or systemd Restart=on-failure retrying - wings process
# still has it open, then restores via a temp-file + atomic mv, mirroring
# the same safe-replace pattern the primary update path already uses for
# installing the new binary, instead of overwriting the target in place
# with cp.
# Usage: restore_wings_backup
# Returns: 0 if a backup was restored (regardless of whether wings restarts
# cleanly afterward), 1 if no backup was found.
restore_wings_backup() {
  local latest_backup
  latest_backup=$(ls -t ${BACKUP_DIR}/wings-backup-*.binary 2>/dev/null | head -1)

  if [ -z "$latest_backup" ]; then
    warning "No backup found to restore"
    return 1
  fi

  info "Restoring from backup: $latest_backup"

  stop_wings

  local restore_temp
  restore_temp=$(mktemp)
  cp "$latest_backup" "$restore_temp"
  chmod +x "$restore_temp"
  mv "$restore_temp" "${WINGS_BINARY}"

  restart_wings || true
  return 0
}

# ------------------ Update Functions ----------------- #

get_download_url() {
  local version="$1"

  # Determine architecture and asset name based on the installed Wings variant.
  # This script is self-contained (no lib.sh dependency), so the
  # architecture mapping is inlined rather than shared via a lib.sh helper.
  # WINGS_VARIANT is already normalized/validated in main() before this runs.
  local machine
  machine=$(uname -m)

  local arch
  case "$machine" in
    x86_64)
      [ "$WINGS_VARIANT" == "rs" ] && arch="x86_64" || arch="amd64"
      ;;
    aarch64 | arm64)
      [ "$WINGS_VARIANT" == "rs" ] && arch="aarch64" || arch="arm64"
      ;;
    *)
      error "Unsupported architecture: $machine (Wings only supports x86_64 and aarch64/arm64)"
      exit 1
      ;;
  esac

  local asset_name
  if [ "$WINGS_VARIANT" == "rs" ]; then
    asset_name="wings-rs-${arch}-linux"
  else
    asset_name="wings_linux_${arch}"
  fi

  # Get asset download URL from GitHub API
  local release_info
  release_info=$(get_release_asset_info "$version")

  if [ -z "$release_info" ]; then
    return 1
  fi

  # Extract asset URL
  local asset_url
  asset_url=$(echo "$release_info" | jq -r ".assets[] | select(.name == \"$asset_name\") | .url" 2>/dev/null)

  if [ -z "$asset_url" ] || [ "$asset_url" == "null" ]; then
    error "Could not find asset '$asset_name' in release $version"
    return 1
  fi

  echo "$asset_url"
}

download_binary() {
  local version="$1"
  local output_file="$2"

  local asset_url
  asset_url=$(get_download_url "$version")

  if [ -z "$asset_url" ]; then
    return 1
  fi

  local curl_opts=("-fsSL" "--max-time" "300")
  curl_opts+=("-H" "Accept: application/octet-stream")

  if [ -n "$GITHUB_TOKEN" ]; then
    curl_opts+=("-H" "Authorization: Bearer $GITHUB_TOKEN")
    curl_opts+=("-H" "X-GitHub-Api-Version: 2022-11-28")
  fi

  debug "Downloading from: $asset_url"

  if ! curl "${curl_opts[@]}" -o "$output_file" "$asset_url" 2>/dev/null; then
    error "Failed to download binary"
    return 1
  fi

  return 0
}

verify_binary() {
  local binary_path="$1"

  # Check if binary exists and is non-empty
  if [ ! -s "$binary_path" ]; then
    error "Binary file is empty or does not exist"
    return 1
  fi

  # Check if binary is executable and can show help
  if ! chmod +x "$binary_path" 2>/dev/null; then
    error "Cannot make binary executable"
    return 1
  fi

  # Try --help first, then --version, then just check if it runs
  if "$binary_path" --help >/dev/null 2>&1; then
    return 0
  elif "$binary_path" --version >/dev/null 2>&1; then
    return 0
  elif "$binary_path" -h >/dev/null 2>&1; then
    return 0
  else
    # Last resort: check if it's a valid ELF binary
    if file "$binary_path" 2>/dev/null | grep -q "ELF"; then
      return 0
    fi
    error "Binary does not appear to be valid"
    return 1
  fi
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

  # Stop service
  stop_wings

  # Download new binary
  local temp_file
  temp_file=$(mktemp)

  info "Downloading Wings $new_version..."
  if ! download_binary "$new_version" "$temp_file"; then
    error "Download failed"
    rm -f "$temp_file"
    start_wings || true
    return $EXIT_DOWNLOAD_FAILED
  fi

  # Verify binary
  info "Verifying binary..."
  if ! verify_binary "$temp_file"; then
    error "Binary verification failed"
    rm -f "$temp_file"
    start_wings || true
    return $EXIT_DOWNLOAD_FAILED
  fi

  # Install new binary
  info "Installing new binary..."
  if ! mv "$temp_file" "${WINGS_BINARY}"; then
    error "Failed to install binary"
    rm -f "$temp_file"
    start_wings || true
    return $EXIT_UPDATE_FAILED
  fi

  chmod +x "${WINGS_BINARY}"

  # Start service
  if ! start_wings; then
    error "Failed to start Wings after update"
    error "Attempting rollback..."
    restore_wings_backup

    return $EXIT_UPDATE_FAILED
  fi

  # Run post-update health check with auto-fix
  info "Running post-update health check..."
  if ! post_update_health_check; then
    warning "Health check detected issues, attempting auto-fix..."
    auto_fix_wings_issues

    # Run second health check after auto-fix
    info "Running second health check after auto-fix..."
    if ! post_update_health_check; then
      error "Auto-fix failed to resolve all issues"

      # Log failure information
      mkdir -p "$WINGS_INSTALL_DIR"
      cat > "$WINGS_INSTALL_DIR/update-health-check-failure.log" << EOF
[$(date)] Wings Update Health Check Failed
Version: ${new_version}
Status: Auto-fix applied but issues persist

Failed Checks:
EOF

      # Append specific failed checks to log
      if [ ! -f "${WINGS_BINARY}" ]; then
        echo "- Wings binary not found" >> "$WINGS_INSTALL_DIR/update-health-check-failure.log"
      elif [ ! -x "${WINGS_BINARY}" ]; then
        echo "- Wings binary is not executable" >> "$WINGS_INSTALL_DIR/update-health-check-failure.log"
      fi

      if [ ! -f "$WINGS_INSTALL_DIR/config.yml" ]; then
        echo "- Wings config file not found" >> "$WINGS_INSTALL_DIR/update-health-check-failure.log"
      fi

      for dir in "${WINGS_DATA_DIR}/volumes" "${WINGS_DATA_DIR}/archives" "${WINGS_DATA_DIR}/backups"; do
        if [ ! -d "$dir" ]; then
          echo "- Data directory missing: $dir" >> "$WINGS_INSTALL_DIR/update-health-check-failure.log"
        fi
      done

      if ! systemctl is-active --quiet docker 2>/dev/null; then
        echo "- Docker is not running" >> "$WINGS_INSTALL_DIR/update-health-check-failure.log"
      fi

      if ! systemctl is-active --quiet "${WINGS_SERVICE}" 2>/dev/null; then
        echo "- Wings service is not running" >> "$WINGS_INSTALL_DIR/update-health-check-failure.log"
      fi

      echo "" >> "$WINGS_INSTALL_DIR/update-health-check-failure.log"
      echo "Please run the Repair Tool or check manually:" >> "$WINGS_INSTALL_DIR/update-health-check-failure.log"
      echo "bash <(curl -sSL https://raw.githubusercontent.com/itzzjustmateo/hydro-install/main/install.sh)" >> "$WINGS_INSTALL_DIR/update-health-check-failure.log"
      echo "And select option [7] Repair / Fix Common Issues" >> "$WINGS_INSTALL_DIR/update-health-check-failure.log"

      error "Update completed but health check failed. See: $WINGS_INSTALL_DIR/update-health-check-failure.log"
      
      # Attempt rollback since health check failed
      error "Attempting rollback..."
      restore_wings_backup

      return $EXIT_UPDATE_FAILED
    fi
  fi

  # Save current version only after successful health check
  save_current_version "$new_version"

  # Log update
  echo "[$(date)] Updated to ${new_version}" >> "${BACKUP_DIR}/update-history.log"

  success "Update to $new_version completed successfully!"
  return 0
}

# ------------------ Post-Update Health Check & Auto-Fix ----------------- #

post_update_health_check() {
  local has_errors=false

  debug "Checking Wings binary..."
  if [ ! -f "${WINGS_BINARY}" ]; then
    error "Wings binary not found"
    return 1
  fi

  if [ ! -x "${WINGS_BINARY}" ]; then
    warning "Wings binary is not executable"
    has_errors=true
  fi

  debug "Checking Wings config..."
  if [ ! -f "$WINGS_INSTALL_DIR/config.yml" ]; then
    warning "Wings config file not found"
    has_errors=true
  fi

  debug "Checking data directories..."
  for dir in "${WINGS_DATA_DIR}/volumes" "${WINGS_DATA_DIR}/archives" "${WINGS_DATA_DIR}/backups"; do
    if [ ! -d "$dir" ]; then
      warning "Data directory missing: $dir"
      has_errors=true
    fi
  done

  debug "Checking Docker status..."
  if ! systemctl is-active --quiet docker 2>/dev/null; then
    warning "Docker is not running"
    has_errors=true
  fi

  debug "Checking Wings service..."
  if ! systemctl is-active --quiet "${WINGS_SERVICE}" 2>/dev/null; then
    warning "Wings service is not running"
    has_errors=true
  fi

  if [ "$has_errors" == true ]; then
    return 1
  fi

  info "Health check passed"
  return 0
}

auto_fix_wings_issues() {
  # This is a standalone copy of lib.sh's _auto_fix_daemon_issues() (as
  # instantiated by lib.sh's own auto_fix_wings_issues()). This file can't
  # source lib.sh (invoked via `bash <(curl ...)`, isolated subshell), so it
  # can't call the shared helper directly - lib.sh's version is canonical;
  # keep both in sync when fixing bugs or changing behavior here.
  info "Attempting to auto-fix Wings issues..."
  local wings_uid
  wings_uid=$(wings_runtime_uid)

  # Fix binary permissions
  if [ -f "${WINGS_BINARY}" ] && wings_may_modify_path "${WINGS_BINARY}"; then
    info "Fixing binary permissions..."
    chmod +x "${WINGS_BINARY}"
  fi

  # Fix data directory permissions
  info "Fixing data directory permissions..."
  mkdir -p "${WINGS_DATA_DIR}/volumes" "${WINGS_DATA_DIR}/archives" "${WINGS_DATA_DIR}/backups"

  chown -R "${wings_uid}:${wings_uid}" ""${WINGS_DATA_DIR}/volumes"" 2>/dev/null || true
  chown -R "${wings_uid}:${wings_uid}" ""${WINGS_DATA_DIR}/archives"" 2>/dev/null || true
  chown -R "${wings_uid}:${wings_uid}" ""${WINGS_DATA_DIR}/backups"" 2>/dev/null || true
  chown -R "${wings_uid}:${wings_uid}" "$WINGS_INSTALL_DIR" 2>/dev/null || true

  # Fix permissions
  info "Fixing Wings permissions..."

  # Create directories if they don't exist
  mkdir -p "${WINGS_DATA_DIR}/volumes" "${WINGS_DATA_DIR}/archives" "${WINGS_DATA_DIR}/backups"

  # Set permissions for containerized game servers
  # Note: 777 is required because game server containers run as arbitrary UIDs
  # and must be able to read/write/execute in these directories
  info "Setting 777 permissions on data directories for container access..."
  # Ensure parent ${WINGS_DATA_DIR} is accessible
  chmod 755 "${WINGS_DATA_DIR}" 2>/dev/null || true
  # Ensure the volumes directory itself and all contents have 777
  chmod 777 "${WINGS_DATA_DIR}/volumes" 2>/dev/null || true
  chmod -R 777 "${WINGS_DATA_DIR}/volumes/"* 2>/dev/null || true
  chmod 777 "${WINGS_DATA_DIR}/archives" 2>/dev/null || true
  chmod -R 777 "${WINGS_DATA_DIR}/archives/"* 2>/dev/null || true
  chmod 777 "${WINGS_DATA_DIR}/backups" 2>/dev/null || true
  chmod -R 777 "${WINGS_DATA_DIR}/backups/"* 2>/dev/null || true

  # Set ACL default permissions so new directories inherit 777 - matches the
  # explicit chmod 777 above, since containers run as arbitrary UIDs and
  # need read/write/execute on files other containers create later too.
  if command -v setfacl >/dev/null 2>&1; then
    info "Setting default ACL permissions for new files..."
    setfacl -R -m d:o:rwx,d:g:rwx "${WINGS_DATA_DIR}/volumes" "${WINGS_DATA_DIR}/archives" "${WINGS_DATA_DIR}/backups" 2>/dev/null || true
  fi

  # Disable check_permissions_on_boot in Wings config to prevent permission resets
  if [ -f "$WINGS_INSTALL_DIR/config.yml" ]; then
    info "Disabling permission checks in Wings config..."
    sed -i 's/check_permissions_on_boot: true/check_permissions_on_boot: false/' "$WINGS_INSTALL_DIR/config.yml" 2>/dev/null || true
  fi

  # Wings config directory - create if needed and set more restrictive permissions
  mkdir -p "$WINGS_INSTALL_DIR"
  find "$WINGS_INSTALL_DIR" -type d -exec chmod 755 {} \; 2>/dev/null || true
  # SECURITY: Config contains daemon credentials - restrict to owner-only
  find "$WINGS_INSTALL_DIR" -type f -name "config.yml" -exec chmod 600 {} \; 2>/dev/null || true
  find "$WINGS_INSTALL_DIR" -type f ! -name "config.yml" -exec chmod 640 {} \; 2>/dev/null || true

  # Restart Wings service
  info "Restarting Wings service..."
  wings_systemctl restart "${WINGS_SERVICE}" 2>/dev/null || true

  # Verify Wings started
  sleep 3
  if systemctl is-active --quiet "${WINGS_SERVICE}" 2>/dev/null; then
    success "Wings is now running"
  else
    warning "Wings may still have issues - manual intervention may be required"
  fi

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
  info "Checking for Wings updates..."
  debug "Repository: $WINGS_REPO"
  debug "Install directory: $WINGS_INSTALL_DIR"

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
    send_notification "UPDATE_AVAILABLE" "Wings update available: $latest_version"
    return $EXIT_SUCCESS
  fi

  if [ "$AUTO_UPDATE" != true ] && [ "$DRY_RUN" != true ]; then
    warning "Auto-update is disabled. Set AUTO_UPDATE=true to enable."
    return $EXIT_SUCCESS
  fi

  # Perform update
  if perform_update "$latest_version"; then
    send_notification "UPDATE_SUCCESS" "Wings updated to $latest_version"
    return $EXIT_SUCCESS
  else
    send_notification "UPDATE_FAILED" "Failed to update Wings"
    return $EXIT_UPDATE_FAILED
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
Hydrodactyl Wings Auto-Updater

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
EOF
}

# ------------------ Main ----------------- #

main() {
  parse_arguments "$@"

  # Setup
  setup_colors
  load_config

  # Normalize and validate here, right after load_config() (which may
  # re-source CONFIG_FILE and override the top-level default) and before
  # acquire_lock/create_backup run - a typo left in the env file would
  # otherwise waste a backup before get_download_url() caught it.
  WINGS_VARIANT=$(echo "$WINGS_VARIANT" | tr '[:upper:]' '[:lower:]')
  case "$WINGS_VARIANT" in
    go | rs) ;;
    *)
      error "Unsupported Wings variant: $WINGS_VARIANT (expected 'go' or 'rs')"
      exit $EXIT_ERROR
      ;;
  esac

  # Ensure directories exist
  mkdir -p "$(dirname "$LOG_FILE")"
  mkdir -p "$BACKUP_DIR"

  # Check if running as root
  if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit $EXIT_ERROR
  fi

  if ! prepare_wings_paths; then
    exit $EXIT_ERROR
  fi

  # Check if Wings is installed
  if [ ! -f "${WINGS_BINARY}" ]; then
    error "Wings not found at ${WINGS_BINARY}"
    exit $EXIT_ERROR
  fi

  # Acquire lock
  acquire_lock

  info "Starting Wings auto-update check"
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

# Handle signals only when this file is executed. Sourcing it for tests must
# not run an update or install a trap in the caller's shell.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  trap release_lock EXIT INT TERM
  main "$@"
fi
