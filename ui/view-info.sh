#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Hydrodactyl Installation Info Viewer                                                #
#                                                                                    #
# Displays saved installation information for Panel, Wings, and/or Elytra            #
#                                                                                    #
# Copyright (C) 2026, ItzzMateo Studios                                             #
#                                                                                    #
# https://github.com/itzzjustmateo/hydro-install                         #
#                                                                                    #
######################################################################################

# Check if script is loaded, load if not or fail otherwise.
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

# ------------------ Main Function ----------------- #

main() {
  print_header
  print_flame "Installation Information"

  local has_panel_info=false
  local has_wings_info=false
  local has_elytra_info=false

  # Check what information is available
  if panel_install_info_exists; then
    has_panel_info=true
  fi

  if wings_install_info_exists; then
    has_wings_info=true
  fi

  if elytra_install_info_exists; then
    has_elytra_info=true
  fi

  # Show summary
  echo ""
  if [ "$has_panel_info" == false ] && [ "$has_wings_info" == false ] && [ "$has_elytra_info" == false ]; then
    warning "No installation information found."
    echo ""
    output "Installation information is saved when you:"
    output "  - Install Hydrodactyl Panel"
    output "  - Install Wings Daemon"
    output "  - Install Elytra Daemon (legacy)"
    echo ""
    output "If you just completed an installation, the information"
    output "should be available. Try running the installer again."
    echo ""
    output "Press Enter to return to the menu..."
    read -r
    return 0
  else
    local found_parts=()
    [ "$has_panel_info" == true ] && found_parts+=("Panel")
    [ "$has_wings_info" == true ] && found_parts+=("Wings")
    [ "$has_elytra_info" == true ] && found_parts+=("Elytra")
    local found_list
    found_list=$(printf '%s, ' "${found_parts[@]}")
    found_list=${found_list%, }
    output "Installation information found for: ${found_list}."
  fi

  echo ""

  # Display panel info if available
  if [ "$has_panel_info" == true ]; then
    display_panel_install_info
    echo ""
  fi

  # Display Wings info if available
  if [ "$has_wings_info" == true ]; then
    display_wings_install_info
    echo ""
  fi

  # Display elytra info if available
  if [ "$has_elytra_info" == true ]; then
    display_elytra_install_info
    echo ""
  fi

  # Check for health check failure logs
  local has_health_check_failures=false

  if [ -f "/etc/hydrodactyl/update-health-check-failure.log" ]; then
    has_health_check_failures=true
  fi

  if [ -f "/etc/pterodactyl/update-health-check-failure.log" ] || [ -f "/etc/hydrodactyl/wings/update-health-check-failure.log" ]; then
    has_health_check_failures=true
  fi

  if [ -f "/etc/elytra/update-health-check-failure.log" ]; then
    has_health_check_failures=true
  fi

  if [ "$has_health_check_failures" == true ]; then
    echo ""
    warning "Health check failures detected!"
    output "Recent update attempts failed health checks."
    echo ""
    echo -n "* View health check failure logs? [y/N]: "
    read -r view_health
    view_health=$(echo "$view_health" | tr '[:upper:]' '[:lower:]')

    if [ "$view_health" == "y" ]; then
      echo ""
      if [ -f "/etc/hydrodactyl/update-health-check-failure.log" ]; then
        output "Panel Health Check Failure Log:"
        echo "---"
        cat "/etc/hydrodactyl/update-health-check-failure.log" 2>/dev/null || echo "Could not read file"
        echo "---"
        echo ""
      fi

      local wings_health_log=""
      if [ -f "/etc/hydrodactyl/wings/update-health-check-failure.log" ]; then
        wings_health_log="/etc/hydrodactyl/wings/update-health-check-failure.log"
      elif [ -f "/etc/pterodactyl/update-health-check-failure.log" ]; then
        wings_health_log="/etc/pterodactyl/update-health-check-failure.log"
      fi
      if [ -n "$wings_health_log" ]; then
        output "Wings Health Check Failure Log:"
        echo "---"
        cat "$wings_health_log" 2>/dev/null || echo "Could not read file"
        echo "---"
        echo ""
      fi

      if [ -f "/etc/elytra/update-health-check-failure.log" ]; then
        output "Elytra Health Check Failure Log:"
        echo "---"
        cat "/etc/elytra/update-health-check-failure.log" 2>/dev/null || echo "Could not read file"
        echo "---"
        echo ""
      fi

      output "To fix these issues, run the Repair Tool from the main menu."
      echo ""
    fi
  fi

  # Option to view raw files
  echo ""
  echo -n "* View raw configuration files? [y/N]: "
  read -r view_raw
  view_raw=$(echo "$view_raw" | tr '[:upper:]' '[:lower:]')

  if [ "$view_raw" == "y" ]; then
    echo ""
    if [ "$has_panel_info" == true ]; then
      output "Panel Info File: $INSTALL_INFO_DIR/panel-info"
      echo "---"
      cat "$INSTALL_INFO_DIR/panel-info" 2>/dev/null || echo "Could not read file"
      echo "---"
      echo ""
    fi

    if [ "$has_wings_info" == true ]; then
      output "Wings Info File: $INSTALL_INFO_DIR/wings-info"
      echo "---"
      cat "$INSTALL_INFO_DIR/wings-info" 2>/dev/null || echo "Could not read file"
      echo "---"
      echo ""
    fi

    if [ "$has_elytra_info" == true ]; then
      output "Elytra Info File: $INSTALL_INFO_DIR/elytra-info"
      echo "---"
      cat "$INSTALL_INFO_DIR/elytra-info" 2>/dev/null || echo "Could not read file"
      echo "---"
      echo ""
    fi
  fi

  output "Press Enter to return to the menu..."
  read -r
}

# Run main
main "$@"