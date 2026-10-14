# Wings Daemon - Manual Installation Guide

This guide provides step-by-step instructions for manually installing the Wings daemon (or its Rust reimplementation, wings-rs) on your game server nodes. Wings is the current, recommended game server management daemon that communicates with the Hydrodactyl Panel and manages Docker containers for game servers. It replaces the legacy [Elytra daemon](./elytra-manual.md).

## Table of Contents

1. [System Requirements](#system-requirements)
2. [Choosing a Variant: Wings (Go) vs wings-rs (Rust)](#choosing-a-variant-wings-go-vs-wings-rs-rust)
3. [Prerequisites](#prerequisites)
4. [Step 1: System Updates](#step-1-system-updates)
5. [Step 2: Install Docker](#step-2-install-docker)
6. [Step 3: Create the pterodactyl System User](#step-3-create-the-pterodactyl-system-user)
7. [Step 4: Download and Install Wings](#step-4-download-and-install-wings)
8. [Step 5: Create a Node in the Panel](#step-5-create-a-node-in-the-panel)
9. [Step 6: Configure Wings](#step-6-configure-wings)
10. [Step 7: Configure SSL/TLS](#step-7-configure-ssltls)
11. [Step 8: Systemd Service](#step-8-systemd-service)
12. [Step 9: Firewall Configuration](#step-9-firewall-configuration)
13. [Verification](#verification)
14. [Troubleshooting](#troubleshooting)
15. [Maintenance](#maintenance)

---

## System Requirements

### Minimum Requirements

| Component | Specification |
| ----------- | -------------- |
| **CPU** | 2 cores (x86_64 or ARM64) |
| **RAM** | 2 GB |
| **Storage** | 20 GB SSD |
| **Network** | Public IPv4 or IPv6 |
| **OS** | Ubuntu 22.04/24.04, Debian 11/12, Rocky Linux 8/9, AlmaLinux 8/9 |
| **Virtualization** | KVM, VMware, Xen, or bare metal (OpenVZ/LXC **not supported**) |

### Recommended Requirements

| Component | Specification |
| ----------- | -------------- |
| **CPU** | 4+ cores |
| **RAM** | 4+ GB |
| **Storage** | 50+ GB SSD |
| **Network** | Both IPv4 and IPv6 |

### Important: Docker Compatibility

Wings requires Docker to run game servers in isolated containers. Before proceeding, verify your virtualization supports Docker:

```bash
systemd-detect-virt
```

**Supported:** `none`, `kvm`, `vmware`, `xen`, `microsoft`
**Not Supported:** `openvz`, `lxc`, `lxc-libvirt`

---

## Choosing a Variant: Wings (Go) vs wings-rs (Rust)

| | Wings (Go) | wings-rs (Rust) |
| --- | --- | --- |
| **Repository** | `pterodactyl/wings` | `calagopus/wings` |
| **Maturity** | Official, most widely used, battle-tested in production | Lightweight reimplementation, additional features |
| **Resource usage** | Standard | Lower memory usage, faster startup |
| **Best for** | Production environments, maximum compatibility | Resource-constrained servers, advanced users |

Both variants speak the same Wings protocol and are configured identically from the panel's point of view - the only difference is which binary you download in [Step 4](#step-4-download-and-install-wings). If you're unsure, use Wings (Go).

---

## Prerequisites

Before beginning:

- Root access to a dedicated server or VPS
- A domain name or subdomain pointing to this server (e.g. `node.yourdomain.com`), or its public IP
- A running Hydrodactyl Panel you can connect this node to
- Basic understanding of Docker and Linux
- Server must support Docker (KVM/VMware/Xen - NOT OpenVZ/LXC)

---

## Step 1: System Updates

```bash
apt update && apt upgrade -y  # Ubuntu/Debian
dnf update -y                 # Rocky/AlmaLinux
```

---

## Step 2: Install Docker

### Ubuntu

```bash
apt install -y apt-transport-https ca-certificates curl gnupg lsb-release

mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

### Debian

```bash
apt install -y apt-transport-https ca-certificates curl gnupg lsb-release

mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

### Rocky Linux/AlmaLinux

```bash
dnf install -y yum-utils
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

### Start Docker

```bash
systemctl enable --now docker
docker --version
```

---

## Step 3: Create the pterodactyl System User

The `wings` systemd service itself runs as `root` (see [Step 8](#step-8-systemd-service)) - it does not drop privileges. This dedicated `pterodactyl` system user/group (UID/GID 9999) exists only so it can be added to the `docker` group and used to own game server volumes/files on disk; create it now so it's in place before Wings starts managing containers:

```bash
groupadd --gid 9999 pterodactyl 2>/dev/null || true

useradd --system --no-create-home --shell /usr/sbin/nologin --uid 9999 --gid 9999 pterodactyl 2>/dev/null || \
useradd --system --no-create-home --shell /sbin/nologin --uid 9999 --gid 9999 pterodactyl 2>/dev/null || \
useradd --system --no-create-home --shell /bin/false --uid 9999 --gid 9999 pterodactyl

usermod -aG docker pterodactyl
```

---

## Step 4: Download and Install Wings

Use these paths for a new install. They sit beside Pelican (`/etc/pelican` and `/usr/local/bin/wings`) and beside an older Hydrodactyl Wings install (`/etc/pterodactyl` and `wings.service`). An existing Hydrodactyl install keeps those original paths until you choose migration from the installer menu. Do not download a new binary over `/usr/local/bin/wings` when that file belongs to another panel.

### Create Directories

```bash
mkdir -p /etc/hydrodactyl/wings
mkdir -p /var/lib/hydrodactyl/wings/volumes /var/lib/hydrodactyl/wings/archives /var/lib/hydrodactyl/wings/backups
```

You don't need to `chown`/`chmod` these directories by hand: Wings runs as `root` and, by default, `check_permissions_on_boot: true` in its config makes it fix ownership and permissions on `/var/lib/hydrodactyl/wings/*` itself the first time it starts (Step 8). If you later disable that setting for faster boots, set ownership/permissions once yourself first:

```bash
chown -R 9999:9999 /var/lib/hydrodactyl/wings/volumes /var/lib/hydrodactyl/wings/archives /var/lib/hydrodactyl/wings/backups /etc/hydrodactyl/wings
chmod 755 /var/lib/hydrodactyl/wings
chmod -R 777 /var/lib/hydrodactyl/wings/volumes /var/lib/hydrodactyl/wings/archives /var/lib/hydrodactyl/wings/backups
chmod 755 /etc/hydrodactyl/wings
```

### Download the Binary

Pick the block matching the variant you chose in [Choosing a Variant](#choosing-a-variant-wings-go-vs-wings-rs-rust):

**Wings (Go):**

```bash
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
curl -Lo /usr/local/bin/hydrodactyl-wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${ARCH}"
chmod +x /usr/local/bin/hydrodactyl-wings
```

**wings-rs (Rust):**

```bash
ARCH=$(uname -m)  # keeps x86_64 / aarch64 as-is
curl -Lo /usr/local/bin/hydrodactyl-wings "https://github.com/calagopus/wings/releases/latest/download/wings-rs-${ARCH}-linux"
chmod +x /usr/local/bin/hydrodactyl-wings
```

### Verify the Binary

```bash
/usr/local/bin/hydrodactyl-wings --version
```

### Record the Installed Version

The panel/auto-updater tooling tracks the installed version via this file. Capture the release tag you actually downloaded (e.g. `v1.11.13`) rather than typing a placeholder:

```bash
# Replace pterodactyl/wings with calagopus/wings if you installed wings-rs
WINGS_TAG=$(curl -sL https://api.github.com/repos/pterodactyl/wings/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

mkdir -p /etc/hydrodactyl
echo "$WINGS_TAG" > /etc/hydrodactyl/wings-version
chmod 644 /etc/hydrodactyl/wings-version
```

---

## Step 5: Create a Node in the Panel

1. Visit your panel, e.g. `https://panel.yourdomain.com`
2. Login with admin credentials
3. Go to **Admin** → **Nodes** → **Create New**
4. Configure:
   - **Name:** e.g. `Wings-Node-1`
   - **Location:** Create or select existing
   - **FQDN:** `node.yourdomain.com` (or this server's IP)
   - **Behind Proxy:** Check if using Cloudflare
   - **Memory / Disk:** Total system resources minus overhead for the OS
5. Click **Create Node**
6. Open the new node → **Configuration** tab and copy the auto-deploy command, or note the `--panel-url`, `--token`, and `--node` values shown there - you'll need them in the next step

---

## Step 6: Configure Wings

Unlike the legacy Elytra daemon (which requires hand-editing a YAML config with placeholder credentials), Wings ships a `configure` subcommand that writes `/etc/hydrodactyl/wings/config.yml` for you directly from the node's deploy credentials:

```bash
mkdir -p /etc/hydrodactyl/wings
/usr/local/bin/hydrodactyl-wings --config /etc/hydrodactyl/wings/config.yml configure \
  --panel-url "https://panel.yourdomain.com" \
  --token "<token-from-panel>" \
  --node "<node-id>"
```

Pass `--config` for both the Go and Rust variants. wings-rs otherwise searches `/etc/pelican/config.yml` and `/etc/pterodactyl/config.yml` and can load another panel's file. Re-run the same command any time you need to reconfigure or point Wings at a different panel/node.

`wings configure` still writes the upstream data directories and the `pterodactyl_nw` network. The installer rewrites those to the Hydrodactyl paths after configure. On a manual install, change `root_directory`, `data`, the log, archive, backup, and temporary directories, and the Docker network to the Hydrodactyl values before starting the service.

A new install inspects the Docker networks already on the machine and then uses `hydrodactyl_nw` on `172.22.0.0/16`, or the next free range through `172.31.0.0/16`, including the paired IPv6 prefix. It also stays off `172.17.0.0/16` through `172.21.0.0/16`. If Docker cannot be queried, installation stops instead of guessing that a subnet is free. The API port stays `8080` and SFTP stays `2022`.

---

## Step 7: Configure SSL/TLS

If this node has its own FQDN pointing at it, obtain a Let's Encrypt certificate:

**Ubuntu/Debian:**

```bash
apt install -y certbot
```

**Rocky Linux/AlmaLinux:**

```bash
dnf install -y certbot
```

**Then, on any OS:**

```bash
certbot certonly --standalone -d node.yourdomain.com --non-interactive --agree-tos --email your@email.com
```

Enable SSL and point Wings at the certificate:

```bash
sed -i '/ssl:/,/certificate:/{s/enabled: false/enabled: true/}' /etc/hydrodactyl/wings/config.yml
sed -i "s|certificate: .*|certificate: /etc/letsencrypt/live/node.yourdomain.com/fullchain.pem|" /etc/hydrodactyl/wings/config.yml
sed -i "s|key: .*|key: /etc/letsencrypt/live/node.yourdomain.com/privkey.pem|" /etc/hydrodactyl/wings/config.yml
```

### Auto-Renewal Hook

```bash
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/wings-restart.sh << 'EOF'
#!/bin/bash
echo "[$(date)] Certificate renewed, restarting Wings..." >> /var/log/hydrodactyl-certbot-renewal.log
systemctl restart hydrodactyl-wings 2>/dev/null && echo "[$(date)] hydrodactyl-wings restarted successfully" >> /var/log/hydrodactyl-certbot-renewal.log
EOF

chmod +x /etc/letsencrypt/renewal-hooks/deploy/wings-restart.sh
```

If you don't have a per-node FQDN (e.g. this node shares the panel's certificate or is only reachable by IP), you can skip SSL and rely on the panel connecting behind a reverse proxy instead.

---

## Step 8: Systemd Service

Create `/etc/systemd/system/hydrodactyl-wings.service`:

```ini
[Unit]
Description=Hydrodactyl Wings Daemon
Documentation=https://github.com/pterodactyl/wings
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
User=root
Group=root
WorkingDirectory=/etc/hydrodactyl/wings
LimitNOFILE=4096
PIDFile=/run/hydrodactyl-wings.pid
ExecStart=/usr/local/bin/hydrodactyl-wings --config /etc/hydrodactyl/wings/config.yml
ExecStop=/bin/kill -s QUIT $MAINPID
ExecReload=/bin/kill -s HUP $MAINPID
Restart=on-failure
RestartSec=5s
StartLimitInterval=60s
StartLimitBurst=3

[Install]
WantedBy=multi-user.target
```

Enable and start it:

```bash
systemctl daemon-reload
systemctl enable --now hydrodactyl-wings

systemctl status hydrodactyl-wings
journalctl -u hydrodactyl-wings -f
```

---

## Step 9: Firewall Configuration

### UFW (Ubuntu/Debian)

```bash
ufw allow 22/tcp          # SSH
ufw allow 80/tcp          # HTTP (certbot renewal)
ufw allow 443/tcp         # HTTPS
ufw allow 8080/tcp        # Wings API
ufw allow 2022/tcp        # SFTP

# Game server ports (adjust as needed)
ufw allow 25565:25665/tcp  # Minecraft
ufw allow 25565:25665/udp
ufw allow 27015:27150/tcp  # Source Engine
ufw allow 27015:27150/udp

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

## Verification

### Check Wings Status

```bash
systemctl status hydrodactyl-wings
journalctl -u hydrodactyl-wings -f
```

### Check the API

```bash
# If you enabled SSL in Step 7, use https; otherwise use http
curl -k https://localhost:8080/api/system   # SSL enabled
curl http://localhost:8080/api/system       # SSL not configured
# Should return JSON, not "connection refused"
```

### Check in the Panel

- Go to **Admin** → **Nodes** in the panel
- Your node should show as **Healthy** (green heart icon)
- If it's unhealthy, see [Troubleshooting](#troubleshooting) below

### Create a Test Server

1. In the panel, go to your Node → **Allocations** and create one (e.g. IP `0.0.0.0`, port `25565`)
2. Go to **Servers** → **Create New**, select a Nest/Egg (e.g. Minecraft), your node, and the allocation
3. Create and start the server - it should install and start successfully

---

## Troubleshooting

### Wings Won't Start

```bash
journalctl -u wings -n 50
```

Common causes:

- Docker isn't running: `systemctl start docker`
- Config file missing/invalid: `cat /etc/hydrodactyl/wings/config.yml`
- Port 8080 already in use: `ss -tlnp | grep 8080`

### Node Shows as Unhealthy in the Panel

**Check:**

1. Wings is running: `systemctl status hydrodactyl-wings`
2. Firewall allows port 8080
3. SSL certificate is valid (if using HTTPS)
4. Token/node values in `/etc/hydrodactyl/wings/config.yml` match what the panel expects

**Test from the panel server:**

```bash
# If you enabled SSL in Step 7, use https; otherwise use http
curl -v https://node.yourdomain.com:8080   # SSL enabled
curl -v http://node.yourdomain.com:8080    # SSL not configured
# Should get an SSL handshake (https) or 401 Unauthorized, not "connection refused"
```

### Docker Permission Denied

```bash
ls -la /var/run/docker.sock
systemctl restart docker
docker run hello-world
```

### Reconfiguring Wings

If you need to point Wings at a different panel/node, or the config gets corrupted, just re-run the configure command from [Step 6](#step-6-configure-wings):

```bash
/usr/local/bin/hydrodactyl-wings --config /etc/hydrodactyl/wings/config.yml configure --panel-url "https://panel.yourdomain.com" --token "<token>" --node "<node-id>"
systemctl restart hydrodactyl-wings
```

---

## Maintenance

### Updating Wings

Stop Wings, download the new binary over the old one, then restart. Use the block matching the variant you actually installed in [Step 4](#step-4-download-and-install-wings). An install that still uses `/usr/local/bin/wings` and `wings.service` is updated in those same places; the installer menu follows the saved layout.

**Wings (Go):**

```bash
systemctl stop hydrodactyl-wings

ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
curl -Lo /usr/local/bin/hydrodactyl-wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${ARCH}"
chmod +x /usr/local/bin/hydrodactyl-wings

systemctl start hydrodactyl-wings
systemctl status hydrodactyl-wings
```

**wings-rs (Rust):**

```bash
systemctl stop hydrodactyl-wings

ARCH=$(uname -m)  # keeps x86_64 / aarch64 as-is
curl -Lo /usr/local/bin/hydrodactyl-wings "https://github.com/calagopus/wings/releases/latest/download/wings-rs-${ARCH}-linux"
chmod +x /usr/local/bin/hydrodactyl-wings

systemctl start hydrodactyl-wings
systemctl status hydrodactyl-wings
```

For a version-pinned, backed-up, health-checked update instead of this manual process, use the automated installer's on-demand "Update Wings Daemon" menu option, or run `installers/auto-update-wings.sh` directly.

### Backups

Wings data directories (`/var/lib/hydrodactyl/wings/volumes`, `/archives`, `/backups`) hold live game server data and should be included in your regular server backup strategy. The panel additionally supports the `rustic_local` backup driver for per-server backups managed through the panel UI.

---

## Support

- Wings Issues: <https://github.com/pterodactyl/wings/issues>
- Wings-RS Issues: <https://github.com/calagopus/wings/issues>
- Hydrodactyl Issues: <https://github.com/BlueprintFramework/hydrodactyl/issues>
- Docker Docs: <https://docs.docker.com/>

---

**Congratulations!** Your Wings daemon is now installed, configured, and connected to your Hydrodactyl Panel. You can begin creating and managing game servers.
