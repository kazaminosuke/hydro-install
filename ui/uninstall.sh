#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Hydrodactyl Uninstallation UI                                                       #
#                                                                                    #
# Copyright (C) 2026, ItzzMateo Studios                                             #
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

# ------------------ Root Check ----------------- #

check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "* ERROR: This script must be executed with root privileges."
    exit 1
  fi
}

check_root

# ------------------ Configuration Variables ----------------- #

REMOVE_PANEL=false
REMOVE_ELYTRA=false
REMOVE_WINGS=false
REMOVE_AUTO_UPDATERS=false
REMOVE_DATABASE=false
REMOVE_DATA=false

# ------------------ Detection ----------------- #

detect_installed_components() {
  PANEL_INSTALLED=false
  ELYTRA_INSTALLED=false
  WINGS_INSTALLED=false
  PANEL_UPDATER_INSTALLED=false
  DAEMON_UPDATER_INSTALLED=false

  if [ -d "/var/www/hydrodactyl" ]; then
    PANEL_INSTALLED=true
  fi

  # Legacy standalone Elytra daemon
  if [ -f "/usr/local/bin/elytra" ]; then
    ELYTRA_INSTALLED=true
  fi

  # Only a Hydrodactyl-owned daemon. Pelican's /usr/local/bin/wings is not ours.
  if wings_owned_binary >/dev/null 2>&1; then
    WINGS_INSTALLED=true
  fi

  if systemctl is-enabled --quiet hydrodactyl-panel-auto-update.timer 2>/dev/null; then
    PANEL_UPDATER_INSTALLED=true
  fi

  # Daemon auto-updater timer - installs from before the Wings/Elytra rename
  # (or a Wings-only install) may have either naming convention, so check both.
  if systemctl is-enabled --quiet hydrodactyl-elytra-auto-update.timer 2>/dev/null || \
     systemctl is-enabled --quiet hydrodactyl-wings-auto-update.timer 2>/dev/null; then
    DAEMON_UPDATER_INSTALLED=true
  fi
}

# ------------------ Main Menu ----------------- #

show_main_menu() {
  print_header
  print_flame "Uninstall Hydrodactyl / Elytra"

  output "Installed components detected:"
  echo ""

  if [ "$PANEL_INSTALLED" == true ]; then
    echo -e "  ${COLOR_GREEN}✓${COLOR_NC} Hydrodactyl Panel"
  else
    echo -e "  ${COLOR_RED}✗${COLOR_NC} Hydrodactyl Panel"
  fi

  if [ "$WINGS_INSTALLED" == true ]; then
    echo -e "  ${COLOR_GREEN}✓${COLOR_NC} Wings Daemon"
  else
    echo -e "  ${COLOR_RED}✗${COLOR_NC} Wings Daemon"
  fi

  if [ "$ELYTRA_INSTALLED" == true ]; then
    echo -e "  ${COLOR_GREEN}✓${COLOR_NC} Elytra Daemon (legacy)"
  else
    echo -e "  ${COLOR_RED}✗${COLOR_NC} Elytra Daemon (legacy)"
  fi

  if [ "$PANEL_UPDATER_INSTALLED" == true ] || [ "$DAEMON_UPDATER_INSTALLED" == true ]; then
    echo -e "  ${COLOR_GREEN}✓${COLOR_NC} Auto-updaters"
  else
    echo -e "  ${COLOR_RED}✗${COLOR_NC} Auto-updaters"
  fi

  echo ""
  output "What would you like to uninstall?"
  echo ""
  output "[${COLOR_ORANGE}0${COLOR_NC}] Uninstall Panel only"
  output "[${COLOR_ORANGE}1${COLOR_NC}] Uninstall Daemon only (Wings/Elytra)"
  output "[${COLOR_ORANGE}2${COLOR_NC}] Uninstall both Panel and Daemon"
  output "[${COLOR_ORANGE}3${COLOR_NC}] Remove auto-updaters only"
  output "[${COLOR_ORANGE}4${COLOR_NC}] Uninstall everything (Panel, Daemon, Auto-updaters)"
  output "[${COLOR_ORANGE}5${COLOR_NC}] Cancel"
  echo ""

  local choice=""
  while true; do
    echo -n "* Select [0-5]: "
    read -r choice

    case "$choice" in
      0)
        if [ "$PANEL_INSTALLED" == false ]; then
          error "Panel is not installed"
          continue
        fi
        REMOVE_PANEL=true
        confirm_uninstall "Panel"
        return
        ;;
      1)
        if [ "$ELYTRA_INSTALLED" == false ] && [ "$WINGS_INSTALLED" == false ]; then
          error "No daemon is installed"
          continue
        fi
        REMOVE_ELYTRA=$ELYTRA_INSTALLED
        REMOVE_WINGS=$WINGS_INSTALLED
        confirm_uninstall "the daemon"
        return
        ;;
      2)
        if [ "$PANEL_INSTALLED" == false ] && [ "$ELYTRA_INSTALLED" == false ] && [ "$WINGS_INSTALLED" == false ]; then
          error "Neither Panel nor a daemon are installed"
          continue
        fi
        REMOVE_PANEL=true
        REMOVE_ELYTRA=$ELYTRA_INSTALLED
        REMOVE_WINGS=$WINGS_INSTALLED
        confirm_uninstall "both Panel and the daemon"
        return
        ;;
      3)
        if [ "$PANEL_UPDATER_INSTALLED" == false ] && [ "$DAEMON_UPDATER_INSTALLED" == false ]; then
          error "No auto-updaters are installed"
          continue
        fi
        REMOVE_AUTO_UPDATERS=true
        confirm_uninstall "auto-updaters"
        return
        ;;
      4)
        if [ "$PANEL_INSTALLED" == false ] && [ "$ELYTRA_INSTALLED" == false ] && [ "$WINGS_INSTALLED" == false ]; then
          error "Nothing is installed"
          continue
        fi
        REMOVE_PANEL=true
        REMOVE_ELYTRA=$ELYTRA_INSTALLED
        REMOVE_WINGS=$WINGS_INSTALLED
        REMOVE_AUTO_UPDATERS=true
        confirm_uninstall "everything"
        return
        ;;
      5)
        output "Cancelled"
        exit 0
        ;;
      *)
        error "Invalid option. Please select 0-5."
        ;;
    esac
  done
}

# ------------------ Confirmation ----------------- #

confirm_uninstall() {
  local component="$1"

  print_header
  print_flame "Confirm Uninstall"

  warning "You are about to uninstall ${component}"
  echo ""

  if [ "$REMOVE_PANEL" == true ]; then
    output "Panel removal includes:"
    output "  - Panel files (/var/www/hydrodactyl)"
    output "  - Nginx configuration"
    output "  - Systemd services (hydroq)"
    output "  - Cron jobs"
    echo ""

    local remove_db=""
    bool_input remove_db "Also remove the panel database?" "n"
    [ "$remove_db" == "y" ] && REMOVE_DATABASE=true

    local remove_data=""
    bool_input remove_data "Also remove all server data and backups?" "n"
    [ "$remove_data" == "y" ] && REMOVE_DATA=true
  fi

  if [ "$REMOVE_WINGS" == true ]; then
    echo ""
    output "Wings removal includes:"
    if wings_resolve_for_action uninstall >/dev/null 2>&1; then
      output "  - Wings binary (${WINGS_BINARY})"
      output "  - Wings configuration (${WINGS_CONFIG_DIR})"
      output "  - Wings data (${WINGS_DATA_DIR})"
      output "  - Systemd service (${WINGS_SERVICE})"
    fi
    output "  - Docker containers created by this installer"
    echo ""
  fi

  if [ "$REMOVE_ELYTRA" == true ]; then
    echo ""
    output "Elytra removal includes:"
    output "  - Elytra binary (/usr/local/bin/elytra)"
    output "  - Elytra configuration (/etc/elytra)"
    output "  - Systemd service (elytra)"
    output "  - Docker containers (game servers will be stopped)"
    echo ""
  fi

  if [ "$REMOVE_AUTO_UPDATERS" == true ]; then
    echo ""
    output "Auto-updater removal includes:"
    output "  - Auto-update scripts"
    output "  - Systemd timer services"
    output "  - Configuration files"
    echo ""
  fi

  echo ""
  warning "This action cannot be undone!"
  echo ""
  local confirm=""
  bool_input confirm "Are you sure you want to proceed?" "n"

  if [ "$confirm" != "y" ]; then
    output "Uninstall cancelled"
    exit 0
  fi
}

# ------------------ Export and Run ----------------- #

export_variables() {
  export REMOVE_PANEL
  export REMOVE_ELYTRA
  export REMOVE_WINGS
  export REMOVE_AUTO_UPDATERS
  export REMOVE_DATABASE
  export REMOVE_DATA
}

# ------------------ Main ----------------- #

main() {
  detect_installed_components

  if [ "$PANEL_INSTALLED" == false ] && [ "$ELYTRA_INSTALLED" == false ] && [ "$WINGS_INSTALLED" == false ] && [ "$PANEL_UPDATER_INSTALLED" == false ] && [ "$DAEMON_UPDATER_INSTALLED" == false ]; then
    print_header
    print_flame "Nothing to Uninstall"
    output "No Hydrodactyl components were detected on this system."
    echo ""
    output "If you believe this is an error, you may need to manually remove:"
    output "  - /var/www/hydrodactyl (Panel files)"
    output "  - /usr/local/bin/hydrodactyl-wings or /usr/local/bin/wings (Wings binary)"
    output "  - /etc/hydrodactyl/wings or /etc/pterodactyl (Wings configuration)"
    output "  - /usr/local/bin/elytra (legacy Elytra binary)"
    output "  - /etc/elytra (legacy Elytra configuration)"
    exit 0
  fi

  show_main_menu
  export_variables

  output "Starting uninstallation..."
  run_installer "uninstall"
}

main
