#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Hydrodactyl Elytra Auto-Updater                                                     #
#                                                                                    #
# Advanced auto-updater with cron support, dry-run mode, backups, and notifications  #
#                                                                                    #
# Usage:                                                                             #
#   auto-update-elytra.sh                    # Interactive mode with colors          #
#   auto-update-elytra.sh --cron             # Cron mode (no colors, log to file)    #
#   auto-update-elytra.sh --dry-run          # Check only, don't actually update      #
#   auto-update-elytra.sh --notify-only      # Only send notification if update avail #
#   auto-update-elytra.sh --force            # Force update even if versions match    #
#                                                                                    #
######################################################################################

# ------------------ Configuration ----------------- #

# Load environment file if it exists (for systemd service)
if [ -f /etc/hydrodactyl/auto-update-elytra.env ]; then
  # shellcheck source=/dev/null
  source /etc/hydrodactyl/auto-update-elytra.env
fi

# Default config (can be overridden by /etc/hydrodactyl/auto-update-elytra.env)
ELYTRA_REPO="${ELYTRA_REPO:-pyrohost/elytra}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
# Use ELYTRA_INSTALL_DIR (not INSTALL_DIR) to avoid collision with lib.sh's
# exported INSTALL_DIR (/var/www/hydrodactyl, the panel's dir) - this script
# is spawned via install.sh's get_script() as a child process that inherits
# that export, so a plain INSTALL_DIR here would silently pick up the
# panel's path instead of its own default.
ELYTRA_INSTALL_DIR="${ELYTRA_INSTALL_DIR:-/etc/elytra}"
LOG_FILE="${LOG_FILE:-/var/log/hydrodactyl-elytra-auto-update.log}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/elytra}"
LOCK_FILE="${LOCK_FILE:-/var/run/hydrodactyl-elytra-update.lock}"
CONFIG_FILE="${CONFIG_FILE:-/etc/hydrodactyl/auto-update-elytra.env}"
VERSION_FILE="${VERSION_FILE:-/etc/hydrodactyl/elytra-version}"
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"
AUTO_UPDATE="${AUTO_UPDATE:-true}"
CHECK_INTERVAL="${CHECK_INTERVAL:-3600}"
# Elytra is always updated via releases (distributed as binary)
UPDATE_METHOD="releases"
ELYTRA_REPO_PRIVATE="${ELYTRA_REPO_PRIVATE:-false}"

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
  if [ -x "/usr/local/bin/elytra" ]; then
    local binary_version
    binary_version=$(/usr/local/bin/elytra --version 2>/dev/null)
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
    "https://api.github.com/repos/$ELYTRA_REPO/releases/latest" 2>/dev/null)

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
    "https://api.github.com/repos/$ELYTRA_REPO/releases/tags/$encoded_version" 2>/dev/null
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
  local backup_name="elytra-backup-${timestamp}"
  local backup_path="${BACKUP_DIR}/${backup_name}"

  # Backup binary
  debug "Backing up Elytra binary..."
  if [ -f "/usr/local/bin/elytra" ]; then
    cp "/usr/local/bin/elytra" "${backup_path}.binary" 2>/dev/null || {
      warning "Failed to backup binary"
    }
  fi

  # Backup configuration
  debug "Backing up configuration..."
  if [ -d "$ELYTRA_INSTALL_DIR" ]; then
    tar -czf "${backup_path}.tar.gz" -C "$ELYTRA_INSTALL_DIR" . 2>/dev/null || {
      warning "Failed to backup configuration"
    }
  fi

  # Create restore info
  cat > "${backup_path}.info" << EOF
Backup created: $(date)
Elytra version: $(get_current_version)
Backup type: pre-update
EOF

  # Cleanup old backups
  cleanup_old_backups

  success "Backup created: ${backup_name}"
  return 0
}

cleanup_old_backups() {
  debug "Cleaning up old backups (keeping last $KEEP_BACKUPS)"

  ls -t ${BACKUP_DIR}/elytra-backup-*.tar.gz 2>/dev/null | \
    tail -n +$((KEEP_BACKUPS + 1)) | \
    xargs -r rm -f 2>/dev/null || true

  ls -t ${BACKUP_DIR}/elytra-backup-*.binary 2>/dev/null | \
    tail -n +$((KEEP_BACKUPS + 1)) | \
    xargs -r rm -f 2>/dev/null || true

  ls -t ${BACKUP_DIR}/elytra-backup-*.info 2>/dev/null | \
    tail -n +$((KEEP_BACKUPS + 1)) | \
    xargs -r rm -f 2>/dev/null || true
}

# ------------------ Service Functions ----------------- #

stop_elytra() {
  info "Stopping Elytra service..."
  if systemctl is-active --quiet elytra 2>/dev/null; then
    systemctl stop elytra
    sleep 2
    success "Elytra stopped"
  else
    info "Elytra was not running"
  fi
}

start_elytra() {
  info "Starting Elytra service..."
  systemctl start elytra
  sleep 3

  if systemctl is-active --quiet elytra; then
    success "Elytra started successfully"
    return 0
  else
    error "Elytra failed to start"
    return 1
  fi
}

restart_elytra() {
  info "Restarting Elytra service..."
  systemctl restart elytra
  sleep 3

  if systemctl is-active --quiet elytra; then
    success "Elytra restarted successfully"
    return 0
  else
    error "Elytra failed to restart"
    return 1
  fi
}

# ------------------ Update Functions ----------------- #

get_download_url() {
  local version="$1"

  # Determine architecture
  local arch
  arch=$(uname -m)
  [[ $arch == x86_64 ]] && arch=amd64 || arch=arm64

  local asset_name="elytra_linux_${arch}"

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
  stop_elytra

  # Download new binary
  local temp_file
  temp_file=$(mktemp)

  info "Downloading Elytra $new_version..."
  if ! download_binary "$new_version" "$temp_file"; then
    error "Download failed"
    rm -f "$temp_file"
    start_elytra || true
    return $EXIT_DOWNLOAD_FAILED
  fi

  # Verify binary
  info "Verifying binary..."
  if ! verify_binary "$temp_file"; then
    error "Binary verification failed"
    rm -f "$temp_file"
    start_elytra || true
    return $EXIT_DOWNLOAD_FAILED
  fi

  # Install new binary
  info "Installing new binary..."
  if ! mv "$temp_file" "/usr/local/bin/elytra"; then
    error "Failed to install binary"
    rm -f "$temp_file"
    start_elytra || true
    return $EXIT_UPDATE_FAILED
  fi

  chmod +x /usr/local/bin/elytra

  # Start service
  if ! start_elytra; then
    error "Failed to start Elytra after update"
    error "Attempting rollback..."

    # Attempt rollback
    local latest_backup
    latest_backup=$(ls -t ${BACKUP_DIR}/elytra-backup-*.binary 2>/dev/null | head -1)

    if [ -n "$latest_backup" ]; then
      info "Restoring from backup: $latest_backup"
      cp "$latest_backup" "/usr/local/bin/elytra"
      chmod +x "/usr/local/bin/elytra"
      restart_elytra || true
    fi

    return $EXIT_UPDATE_FAILED
  fi

  # Run post-update health check with auto-fix
  info "Running post-update health check..."
  if ! post_update_health_check; then
    warning "Health check detected issues, attempting auto-fix..."
    auto_fix_elytra_issues

    # Run second health check after auto-fix
    info "Running second health check after auto-fix..."
    if ! post_update_health_check; then
      error "Auto-fix failed to resolve all issues"

      # Log failure information
      mkdir -p "$ELYTRA_INSTALL_DIR"
      cat > "$ELYTRA_INSTALL_DIR/update-health-check-failure.log" << EOF
[$(date)] Elytra Update Health Check Failed
Version: ${new_version}
Status: Auto-fix applied but issues persist

Failed Checks:
EOF

      # Append specific failed checks to log
      if [ ! -f "/usr/local/bin/elytra" ]; then
        echo "- Elytra binary not found" >> "$ELYTRA_INSTALL_DIR/update-health-check-failure.log"
      elif [ ! -x "/usr/local/bin/elytra" ]; then
        echo "- Elytra binary is not executable" >> "$ELYTRA_INSTALL_DIR/update-health-check-failure.log"
      fi

      if [ ! -f "$ELYTRA_INSTALL_DIR/config.yml" ]; then
        echo "- Elytra config file not found" >> "$ELYTRA_INSTALL_DIR/update-health-check-failure.log"
      fi

      for dir in /var/lib/elytra/volumes /var/lib/elytra/archives /var/lib/elytra/backups; do
        if [ ! -d "$dir" ]; then
          echo "- Data directory missing: $dir" >> "$ELYTRA_INSTALL_DIR/update-health-check-failure.log"
        fi
      done

      if ! systemctl is-active --quiet docker 2>/dev/null; then
        echo "- Docker is not running" >> "$ELYTRA_INSTALL_DIR/update-health-check-failure.log"
      fi

      if ! systemctl is-active --quiet elytra 2>/dev/null; then
        echo "- Elytra service is not running" >> "$ELYTRA_INSTALL_DIR/update-health-check-failure.log"
      fi

      echo "" >> "$ELYTRA_INSTALL_DIR/update-health-check-failure.log"
      echo "Please run the Repair Tool or check manually:" >> "$ELYTRA_INSTALL_DIR/update-health-check-failure.log"
      echo "bash <(curl -sSL https://raw.githubusercontent.com/itzzjustmateo/hydro-install/main/install.sh)" >> "$ELYTRA_INSTALL_DIR/update-health-check-failure.log"
      echo "And select option [7] Repair / Fix Common Issues" >> "$ELYTRA_INSTALL_DIR/update-health-check-failure.log"

      error "Update completed but health check failed. See: $ELYTRA_INSTALL_DIR/update-health-check-failure.log"
      
      # Attempt rollback since health check failed
      error "Attempting rollback..."
      local latest_backup
      latest_backup=$(ls -t ${BACKUP_DIR}/elytra-backup-*.binary 2>/dev/null | head -1)
      if [ -n "$latest_backup" ]; then
        info "Restoring from backup: $latest_backup"
        cp "$latest_backup" "/usr/local/bin/elytra"
        chmod +x "/usr/local/bin/elytra"
        restart_elytra || true
      fi
      
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

  debug "Checking Elytra binary..."
  if [ ! -f "/usr/local/bin/elytra" ]; then
    error "Elytra binary not found"
    return 1
  fi

  if [ ! -x "/usr/local/bin/elytra" ]; then
    warning "Elytra binary is not executable"
    has_errors=true
  fi

  debug "Checking Elytra config..."
  if [ ! -f "$ELYTRA_INSTALL_DIR/config.yml" ]; then
    warning "Elytra config file not found"
    has_errors=true
  fi

  debug "Checking data directories..."
  for dir in /var/lib/elytra/volumes /var/lib/elytra/archives /var/lib/elytra/backups; do
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

  debug "Checking Elytra service..."
  if ! systemctl is-active --quiet elytra 2>/dev/null; then
    warning "Elytra service is not running"
    has_errors=true
  fi

  if [ "$has_errors" == true ]; then
    return 1
  fi

  info "Health check passed"
  return 0
}

auto_fix_elytra_issues() {
  info "Attempting to auto-fix issues..."

  # Fix binary permissions
  if [ -f "/usr/local/bin/elytra" ]; then
    info "Fixing binary permissions..."
    chmod +x /usr/local/bin/elytra
  fi

  # Fix data directory permissions
  info "Fixing data directory permissions..."
  mkdir -p /var/lib/elytra/volumes /var/lib/elytra/archives /var/lib/elytra/backups

  chown -R 8888:8888 /var/lib/elytra/volumes 2>/dev/null || true
  chown -R 8888:8888 /var/lib/elytra/archives 2>/dev/null || true
  chown -R 8888:8888 /var/lib/elytra/backups 2>/dev/null || true
  chown -R 8888:8888 /etc/elytra 2>/dev/null || true

  # Fix permissions
  info "Fixing Elytra permissions..."
  
  # Create directories if they don't exist
  mkdir -p /var/lib/elytra/volumes /var/lib/elytra/archives /var/lib/elytra/backups
  
  # Set permissions for containerized game servers
  # Note: 777 is required because game server containers run as arbitrary UIDs
  # and must be able to read/write/execute in these directories
  info "Setting 777 permissions on data directories for container access..."
  # Ensure parent /var/lib/elytra is accessible
  chmod 755 /var/lib/elytra 2>/dev/null || true
  # Ensure the volumes directory itself and all contents have 777
  chmod 777 /var/lib/elytra/volumes 2>/dev/null || true
  chmod -R 777 /var/lib/elytra/volumes/* 2>/dev/null || true
  chmod 777 /var/lib/elytra/archives 2>/dev/null || true
  chmod -R 777 /var/lib/elytra/archives/* 2>/dev/null || true
  chmod 777 /var/lib/elytra/backups 2>/dev/null || true
  chmod -R 777 /var/lib/elytra/backups/* 2>/dev/null || true
  
  # Disable check_permissions_on_boot to prevent Elytra from resetting permissions
  if [ -f "/etc/elytra/config.yml" ]; then
    info "Disabling permission checks in Elytra config..."
    sed -i 's/check_permissions_on_boot: true/check_permissions_on_boot: false/' /etc/elytra/config.yml 2>/dev/null || true
  fi
  
  # Elytra config directory - create if needed and set more restrictive permissions
  mkdir -p /etc/elytra
  find /etc/elytra -type d -exec chmod 755 {} \; 2>/dev/null || true
  # SECURITY: Config contains daemon credentials - restrict to owner-only
  find /etc/elytra -type f -name "config.yml" -exec chmod 600 {} \; 2>/dev/null || true
  find /etc/elytra -type f ! -name "config.yml" -exec chmod 640 {} \; 2>/dev/null || true

  # Restart Elytra service
  info "Restarting Elytra service..."
  systemctl restart elytra 2>/dev/null || true

  # Verify Elytra started
  sleep 3
  if systemctl is-active --quiet elytra 2>/dev/null; then
    success "Elytra is now running"
  else
    warning "Elytra may still have issues - manual intervention may be required"
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
  info "Checking for Elytra updates..."
  debug "Repository: $ELYTRA_REPO"
  debug "Install directory: $ELYTRA_INSTALL_DIR"

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
    send_notification "UPDATE_AVAILABLE" "Elytra update available: $latest_version"
    return $EXIT_SUCCESS
  fi

  if [ "$AUTO_UPDATE" != true ] && [ "$DRY_RUN" != true ]; then
    warning "Auto-update is disabled. Set AUTO_UPDATE=true to enable."
    return $EXIT_SUCCESS
  fi

  # Perform update
  if perform_update "$latest_version"; then
    send_notification "UPDATE_SUCCESS" "Elytra updated to $latest_version"
    return $EXIT_SUCCESS
  else
    send_notification "UPDATE_FAILED" "Failed to update Elytra"
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
Hydrodactyl Elytra Auto-Updater

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

  # Ensure directories exist
  mkdir -p "$(dirname "$LOG_FILE")"
  mkdir -p "$BACKUP_DIR"

  # Check if running as root
  if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    exit $EXIT_ERROR
  fi

  # Check if Elytra is installed
  if [ ! -f "/usr/local/bin/elytra" ]; then
    error "Elytra not found at /usr/local/bin/elytra"
    exit $EXIT_ERROR
  fi

  # Acquire lock
  acquire_lock

  info "Starting Elytra auto-update check"
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
