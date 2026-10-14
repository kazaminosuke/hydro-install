#!/bin/bash

set -e

# Check if lib is loaded, load if not or fail otherwise.
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

# Configuration
PANEL_DIR="/var/www/hydrodactyl"
ELYTRA_DIR="/etc/elytra"
PANEL_DATA_DIR="/var/lib/hydrodactyl"

remove_panel() {
    print_flame "Removing Hydrodactyl Panel"

    # Stop services
    output "Stopping panel services..."
    systemctl stop hydroq 2>/dev/null || true
    systemctl disable hydroq 2>/dev/null || true

    # Remove nginx config
    output "Removing nginx configuration..."
    rm -f /etc/nginx/sites-available/hydrodactyl.conf
    rm -f /etc/nginx/sites-enabled/hydrodactyl.conf

    # Reload nginx if it's running
    if systemctl is-active --quiet nginx; then
        nginx -t && systemctl reload nginx
    fi

    # Remove panel files
    if [ -d "$PANEL_DIR" ]; then
        output "Removing panel files..."
        rm -rf "$PANEL_DIR"
    fi

    # Remove systemd service
    rm -f /etc/systemd/system/hydroq.service
    systemctl daemon-reload

    # Remove cron job
    crontab -l 2>/dev/null | grep -v "hydrodactyl" | crontab - 2>/dev/null || true

    # Remove SSL certificates if Let's Encrypt was used
    if [ -d "/etc/letsencrypt" ]; then
        output "Checking for Let's Encrypt certificates..."
        certbot delete --cert-name "$(hostname -f)" 2>/dev/null || true
    fi

    success "Panel removed"
}

# Shared daemon-removal steps for Elytra and Wings/Wings-RS, so their
# uninstall logic (service, binary, config, Docker containers, data dir,
# tracking files) can't silently drift apart as separate copies.
# Usage: remove_daemon_common <label> <service> <binary> <config_dir> <data_dir> <version_file...>
remove_daemon_common() {
    local label="$1"
    local service="$2"
    local binary="$3"
    local config_dir="$4"
    local data_dir="$5"
    shift 5
    local version_files=("$@")

    print_flame "Removing ${label}"

    # Stop and remove service
    output "Stopping ${label} service..."
    systemctl stop "$service" 2>/dev/null || true
    systemctl disable "$service" 2>/dev/null || true

    # Remove binary
    output "Removing ${label} binary..."
    rm -f "$binary"

    # Remove configuration
    if [ -d "$config_dir" ]; then
        output "Removing ${label} configuration..."
        rm -rf "$config_dir"
    fi

    output "Stopping containers that mount ${data_dir}..."
    wings_stop_containers_using "$data_dir" || true

    # Remove systemd service
    rm -f "/etc/systemd/system/${service}.service"
    systemctl daemon-reload

    # Remove data directory
    if [ -d "$data_dir" ]; then
        output "Removing ${label} data directory..."
        rm -rf "$data_dir"
    fi

    # Remove version/tracking files
    local version_file
    for version_file in "${version_files[@]}"; do
        rm -f "$version_file"
    done

    # Success message is printed by the caller, not here - remove_elytra()
    # and remove_wings() both have an extra user-removal step after this
    # returns, and printing "removed" before that step completes would be
    # misleading.
}

remove_elytra() {
    remove_daemon_common "Elytra" "elytra" "/usr/local/bin/elytra" "$ELYTRA_DIR" \
        "/var/lib/elytra" "/etc/hydrodactyl/elytra-version"

    # Remove hydrodactyl user (if it exists). This is Elytra's own dedicated
    # system user, distinct from Wings' "pterodactyl" user (see
    # remove_wings() below) - each daemon cleans up only its own identity.
    if id -u hydrodactyl >/dev/null 2>&1; then
        output "Removing hydrodactyl user..."
        userdel hydrodactyl 2>/dev/null || true
        groupdel hydrodactyl 2>/dev/null || true
    fi

    success "Elytra removed"
}

remove_wings() {
    if ! wings_resolve_for_action uninstall; then
        warning "No Hydrodactyl Wings installation was found. Nothing was removed."
        return 0
    fi

    local foreign_before=false
    if [ "$WINGS_FOREIGN_PRESENT" = true ]; then
        foreign_before=true
    fi

    print_flame "Removing Wings"

    if wings_may_stop_service "$WINGS_SERVICE"; then
        output "Stopping ${WINGS_SERVICE}..."
        systemctl stop "$WINGS_SERVICE" 2>/dev/null || true
        systemctl disable "$WINGS_SERVICE" 2>/dev/null || true
    else
        warning "Leaving service ${WINGS_SERVICE} untouched"
    fi

    if wings_may_modify_path "$WINGS_BINARY"; then
        output "Removing Wings binary..."
        rm -f "$WINGS_BINARY"
    else
        warning "Leaving ${WINGS_BINARY} in place"
    fi

    if wings_may_modify_path "$WINGS_CONFIG_DIR"; then
        output "Removing Wings configuration..."
        rm -rf "$WINGS_CONFIG_DIR"
    else
        warning "Leaving ${WINGS_CONFIG_DIR} in place"
    fi

    local unit_path="/etc/systemd/system/${WINGS_SERVICE}.service"
    if wings_may_modify_path "$unit_path"; then
        rm -f "$unit_path"
    fi
    if [ "$WINGS_SERVICE" != "wings" ] && wings_may_modify_path "/etc/systemd/system/wings.service"; then
        systemctl disable wings 2>/dev/null || true
        rm -f /etc/systemd/system/wings.service
    fi
    systemctl daemon-reload

    if wings_may_modify_path "$WINGS_DATA_DIR"; then
        output "Stopping containers that mount ${WINGS_DATA_DIR}..."
        wings_stop_containers_using "$WINGS_DATA_DIR" || true
        output "Removing Wings data directory..."
        rm -rf "$WINGS_DATA_DIR"
    else
        warning "Leaving ${WINGS_DATA_DIR} in place"
    fi
    local extra_dir
    for extra_dir in "$WINGS_LOG_DIR" "$WINGS_TMP_DIR"; do
        [ -n "$extra_dir" ] || continue
        if wings_may_modify_path "$extra_dir"; then
            rm -rf "$extra_dir"
        else
            warning "Leaving ${extra_dir} in place"
        fi
    done

    rm -f /etc/hydrodactyl/wings-version \
        /etc/hydrodactyl/auto-update-wings.env \
        /etc/hydrodactyl/wings-layout.env \
        /etc/hydrodactyl/install-info/wings-info

    # The pterodactyl user is shared with a foreign Wings install and with any
    # legacy files this removal was not allowed to delete.
    if [ "$foreign_before" = true ] || [ -e /usr/local/bin/wings ] || [ -d /etc/pterodactyl ] || [ -d /var/lib/pterodactyl ] || [ -d /etc/pelican ] || [ -d /var/lib/pelican ]; then
        output "Leaving the pterodactyl user in place"
    elif id -u pterodactyl >/dev/null 2>&1; then
        output "Removing pterodactyl user..."
        userdel pterodactyl 2>/dev/null || true
        groupdel pterodactyl 2>/dev/null || true
    fi

    success "Wings removed"
}

remove_auto_updaters() {
    print_flame "Removing Auto-Updaters"

    # Remove panel auto-updater
    remove_auto_updater_panel

    # Remove Elytra auto-updater
    remove_auto_updater_elytra

    # Remove backup directories
    rm -rf /var/backups/hydrodactyl
    rm -rf /var/backups/elytra

    # Remove /etc/hydrodactyl directory if empty
    if [ -d "/etc/hydrodactyl" ]; then
        rmdir /etc/hydrodactyl 2>/dev/null || true
    fi

    success "Auto-updaters removed"
}

remove_database() {
    print_flame "Removing Database"

    output "This will remove the panel database and database user."

    if [ -f /root/.config/hydrodactyl/db-credentials ]; then
        local db_root_pass
        db_root_pass=$(grep '^root:' /root/.config/hydrodactyl/db-credentials | cut -d':' -f2)

        # Drop database
        output "Dropping database 'panel'..."
        mysql_root "${db_root_pass}" -e "DROP DATABASE IF EXISTS panel;" 2>/dev/null || warning "Could not drop database"

        # Drop user
        output "Dropping database user..."
        mysql_root "${db_root_pass}" -e "DROP USER IF EXISTS 'hydrodactyl'@'localhost';" 2>/dev/null || true
        mysql_root "${db_root_pass}" -e "DROP USER IF EXISTS 'hydrodactyl'@'127.0.0.1';" 2>/dev/null || true
        mysql_root "${db_root_pass}" -e "DROP USER IF EXISTS 'hydrodactyl'@'%';" 2>/dev/null || true
        mysql_root "${db_root_pass}" -e "FLUSH PRIVILEGES;" 2>/dev/null || true

        # Remove credentials file
        rm -f /root/.config/hydrodactyl/db-credentials
        rmdir /root/.config/hydrodactyl 2>/dev/null || true
        rmdir /root/.config 2>/dev/null || true

        success "Database removed"
    else
        warning "Database credentials not found. You may need to manually remove the database."
    fi
}

remove_phpmyadmin() {
    print_flame "Removing phpMyAdmin"

    output "Removing phpMyAdmin configuration..."

    # Get root password if available
    local db_root_pass=""
    if [ -f /root/.config/hydrodactyl/db-credentials ]; then
        db_root_pass=$(grep '^root:' /root/.config/hydrodactyl/db-credentials | cut -d':' -f2)
    fi

    # Drop phpmyadmin database users
    if [ -n "$db_root_pass" ]; then
        output "Dropping phpMyAdmin database users..."
        mysql_root "${db_root_pass}" -e "DROP USER IF EXISTS 'phpmyadmin'@'localhost';" 2>/dev/null || true
        mysql_root "${db_root_pass}" -e "DROP USER IF EXISTS 'phpmyadmin'@'127.0.0.1';" 2>/dev/null || true
        mysql_root "${db_root_pass}" -e "DROP USER IF EXISTS 'phpmyadmin'@'%';" 2>/dev/null || true
        mysql_root "${db_root_pass}" -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    fi

    # Remove nginx config
    rm -f /etc/nginx/sites-available/phpmyadmin.conf
    rm -f /etc/nginx/sites-enabled/phpmyadmin.conf

    # Reload nginx
    if systemctl is-active --quiet nginx; then
        nginx -t && systemctl reload nginx
    fi

    # Remove phpMyAdmin config files
    rm -f /etc/phpmyadmin/conf.d/99-custom.php

    # Remove phpMyAdmin credentials from file
    if [ -f /root/.config/hydrodactyl/db-credentials ]; then
        sed -i '/^phpmyadmin:/d' /root/.config/hydrodactyl/db-credentials
    fi

    # Purge debconf database for clean reinstall
    output "Purging phpMyAdmin debconf database..."
    echo "PURGE" | debconf-communicate phpmyadmin 2>/dev/null || true

    success "phpMyAdmin configuration removed"
}

remove_data() {
    print_flame "Removing Data Files"

    output "This will remove all server data, backups, and eggs."

    if [ -d "$PANEL_DATA_DIR" ]; then
        output "Removing data directory: $PANEL_DATA_DIR"
        rm -rf "$PANEL_DATA_DIR"
    fi

    # Remove any remaining Docker volumes
    output "Removing Docker volumes..."
    docker volume ls -q --filter "name=hydrodactyl" | xargs -r docker volume rm 2>/dev/null || true

    success "Data files removed"
}

cleanup_packages() {
    print_flame "Cleaning up packages"

    output "Would you like to remove the installed packages (nginx, php, mariadb, etc.)?"
    output "Warning: This may affect other services on your system."

    local remove_packages=""
    bool_input remove_packages "Remove packages?" "n"

    if [ "$remove_packages" == "y" ]; then
        output "Removing packages..."

        case "$OS" in
            ubuntu | debian)
                apt-get remove -y \
                    php8.4-fpm php8.4-cli php8.4-gd php8.4-mysql \
                    php8.4-pdo php8.4-mbstring php8.4-tokenizer \
                    php8.4-bcmath php8.4-xml php8.4-curl php8.4-zip \
                    php8.4-intl php8.4-redis php8.4-sqlite3 \
                    nginx mariadb-server redis-server \
                    2>/dev/null || warning "Some packages may not have been installed"

                apt-get autoremove -y
                ;;

            rocky | almalinux)
                dnf remove -y \
                    php-fpm php-cli php-gd php-mysqlnd \
                    php-pdo php-mbstring php-tokenizer \
                    php-bcmath php-xml php-curl php-zip \
                    php-intl php-redis php-sqlite3 \
                    nginx mariadb-server redis \
                    2>/dev/null || warning "Some packages may not have been installed"
                ;;
        esac

        success "Packages removed"
    fi
}

main() {
    print_header
    print_flame "Starting Uninstallation"

    # Remove components based on what was requested
    if [ "$REMOVE_AUTO_UPDATERS" == "true" ]; then
        remove_auto_updaters
    fi

    if [ "$REMOVE_PANEL" == "true" ]; then
        remove_panel
        remove_phpmyadmin
    fi

    if [ "$REMOVE_ELYTRA" == "true" ]; then
        remove_elytra
    fi

    if [ "$REMOVE_WINGS" == "true" ]; then
        remove_wings
    fi

    if [ "$REMOVE_DATABASE" == "true" ]; then
        remove_database
    fi

    if [ "$REMOVE_DATA" == "true" ]; then
        remove_data
    fi

    # Ask about package cleanup only if removing everything
    if [ "$REMOVE_PANEL" == "true" ] && { [ "$REMOVE_ELYTRA" == "true" ] || [ "$REMOVE_WINGS" == "true" ]; }; then
        cleanup_packages
    fi

    print_header
    print_flame "Uninstallation Complete!"

    echo ""
    output "Hydrodactyl has been uninstalled from your system."
    output ""
    output "Note: Some configuration files may remain in:"
    output "  ${COLOR_ORANGE}/etc/nginx/${COLOR_NC}"
    output "  ${COLOR_ORANGE}/etc/mysql/${COLOR_NC}"
    output "  ${COLOR_ORANGE}/etc/redis/${COLOR_NC}"
    output ""
    output "If you no longer need these services, you can remove them manually."

    print_brake 70
}

main
