#!/bin/bash

# Clean up any cached files from previous runs
rm -f /tmp/hydrodactyl-lib.sh /tmp/hydrodactyl-*.sh 2>/dev/null || true

set -e

# ------------------ Command Line Arguments ----------------- #

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --help|-h)
      echo "Hydrodactyl Installer"
      echo ""
      echo "Usage: install.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --help, -h    Show this help message"
      echo ""
      echo "Examples:"
      echo "  # Standard install (downloads from GitHub)"
      echo "  bash <(curl -sSL https://raw.githubusercontent.com/itzzjustmateo/hydro-install/main/install.sh)"
      echo ""
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

######################################################################################
#                                                                                    #
# Hydrodactyl Installer                                                               #
#                                                                                    #
# One-command installer for Hydrodactyl Panel and Wings Daemon                        #
#                                                                                    #
# Copyright (C) 2026, ItzzMateo Studios                                             #
#                                                                                    #
# https://github.com/itzzjustmateo/hydro-install                         #
#                                                                                    #
######################################################################################

export GITHUB_SOURCE="${GITHUB_SOURCE:-main}"
export SCRIPT_RELEASE="${SCRIPT_RELEASE:-v1.0.0}"
export GITHUB_BASE_URL="${GITHUB_BASE_URL:-https://raw.githubusercontent.com/itzzjustmateo/hydro-install}"

LOG_PATH="/var/log/hydrodactyl-installer.log"

# ------------------ Utility Functions ----------------- #

# Color definitions - Orange gradient for flame effect
export COLOR_DARK_ORANGE='\033[38;5;208m'
export COLOR_ORANGE='\033[38;5;214m'
export COLOR_LIGHT_ORANGE='\033[38;5;220m'
export COLOR_YELLOW='\033[1;33m'
export COLOR_GREEN='\033[0;32m'
export COLOR_RED='\033[0;31m'
export COLOR_BLUE='\033[0;34m'
export COLOR_CYAN='\033[0;36m'
export COLOR_NC='\033[0m'

# Smooth flame gradient colors (top to bottom) - red to gold
export GRADIENT_1='\033[38;5;196m'   # Deep red
export GRADIENT_2='\033[38;5;202m'   # Red-orange
export GRADIENT_3='\033[38;5;208m'   # Dark orange
export GRADIENT_4='\033[38;5;214m'   # Orange
export GRADIENT_5='\033[38;5;220m'   # Light orange
export GRADIENT_6='\033[38;5;221m'   # Gold-orange
export GRADIENT_7='\033[38;5;222m'   # Gold
export GRADIENT_8='\033[38;5;226m'   # Yellow-gold
export GRADIENT_9='\033[38;5;227m'   # Bright gold
export GRADIENT_10='\033[38;5;228m'  # Light gold
export GRADIENT_11='\033[38;5;229m'  # Pale gold

output() {
  echo -e "* $1"
}

success() {
  echo ""
  echo -e "* ${COLOR_GREEN}SUCCESS${COLOR_NC}: $1"
  echo ""
}

error() {
  echo ""
  echo -e "* ${COLOR_RED}ERROR${COLOR_NC}: $1" 1>&2
  echo ""
}

warning() {
  echo ""
  echo -e "* ${COLOR_YELLOW}WARNING${COLOR_NC}: $1"
  echo ""
}

# Error handler - called when script exits with error
error_handler() {
  local exit_code=$?
  local line_no=$1

  if [ $exit_code -ne 0 ]; then
    echo ""
    echo -e "* ${COLOR_RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_NC}"
    echo -e "* ${COLOR_RED}INSTALLATION FAILED${COLOR_NC}"
    echo -e "* ${COLOR_RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_NC}"
    echo ""
    echo -e "* ${COLOR_YELLOW}Exit code:${COLOR_NC} $exit_code"
    [ -n "$line_no" ] && echo -e "* ${COLOR_YELLOW}Failed at line:${COLOR_NC} $line_no"
    echo ""
    echo -e "* ${COLOR_CYAN}Troubleshooting tips:${COLOR_NC}"
    echo -e "  1. Check the log file: ${COLOR_ORANGE}$LOG_PATH${COLOR_NC}"
    echo -e "  2. Ensure you have a stable internet connection"
    echo -e "  3. Verify your GitHub token has 'repo' scope"
    echo -e "  4. Check that your OS is supported"
    echo ""
    echo -e "* ${COLOR_CYAN}For help, visit:${COLOR_NC} https://github.com/itzzjustmateo/hydro-install/issues"
    echo ""
    echo -e "* ${COLOR_RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_NC}"
    echo ""
  fi
}

# Set up error trap
trap 'error_handler $LINENO' ERR

# Cleanup function for temporary files
print_brake() {
  local char="${2:-─}"
  for ((n = 0; n < $1; n++)); do
    echo -n "$char"
  done
  echo ""
}

print_header() {
  clear 2>/dev/null || true
  echo ""

  echo -e "${COLOR_ORANGE}Hydrodactyl Installation Manager${COLOR_NC}  ${COLOR_ORANGE}|${COLOR_NC}  ${COLOR_ORANGE}Version:${COLOR_NC} ${SCRIPT_RELEASE}  ${COLOR_ORANGE}|${COLOR_NC}  ${COLOR_ORANGE}By:${COLOR_NC} ItzzMateo Studios"
  echo ""
}

print_flame() {
  local message="$1"

  echo ""
  echo -e "${COLOR_ORANGE}  $message${COLOR_NC}"
  echo ""
}

# Cleanup function for temporary files
cleanup() {
  rm -f /tmp/hydrodactyl-lib.sh 2>/dev/null || true
  rm -f /tmp/lib.sh 2>/dev/null || true
}

# Set trap to cleanup on exit
trap cleanup EXIT INT TERM

# Check for root
check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "This script must be executed with root privileges."
    exit 1
  fi
}

# Check for curl
check_curl() {
  if ! [ -x "$(command -v curl)" ]; then
    error "curl is required in order for this script to work."
    error "Install using: apt install curl (Debian/Ubuntu) or dnf install curl (RHEL)"
    exit 1
  fi
}

# Download and source library
load_library() {
  # Download lib.sh from GitHub
  [ -f /tmp/hydrodactyl-lib.sh ] && rm -rf /tmp/hydrodactyl-lib.sh

  output "Loading installer library..."

  if ! curl -sSL -o /tmp/hydrodactyl-lib.sh "$GITHUB_BASE_URL/$GITHUB_SOURCE/lib/lib.sh"; then
    error "Failed to download installer library."
    error "Please check your internet connection and try again."
    exit 1
  fi

  # shellcheck source=/dev/null
  if ! source /tmp/hydrodactyl-lib.sh; then
    error "Failed to load installer library."
    exit 1
  fi
}

# Log execution
log_execution() {
  echo -e "\n\n* hydrodactyl-installer $(date) \n\n" >> "$LOG_PATH" 2>/dev/null || true
}

# Execute UI script
execute_ui() {
  local script_name="$1"
  local next_script="${2:-}"

  # Download and run from GitHub
  run_ui "$script_name" 2>&1 | tee -a "$LOG_PATH"
  local exit_code=${PIPESTATUS[0]}

  # Exit if the installation failed
  if [ $exit_code -ne 0 ]; then
    exit $exit_code
  fi

  # Wait for user to acknowledge before returning to menu
  # (unless there's a next script to run)
  if [[ -z "$next_script" ]]; then
    echo ""
    output "Press Enter to return to the menu..."
    read -r
  fi

  if [[ -n "$next_script" ]]; then
    echo ""
    local CONFIRM=""
    while [[ "$CONFIRM" != "y" && "$CONFIRM" != "n" ]]; do
      echo -n "* Installation of $script_name completed. Do you want to proceed to $next_script installation? [y/N]: "
      read -r CONFIRM
      CONFIRM=$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')
      [ -z "$CONFIRM" ] && CONFIRM="n"
      if [[ "$CONFIRM" != "y" && "$CONFIRM" != "n" ]]; then
        error "Invalid input. Please enter 'y' or 'n'."
      fi
    done
    if [[ "$CONFIRM" == "y" ]]; then
      execute_ui "$next_script"
    else
      warning "Installation of $next_script aborted."
      exit 1
    fi
  fi
}

# Show welcome screen
# Check installations and set state variables
check_installations() {
  PANEL_INSTALLED=false
  WINGS_INSTALLED=false
  PANEL_VERSION=""
  WINGS_VERSION=""
  WINGS_VARIANT=""

  # Check for Hydrodactyl
  if [ -d "/var/www/hydrodactyl" ]; then
    PANEL_INSTALLED=true
    if [ -f "/var/www/hydrodactyl/config/app.php" ]; then
      PANEL_VERSION=$(grep "'version'" "/var/www/hydrodactyl/config/app.php" 2>/dev/null | head -1 | cut -d"'" -f4 || echo "")
    fi
  fi

  # Check for Wings
  if detect_wings_binary >/dev/null 2>&1; then
    WINGS_INSTALLED=true
    if [ -f "/etc/hydrodactyl/wings-version" ]; then
      WINGS_VERSION=$(cat "/etc/hydrodactyl/wings-version" 2>/dev/null || echo "")
    fi
    # auto-update-wings.env tracks the installed variant (go/rs) and is the
    # more reliable of the two info sources here: install.sh itself
    # self-heals it (see run_wings_update()) whenever it's missing, while
    # install-info/wings-info has no such fallback for older installs.
    # Grep the single field instead of sourcing the file, since it also
    # holds GITHUB_TOKEN - no need to pull that into this shell just to
    # read the variant.
    if [ -f "/etc/hydrodactyl/auto-update-wings.env" ]; then
      WINGS_VARIANT=$(grep '^WINGS_VARIANT=' "/etc/hydrodactyl/auto-update-wings.env" 2>/dev/null | head -1 | cut -d'"' -f2)
    fi
  fi
}

show_welcome() {
  print_header

  # Detect OS if possible
  local os_info="Unknown"
  if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    os_info="$NAME $VERSION_ID"
  fi

  echo -e "  ${COLOR_ORANGE}Operating System:${COLOR_NC} $os_info"
  echo ""

  # Check and display installed components
  check_installations

  if [ "$PANEL_INSTALLED" == true ]; then
    echo -e "  ${COLOR_GREEN}✓${COLOR_NC} Panel installed${PANEL_VERSION:+ ($PANEL_VERSION)}"
  else
    echo -e "  ${COLOR_RED}✗${COLOR_NC} Panel not installed"
  fi

  if [ "$WINGS_INSTALLED" == true ]; then
    local wings_label="Wings"
    [ "$WINGS_VARIANT" == "rs" ] && wings_label="Wings-RS"
    echo -e "  ${COLOR_GREEN}✓${COLOR_NC} ${wings_label} installed${WINGS_VERSION:+ ($WINGS_VERSION)}"
  else
    echo -e "  ${COLOR_RED}✗${COLOR_NC} Wings not installed"
  fi

  echo ""
  print_brake 70
  echo ""
}

# ------------------ Direct Update Functions ----------------- #

run_panel_update() {
  print_header
  print_flame "Update Hydrodactyl Panel"

  if [ ! -d "/var/www/hydrodactyl" ]; then
    error "Panel is not installed at /var/www/hydrodactyl"
    return 1
  fi

  # Check if auto-updater env file exists
  if [ -f "/etc/hydrodactyl/auto-update-panel.env" ]; then
    output "Using existing auto-updater configuration..."
  else
    # Create temporary env file with defaults
    mkdir -p /etc/hydrodactyl
    echo "PANEL_REPO=\"BlueprintFramework/hydrodactyl\"" > /etc/hydrodactyl/auto-update-panel.env
    echo "GITHUB_TOKEN=\"\"" >> /etc/hydrodactyl/auto-update-panel.env
    chmod 600 /etc/hydrodactyl/auto-update-panel.env
  fi

  output "Getting and running panel auto-updater..."
  echo ""

  # Get and run the auto-update script
  if ! get_script "installers" "auto-update-panel"; then
    error "Update failed"
    return 1
  fi
  echo ""
  output "Press Enter to continue..."
  read -r
}

run_wings_update() {
  print_header
  print_flame "Update Wings Daemon"

  if ! wings_resolve_for_action update; then
    error "Hydrodactyl Wings is not installed, or it cannot be updated without touching another Wings install."
    return 1
  fi
  if [ ! -e "$WINGS_BINARY" ]; then
    error "Wings is not installed at ${WINGS_BINARY}"
    return 1
  fi

  # Check if a complete auto-updater env file exists (installs from before
  # variant tracking was added may have no file, or one missing WINGS_VARIANT)
  if [ -f "/etc/hydrodactyl/auto-update-wings.env" ] && grep -q '^WINGS_VARIANT=' "/etc/hydrodactyl/auto-update-wings.env"; then
    output "Using existing auto-updater configuration..."
  else
    warning "No saved Wings variant found for this install (it may predate variant tracking)."
    local is_rs_variant="n"
    bool_input is_rs_variant "Is the currently installed Wings a Wings-RS (Rust) build, rather than the standard Go Wings?" "n"

    WINGS_VARIANT="go"
    WINGS_REPO="pterodactyl/wings"
    if [ "$is_rs_variant" == "y" ]; then
      WINGS_VARIANT="rs"
      WINGS_REPO="calagopus/wings"
    fi
    GITHUB_TOKEN=""
    WINGS_REPO_PRIVATE="false"
    save_wings_update_config
  fi

  output "Getting and running Wings auto-updater..."
  echo ""

  # Get and run the auto-update script
  if ! get_script "installers" "auto-update-wings"; then
    error "Update failed"
    return 1
  fi
  echo ""
  output "Press Enter to continue..."
  read -r
}

run_both_updates() {
  print_header
  print_flame "Update Both Panel and Wings"

  run_panel_update
  echo ""
  run_wings_update
}



# Show main menu
show_menu() {
  local choice=""

  while true; do
    show_welcome

    echo ""
    output "${COLOR_ORANGE}What would you like to do?${COLOR_NC}"
    echo ""
    output "[${COLOR_ORANGE}0${COLOR_NC}] Install Hydrodactyl Panel"
    output "[${COLOR_ORANGE}1${COLOR_NC}] Install Wings Daemon"
    output "[${COLOR_ORANGE}2${COLOR_NC}] Install both Panel and Wings (same machine)"
    echo ""

    # Update options - gray out if not installed
    local COLOR_DARK_GRAY='\033[90m'
    if [ "$PANEL_INSTALLED" == true ]; then
      output "[${COLOR_ORANGE}3${COLOR_NC}] Update Hydrodactyl Panel"
    else
      echo -e "* [3] ${COLOR_DARK_GRAY}Update Hydrodactyl Panel (not installed)${COLOR_NC}"
    fi

    if [ "$WINGS_INSTALLED" == true ]; then
      output "[${COLOR_ORANGE}4${COLOR_NC}] Update Wings Daemon"
    else
      echo -e "* [4] ${COLOR_DARK_GRAY}Update Wings Daemon (not installed)${COLOR_NC}"
    fi

    if [ "$PANEL_INSTALLED" == true ] && [ "$WINGS_INSTALLED" == true ]; then
      output "[${COLOR_ORANGE}5${COLOR_NC}] Update both Panel and Wings"
    else
      echo -e "* [5] ${COLOR_DARK_GRAY}Update both Panel and Wings (not available)${COLOR_NC}"
    fi

    echo ""
    output "[${COLOR_ORANGE}6${COLOR_NC}] Repair / Fix Common Issues"
    echo ""
    output "[${COLOR_ORANGE}7${COLOR_NC}] Health Check"
    echo ""
    output "[${COLOR_ORANGE}8${COLOR_NC}] Uninstall Hydrodactyl / Wings"
    echo ""
    output "[${COLOR_ORANGE}9${COLOR_NC}] View Installation Information"
    echo ""
    output "[${COLOR_ORANGE}10${COLOR_NC}] Remove Other Panels (Struxa, Pterodactyl, Dokploy, Coolify)"
    echo ""
    output "[${COLOR_ORANGE}11${COLOR_NC}] Exit"
    echo ""

    echo -n "* Select an option [0-11]: "
    read -r choice

    case "$choice" in
      0)
        execute_ui "panel"
        continue
        ;;
      1)
        execute_ui "wings"
        continue
        ;;
      2)
        execute_ui "both"
        continue
        ;;
      3)
        if [ "$PANEL_INSTALLED" == false ]; then
          error "Hydrodactyl Panel is not installed"
          sleep 2
          continue
        fi
        run_panel_update
        continue
        ;;
      4)
        if [ "$WINGS_INSTALLED" == false ]; then
          error "Wings Daemon is not installed"
          sleep 2
          continue
        fi
        run_wings_update
        continue
        ;;
      5)
        if [ "$PANEL_INSTALLED" == false ] || [ "$WINGS_INSTALLED" == false ]; then
          error "Both Panel and Wings must be installed to use this option"
          sleep 2
          continue
        fi
        run_both_updates
        continue
        ;;
      6)
        execute_ui "repair"
        continue
        ;;
      7)
        # Health Check - runs based on what's installed
        if [ "$PANEL_INSTALLED" == true ] && [ "$WINGS_INSTALLED" == true ]; then
          check_both_health
        elif [ "$PANEL_INSTALLED" == true ]; then
          check_panel_health
        elif [ "$WINGS_INSTALLED" == true ]; then
          check_wings_health
        else
          error "Nothing installed to check. Install Hydrodactyl or Wings first."
          sleep 2
          continue
        fi
        output "Press Enter to return to the menu..."
        read -r
        continue
        ;;
      8)
        execute_ui "uninstall"
        continue
        ;;
      9)
        execute_ui "view-info"
        continue
        ;;
      10)
        # Remove other panels
        local detected_panels
        detected_panels=($(detect_installed_panels))
        if [ ${#detected_panels[@]} -eq 0 ]; then
          output "No other panels detected on this server."
        else
          output "${COLOR_YELLOW}Detected panels:${COLOR_NC}"
          local idx=0
          local panel_names=()
          for panel in "${detected_panels[@]}"; do
            echo -e "  [${COLOR_ORANGE}$idx${COLOR_NC}] Remove $panel"
            panel_names+=("$panel")
            idx=$((idx + 1))
          done
          echo -e "  [${COLOR_ORANGE}$idx${COLOR_NC}] Remove all detected panels"
          echo ""
          echo -n "* Select [0-$idx]: "
          read -r panel_choice

          if [[ "$panel_choice" =~ ^[0-9]+$ ]] && [ "$panel_choice" -ge 0 ] && [ "$panel_choice" -lt "$idx" ]; then
            local selected="${panel_names[$panel_choice]}"
            local confirm=""
            bool_input confirm "Remove $selected? This cannot be undone" "n"
            if [ "$confirm" == "y" ]; then
              case "$selected" in
                Struxa) remove_struxa ;;
                Pterodactyl) remove_pterodactyl ;;
                Dokploy) remove_dokploy ;;
                Coolify) remove_coolify ;;
              esac
              success "$selected removed"
            fi
          elif [ "$panel_choice" == "$idx" ]; then
            local confirm=""
            bool_input confirm "Remove all detected panels? This cannot be undone" "n"
            if [ "$confirm" == "y" ]; then
              for panel in "${panel_names[@]}"; do
                case "$panel" in
                  Struxa) remove_struxa ;;
                  Pterodactyl) remove_pterodactyl ;;
                  Dokploy) remove_dokploy ;;
                  Coolify) remove_coolify ;;
                esac
              done
              success "All panels removed"
            fi
          fi
        fi
        output "Press Enter to continue..."
        read -r
        continue
        ;;
      11)
        output "Exiting..."
        exit 0
        ;;
      *)
        error "Invalid option. Please select 0-11."
        ;;
    esac
  done
}

# Main function
main() {
  check_root
  check_curl

  load_library
  log_execution
  show_welcome

  # Pre-flight system resource check
  echo ""
  output "${COLOR_ORANGE}Running system requirements check...${COLOR_NC}"
  if ! check_system_resources; then
    echo ""
    warning "Your system is below minimum requirements!"
    output "You may experience performance issues or installation failures."
    echo ""
    local continue_anyway=""
    while [[ "$continue_anyway" != "y" && "$continue_anyway" != "n" ]]; do
      echo -n "* Continue anyway? [y/N]: "
      read -r continue_anyway
      continue_anyway=$(echo "$continue_anyway" | tr '[:upper:]' '[:lower:]')
      [ -z "$continue_anyway" ] && continue_anyway="n"

      if [[ "$continue_anyway" != "y" && "$continue_anyway" != "n" ]]; then
        error "Invalid input. Please enter 'y' or 'n'."
      fi
    done

    if [[ "$continue_anyway" == "n" ]]; then
      exit 1
    fi
  fi

  # Check Docker compatibility for Wings/Elytra installations
  echo ""
  output "${COLOR_ORANGE}Checking Docker compatibility...${COLOR_NC}"
  check_docker_compatibility || true

  # Run menu/installation
  if show_menu; then
    echo ""
    print_flame "Thank you for using Hydrodactyl Installer!"
  fi

  # Always show log location at the end
  echo ""
  output "Installation log saved to: ${COLOR_ORANGE}$LOG_PATH${COLOR_NC}"
  echo ""
}

# Run main
main "$@"
