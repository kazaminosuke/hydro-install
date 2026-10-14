#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Hydrodactyl Wings path migration                                                   #
#                                                                                    #
# Copies an existing Hydrodactyl Wings install to the Hydrodactyl paths. The        #
# original files stay in place. Pelican and other external Wings installs are not   #
# stopped, overwritten, or deleted.                                                  #
#                                                                                    #
######################################################################################

fn_exists() { declare -F "$1" >/dev/null; }
if ! fn_exists lib_loaded; then
  # Only a copy this user owns and nobody else can write; /tmp is shared.
  if [ -f /tmp/hydrodactyl-lib.sh ] && [ ! -L /tmp/hydrodactyl-lib.sh ] && [ -O /tmp/hydrodactyl-lib.sh ] \
    && [ -z "$(find /tmp/hydrodactyl-lib.sh -perm /022 2>/dev/null)" ]; then
    if ! source /tmp/hydrodactyl-lib.sh 2>/dev/null; then
      rm -f /tmp/hydrodactyl-lib.sh
    fi
  fi
  if ! fn_exists lib_loaded; then
    # shellcheck source=../lib/lib.sh
    source <(curl -sSL "${GITHUB_BASE_URL:-"https://raw.githubusercontent.com/itzzjustmateo/hydro-install"}/${GITHUB_SOURCE:-"main"}/lib/lib.sh")
  fi
  ! fn_exists lib_loaded && echo "* ERROR: Could not load lib script" && exit 1
fi

main() {
  local template
  print_header
  print_flame "Migrate Wings to Hydrodactyl Paths"

  output "This copies the current Hydrodactyl Wings install to:"
  output "  Binary:  /usr/local/bin/hydrodactyl-wings"
  output "  Config:  /etc/hydrodactyl/wings/"
  output "  Data:    /var/lib/hydrodactyl/wings/"
  output "  Service: hydrodactyl-wings.service"
  output ""
  output "The files you have now stay where they are. A backup is written under"
  output "/var/backups/hydrodactyl/ before anything is copied. If a step fails,"
  output "the new files are removed and the original config is left unchanged."
  output "Another panel's Wings service is not stopped."
  echo ""

  template=$(mktemp)
  if ! get_config "wings.service" "$template" || ! grep -q '__WINGS_BINARY__' "$template"; then
    wings_builtin_service_template > "$template"
  fi
  WINGS_SERVICE_TEMPLATE="$template"
  export WINGS_SERVICE_TEMPLATE

  if ! wings_migrate_to_namespaced; then
    rm -f "$template"
    error "Migration was not completed. The original install is unchanged."
    exit 1
  fi
  rm -f "$template"

  success "Wings now uses the Hydrodactyl paths."
  output "Later updates, repairs, and uninstalls follow the new paths."
  output "The previous binary and config are still on disk."
}

main "$@"
