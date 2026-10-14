# Hydrodactyl Panel + Elytra Daemon - Same Machine Installation Guide

> **Elytra is deprecated.** This guide walks through the legacy Elytra daemon specifically. For a new same-machine setup, we recommend combining the [Hydrodactyl Panel Manual](./hydrodactyl-panel-manual.md) with the [Wings Daemon Manual](./wings-manual.md) instead, or simply using the automated installer's "Install both Panel and Wings" option. This guide remains available for maintaining existing legacy Elytra installations.

This guide covers installing both the Hydrodactyl Panel and Elytra Daemon on the same physical or virtual server. This setup is suitable for small deployments, development environments, or single-node installations.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [System Requirements](#system-requirements)
3. [Prerequisites](#prerequisites)
4. [Step 1: System Preparation](#step-1-system-preparation)
5. [Step 2: Install Dependencies](#step-2-install-dependencies)
6. [Step 3: Database Setup](#step-3-database-setup)
7. [Step 4: Install and Configure Hydrodactyl Panel](#step-4-install-and-configure-hydrodactyl-panel)
8. [Step 5: Install and Configure Elytra Daemon](#step-5-install-and-configure-elytra-daemon)
9. [Step 6: SSL/TLS Configuration](#step-6-ssltls-configuration)
10. [Step 7: Configure Firewall](#step-7-configure-firewall)
11. [Step 8: Create Node and Connect Services](#step-8-create-node-and-connect-services)
12. [Verification](#verification)
13. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

When running both Panel and Daemon on the same machine:

```text
┌─────────────────────────────────────────────────────┐
│                  Single Server                      │
│                                                     │
│  ┌──────────────────────────────────────────┐       │
│  │          Hydrodactyl Panel                │       │
│  │   - Nginx (Port 80/443)                  │       │
│  │   - PHP-FPM (Unix Socket)                │       │
│  │   - MariaDB (Port 3306)                  │       │
│  │   - Redis (Port 6379)                    │       │
│  └──────────────────────────────────────────┘       │
│                                                     │
│  ┌──────────────────────────────────────────┐       │
│  │          Elytra Daemon                   │       │
│  │   - API Server (Port 8080)               │       │
│  │   - Docker (Internal 172.18.0.0/16)      │       │
│  │   - Game Servers (Various Ports)         │       │
│  └──────────────────────────────────────────┘       │
│                                                     │
└─────────────────────────────────────────────────────┘
```

**Communication Flow:**

- Panel communicates with Elytra via HTTPS on port 8080 (localhost)
- Elytra communicates with Panel API via HTTPS on port 443
- Both share the same database (MariaDB)
- Both use Redis (can be shared)

---

## System Requirements

### Minimum Requirements (Single Machine)

| Component | Specification |
| ----------- | -------------- |
| **CPU** | 4 cores (x86_64 or ARM64) |
| **RAM** | 4 GB |
| **Storage** | 50 GB SSD |
| **Network** | Public IPv4 or IPv6 |
| **OS** | Ubuntu 22.04/24.04, Debian 12, Rocky Linux 9, AlmaLinux 9 |

### Recommended Requirements (Single Machine)

| Component | Specification |
| ----------- | -------------- |
| **CPU** | 4+ cores |
| **RAM** | 8+ GB |
| **Storage** | 100+ GB SSD |
| **Network** | Both IPv4 and IPv6 |

**Note:** Running both services on the same machine requires more resources than running them separately. Game servers (managed by Elytra) will consume additional resources.

---

## Prerequisites

Before beginning:

- Root access to a dedicated server or VPS
- **Two domain names or subdomains:**
  - Panel domain: `panel.yourdomain.com`
  - Daemon domain: `daemon.yourdomain.com` (can be same IP)
  - Alternatively, use `panel.yourdomain.com` for Panel and `panel.yourdomain.com:8080` for Elytra
- Basic understanding of Docker and Linux
- Server must support Docker (KVM/VMware/Xen - NOT OpenVZ/LXC)

Verify Docker compatibility:

```bash
systemd-detect-virt
# Should NOT return: openvz, lxc, lxc-libvirt
```

---

## Step 1: System Preparation

### Update System

```bash
apt update && apt upgrade -y  # Ubuntu/Debian
dnf update -y                 # Rocky/AlmaLinux
```

### Set Hostname (Optional)

```bash
hostnamectl set-hostname panel-node
```

### Configure Timezone

Setting the correct timezone ensures log timestamps, scheduled tasks, and PHP date functions display the correct time.

**Detect current timezone:**

```bash
timedatectl show --property=Timezone --value
```

**List available timezones:**

```bash
timedatectl list-timezones
# Alternatively, browse by region:
ls /usr/share/zoneinfo/Europe/
```

**Set your timezone** (e.g., Europe/Berlin, America/New_York, UTC):

```bash
timedatectl set-timezone Europe/Berlin
```

**Install and enable NTP for accurate time sync:**

```bash
# Ubuntu/Debian:
apt install -y chrony
systemctl enable --now chrony

# Rocky/AlmaLinux:
dnf install -y chrony
systemctl enable --now chronyd
```

**Verify configuration:**

```bash
timedatectl
chronyc tracking
```

---

## Step 2: Install Dependencies

Install all dependencies for both Panel and Elytra at once:

### Ubuntu/Debian

```bash
# Add repositories
apt install -y software-properties-common apt-transport-https ca-certificates gnupg2 curl
LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php

# Add Docker repository
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update

# Install PHP, Nginx, MariaDB, Redis, Docker
apt install -y php8.4-fpm php8.4-cli php8.4-gd php8.4-mysql \
  php8.4-pdo php8.4-mbstring php8.4-tokenizer php8.4-bcmath \
  php8.4-xml php8.4-curl php8.4-zip php8.4-intl php8.4-redis \
  php8.4-sqlite3

apt install -y nginx mariadb-server redis-server \
  certbot python3-certbot-nginx docker-ce docker-ce-cli containerd.io

# Install tools
apt install -y curl tar unzip git jq composer
```

### Rocky Linux/AlmaLinux

```bash
# Add repositories
dnf install -y epel-release
dnf install -y "https://rpms.remirepo.net/enterprise/remi-release-$(rpm -E %rhel).rpm"

# Enable PHP 8.4
dnf module reset php -y
dnf module enable php:remi-8.4 -y

# Add Docker repository
dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo

# Install packages
dnf install -y php php-fpm php-cli php-gd php-mysqlnd php-pdo \
  php-mbstring php-tokenizer php-bcmath php-xml php-curl php-zip \
  php-intl php-redis php-sqlite3

dnf install -y nginx mariadb-server redis docker-ce docker-ce-cli containerd.io
dnf install -y curl tar unzip git jq

# Install Composer
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
```

### Enable Swap (Important for Single Machine)

```bash
fallocate -l 4G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
sysctl vm.swappiness=10
echo "vm.swappiness=10" >> /etc/sysctl.conf
```

---

## Step 3: Database Setup

### Start Services

```bash
systemctl enable --now mariadb redis docker
```

### Secure MariaDB

```bash
mysql_secure_installation
# Set root password, remove anonymous users, disable remote root, remove test db
```

### Create Database and User

```bash
mysql -u root -p <<EOF
CREATE DATABASE panel CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'hydrodactyl'@'127.0.0.1' IDENTIFIED BY 'YOUR_SECURE_PASSWORD';
GRANT ALL PRIVILEGES ON panel.* TO 'hydrodactyl'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
```

Save this password - you'll need it when configuring the Panel's `.env` file below. The daemon (Elytra or Wings) does not use this database, so it isn't needed there.

---

## Step 4: Install and Configure Hydrodactyl Panel

### Create Directory

```bash
mkdir -p /var/www/hydrodactyl
cd /var/www/hydrodactyl
```

### Download Panel

```bash
curl -Lo panel.tar.gz $(curl -s https://api.github.com/repos/BlueprintFramework/hydrodactyl/releases/latest | grep "tarball_url" | cut -d'"' -f4)
tar -xzf panel.tar.gz --strip-components=1
rm panel.tar.gz
```

### Set Permissions

```bash
chown -R www-data:www-data /var/www/hydrodactyl
chmod -R 755 /var/www/hydrodactyl
```

### Install Dependencies

```bash
cd /var/www/hydrodactyl
composer install --no-dev --optimize-autoloader --no-interaction
```

### Configure Environment

```bash
cp .env.example .env
nano .env
```

**Key settings for same-machine setup:**

```ini
APP_URL=https://panel.yourdomain.com
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=panel
DB_USERNAME=hydrodactyl
DB_PASSWORD=YOUR_SECURE_PASSWORD
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
```

### Generate Key and Migrate

```bash
php artisan key:generate --force
php artisan migrate --seed --force
```

### Create Admin User

```bash
php artisan p:user:make
```

### Cache Configuration

```bash
php artisan config:cache
php artisan route:cache
php artisan view:cache
```

### Configure Nginx

Create `/etc/nginx/sites-available/hydrodactyl`:

```nginx
server {
    listen 80;
    server_name panel.yourdomain.com;
    root /var/www/hydrodactyl/public;
    index index.php;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.4-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}

server {
    listen 80;
    server_name daemon.yourdomain.com;
    return 301 https://panel.yourdomain.com$request_uri;
}
```

Enable:

```bash
ln -s /etc/nginx/sites-available/hydrodactyl /etc/nginx/sites-enabled/
rm /etc/nginx/sites-enabled/default 2>/dev/null || true
nginx -t
systemctl restart nginx
```

### Queue Worker Service

Create `/etc/systemd/system/hydroq.service`:

```ini
[Unit]
Description=Hydrodactyl Queue Worker
After=redis-server.service mariadb.service

[Service]
Type=simple
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/hydrodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3 --max-time=3600 --max-jobs=1000 --memory=512
OOMScoreAdjust=-100
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

Enable:

```bash
systemctl daemon-reload
systemctl enable --now hydroq
```

### Cron Job

```bash
crontab -e
# Add:
* * * * * cd /var/www/hydrodactyl && php artisan schedule:run >> /dev/null 2>&1
```

---

## Step 5: Install and Configure Elytra Daemon

### Create Directories

```bash
mkdir -p /var/lib/elytra/volumes /var/lib/elytra/archives /var/lib/elytra/backups /etc/elytra
```

### Download Elytra

```bash
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
curl -Lo /usr/local/bin/elytra "https://github.com/pyrohost/elytra/releases/latest/download/elytra_linux_${ARCH}"
chmod +x /usr/local/bin/elytra
```

### Create System User

```bash
groupadd --system --gid 8888 hydrodactyl 2>/dev/null || true
useradd --system --no-create-home --shell /usr/sbin/nologin --uid 8888 --gid 8888 hydrodactyl 2>/dev/null || true

chown -R 8888:8888 /var/lib/elytra /etc/elytra

# SECURITY NOTE: 777 is required because containerized game servers run as
# various UIDs and must read/write game data. This grants all users access.
# Ensure /var/lib/elytra parent directory restricts access.
chmod -R 777 /var/lib/elytra/volumes /var/lib/elytra/archives /var/lib/elytra/backups
chmod -R 755 /etc/elytra
# SECURITY: Config contains daemon credentials - restrict to owner-only
[ -f /etc/elytra/config.yml ] && chmod 600 /etc/elytra/config.yml
```

### Initial Config (Temporary)

Create `/etc/elytra/config.yml` with placeholder:

```yaml
debug: false
uuid: PLACEHOLDER
token-id: PLACEHOLDER
token: PLACEHOLDER

api:
    host: 0.0.0.0
    port: 8080
    ssl:
        enabled: false
    upload-limit: 100

system:
    data: /var/lib/elytra/volumes
    archive: /var/lib/elytra/archives
    backup: /var/lib/elytra/backups

remote: https://panel.yourdomain.com

docker:
    network:
        interface: 172.18.0.1
        gateway: 172.18.0.1
        subnet: 172.18.0.0/16

throttles:
    enabled: true
    lines: 1000
    line_reset_interval: 100
    maximum_trigger_count: 5

installed: true
```

### Create Elytra Service

Create `/etc/systemd/system/elytra.service`:

```ini
[Unit]
Description=Elytra Daemon
After=docker.service network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/elytra
ExecStart=/usr/local/bin/elytra
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

**Don't start Elytra yet** - we need to configure the node first.

---

## Step 6: SSL/TLS Configuration

### Obtain Certificates

```bash
# For Panel (primary domain)
certbot --nginx -d panel.yourdomain.com --non-interactive --agree-tos --email your@email.com

# For Daemon (optional, can use same certificate or skip if using localhost)
certbot --nginx -d daemon.yourdomain.com --non-interactive --agree-tos --email your@email.com
```

### Elytra SSL Configuration

If using Let's Encrypt for Elytra:

```bash
mkdir -p /etc/elytra
# Use symlinks instead of copies so certificates auto-update on renewal
ln -sf /etc/letsencrypt/live/daemon.yourdomain.com/fullchain.pem /etc/elytra/certificate.pem
ln -sf /etc/letsencrypt/live/daemon.yourdomain.com/privkey.pem /etc/elytra/certificate.key
chown 8888:8888 /etc/elytra/certificate.*
chmod 644 /etc/elytra/certificate.pem
chmod 600 /etc/elytra/certificate.key
```

Update `/etc/elytra/config.yml`:

```yaml
api:
    host: 0.0.0.0
    port: 8080
    ssl:
        enabled: true
        certificate: /etc/elytra/certificate.pem
        key: /etc/elytra/certificate.key
```

### Auto-Renewal Hook

Create `/etc/letsencrypt/renewal-hooks/deploy/combined-restart.sh`:

```bash
cat > /etc/letsencrypt/renewal-hooks/deploy/combined-restart.sh << 'EOF'
#!/bin/bash
echo "[$(date)] Certificate renewed" >> /var/log/hydrodactyl-certbot-renewal.log

# Ensure Elytra certificate symlinks are valid (re-create if needed)
# Symlinks automatically point to latest certs, just need to ensure they exist
if [ -d "/etc/letsencrypt/live/daemon.yourdomain.com" ]; then
    ln -sf /etc/letsencrypt/live/daemon.yourdomain.com/fullchain.pem /etc/elytra/certificate.pem
    ln -sf /etc/letsencrypt/live/daemon.yourdomain.com/privkey.pem /etc/elytra/certificate.key
    chown 8888:8888 /etc/elytra/certificate.*
    chmod 644 /etc/elytra/certificate.pem
    chmod 600 /etc/elytra/certificate.key
    echo "[$(date)] Elytra certificates updated" >> /var/log/hydrodactyl-certbot-renewal.log
fi

systemctl restart nginx
systemctl restart elytra
EOF

chmod +x /etc/letsencrypt/renewal-hooks/deploy/combined-restart.sh
```

---

## Step 7: Configure Firewall

### UFW (Ubuntu/Debian)

```bash
ufw default deny incoming
ufw default allow outgoing

# SSH
ufw allow 22/tcp

# Panel (HTTP/HTTPS)
ufw allow 80/tcp
ufw allow 443/tcp

# Elytra API
ufw allow 8080/tcp

# SFTP (Elytra)
ufw allow 2022/tcp

# Game Server Ports (adjust as needed)
ufw allow 25565:25665/tcp  # Minecraft
ufw allow 25565:25665/udp  # Minecraft
ufw allow 27015:27150/tcp  # Source Engine
ufw allow 27015:27150/udp  # Source Engine

ufw enable
```

### FirewallD (Rocky/AlmaLinux)

```bash
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-port=8080/tcp
firewall-cmd --permanent --add-port=2022/tcp
firewall-cmd --permanent --add-port=25565-25665/tcp
firewall-cmd --permanent --add-port=25565-25665/udp
firewall-cmd --reload
```

---

## Step 8: Create Node and Connect Services

### Create Node in Panel

1. Visit `https://panel.yourdomain.com`
2. Login with admin credentials
3. Go to **Admin** → **Nodes**
4. Click **Create New**
5. Configure:
   - **Name:** `Local Node` or `Main Node`
   - **Location:** Create or select existing
   - **FQDN:** `daemon.yourdomain.com` (or `panel.yourdomain.com` if using same domain)
   - **Behind Proxy:** Check if using Cloudflare
   - **Memory:** Total system RAM minus 2GB for system overhead
   - **Disk:** Total disk space minus 20GB for system overhead

6. Click **Create Node**

### Get Configuration

1. Click on your newly created node
2. Go to **Configuration** tab
3. Copy the `uuid`, `token-id`, and `token` values

### Update Elytra Configuration

Edit `/etc/elytra/config.yml`:

```yaml
uuid: YOUR-COPIED-UUID
token-id: YOUR-COPIED-TOKEN-ID
token: YOUR-COPIED-TOKEN
remote: https://panel.yourdomain.com
```

Save and set permissions:

```bash
chown -R 8888:8888 /etc/elytra
```

### Start Elytra

```bash
systemctl daemon-reload
systemctl enable --now elytra

# Check status
systemctl status elytra

# View logs
journalctl -u elytra -f
```

You should see connection successful messages in the logs.

---

## Verification

### Check All Services

```bash
echo "=== Panel Services ==="
systemctl status nginx | grep Active
systemctl status php8.4-fpm | grep Active
systemctl status mariadb | grep Active
systemctl status hydroq | grep Active

echo "=== Elytra/Docker ==="
systemctl status elytra | grep Active
systemctl status docker | grep Active
docker ps

echo "=== Resources ==="
free -h
df -h /var/lib/elytra
```

### Test Panel Access

- Visit `https://panel.yourdomain.com`
- Login with admin credentials
- Navigate to **Admin** → **Nodes**
- Node should show as **Healthy** (green heart icon)

### Test Elytra Connection

```bash
# From the server
curl -k https://localhost:8080/api/servers 2>/dev/null | head -1

# Should return unauthorized or similar (not connection refused)
```

### Create Test Server

1. In Panel, go to your Node → **Allocations**
2. Create allocation:
   - IP: `0.0.0.0` (listens on all interfaces) or your server IP
   - Port: `25565` (or any available port)
3. Go to **Servers** → **Create New**
4. Select a Nest/Egg (e.g., Minecraft)
5. Select your node and allocation
6. Create and start the server
7. Check logs in Panel - should show server installing and starting

---

## Troubleshooting

### Port Conflicts

**Problem:** Elytra won't start, port 8080 in use

**Solution:** Check what's using port 8080:

```bash
netstat -tlnp | grep 8080
lsof -i :8080

# Change Elytra port in /etc/elytra/config.yml if needed
# Then update Panel node configuration to match
```

### Database Connection Issues

**Problem:** Panel shows database errors

**Solution:**

```bash
# Test connection
mysql -u hydrodactyl -p -h 127.0.0.1 panel -e "SELECT 1"

# Check if MariaDB is bound to localhost
grep bind-address /etc/mysql/mariadb.conf.d/50-server.cnf
# Should be: bind-address = 127.0.0.1
```

### Docker Permission Denied

**Problem:** Elytra can't create containers

**Solution:**

```bash
# Check Docker socket
ls -la /var/run/docker.sock

# Restart Docker
systemctl restart docker

# Check Docker is working
docker run hello-world
```

### Panel Can't Connect to Elytra

**Problem:** Node shows as unhealthy

**Check:**

1. Elytra is running: `systemctl status elytra`
2. Firewall allows port 8080
3. SSL certificate is valid (if using HTTPS)
4. Token values match exactly

**Test from Panel server:**

```bash
curl -v https://daemon.yourdomain.com:8080
# Should get SSL handshake or 401 Unauthorized (not connection refused)
```

### Resource Exhaustion

**Problem:** Server becomes unresponsive

**Check resources:**

```bash
free -h
df -h
docker system df

# Clean up Docker
docker system prune -a

# Check what's consuming resources
docker stats
```

### Swap Not Working

**Problem:** Docker shows "WARNING: No swap limit support"

**Fix:**

```bash
# Check if swap accounting is enabled
cat /proc/cmdline | grep swapaccount

# If not present, enable and reboot
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="swapaccount=1 /' /etc/default/grub
update-grub
reboot
```

---

## Post-Installation

### Enable Automatic Updates (Optional)

Create a weekly update check:

```bash
cat > /etc/cron.weekly/hydrodactyl-update << 'EOF'
#!/bin/bash
# Update check script
# Only run git fetch if this is a git installation
if [ -d /var/www/hydrodactyl/.git ]; then
  cd /var/www/hydrodactyl && git fetch origin
fi
/usr/local/bin/elytra --version
EOF

chmod +x /etc/cron.weekly/hydrodactyl-update
```

### Backup Strategy

Create backup script:

```bash
cat > /usr/local/bin/backup-hydrodactyl << 'EOF'
#!/bin/bash
BACKUP_DIR="/var/backups/hydrodactyl"
DATE=$(date +%Y%m%d_%H%M%S)

mkdir -p $BACKUP_DIR

# Backup database
mysqldump -u root panel > $BACKUP_DIR/panel_$DATE.sql

# Backup Panel files
tar -czf $BACKUP_DIR/panel_files_$DATE.tar.gz -C /var/www hydrodactyl

# Backup Elytra config
tar -czf $BACKUP_DIR/elytra_config_$DATE.tar.gz -C /etc elytra

# Keep only last 7 backups
ls -t $BACKUP_DIR/*.sql | tail -n +8 | xargs -r rm
ls -t $BACKUP_DIR/*.tar.gz | tail -n +8 | xargs -r rm

echo "Backup completed: $DATE"
EOF

chmod +x /usr/local/bin/backup-hydrodactyl
```

Run daily:

```bash
echo "0 2 * * * root /usr/local/bin/backup-hydrodactyl" >> /etc/crontab
```

### Monitoring

Install monitoring tools:

```bash
# Basic monitoring
apt install -y htop iotop nethogs

# Optional: Netdata
bash <(curl -Ss https://my-netdata.io/kickstart.sh)
# Access at http://your-server-ip:19999
```

---

## Support

- Hydrodactyl Issues: <https://github.com/BlueprintFramework/hydrodactyl/issues>
- Wings Issues: <https://github.com/pterodactyl/wings/issues>
- Wings-RS Issues: <https://github.com/calagopus/wings/issues>
- Elytra Issues (legacy): <https://github.com/pyrohost/elytra/issues>
- Docker Docs: <https://docs.docker.com/>
- Community Discord: [Hydrodactyl Community]

---

**Congratulations!** You now have a complete Hydrodactyl Panel and Elytra Daemon installation on a single server. You can begin creating and managing game servers.
