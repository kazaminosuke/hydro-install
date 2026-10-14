# Hydrodactyl Manual Installation Guides

This directory contains comprehensive manual installation guides for Hydrodactyl Panel and the Wings/wings-rs daemon (with legacy Elytra guides also available). These guides are designed for users who prefer to install and configure each component manually, or for those who want to understand the installation process in detail.

> **New installations should use Wings or wings-rs.** Elytra is no longer maintained upstream and is deprecated - see the root [README's Elytra Support Notice](../README.md). The Elytra and "Both Same Machine" guides below remain available for maintaining existing legacy installations.

## 📚 Available Guides

| Guide | Description | Use Case |
| ------- | ------------- | ---------- |
| [Hydrodactyl Panel Manual](./hydrodactyl-panel-manual.md) | Complete standalone Panel installation | Control panel only, separate from game servers |
| [Wings Daemon Manual](./wings-manual.md) | Complete standalone Wings/wings-rs installation | Game server node only, connects to existing Panel (**recommended for new nodes**) |
| [Elytra Daemon Manual](./elytra-manual.md) (legacy) | Complete standalone legacy Daemon installation | Maintaining an existing legacy Elytra node |
| [Both Same Machine](./both-same-machine.md) (legacy) | Combined Panel + legacy Elytra installation | Single-server setup using the legacy daemon |

## 🤔 Which Guide Should I Use?

### Use the **Panel Only** guide if

- You want a dedicated control panel server
- You plan to have multiple game server nodes
- You're setting up a distributed architecture
- You already have a daemon installed elsewhere

### Use the **Wings Daemon** guide if

- You already have a Hydrodactyl Panel running
- You're adding a new game server node
- You want dedicated game server hardware
- You're expanding an existing setup

### Use the **Elytra Only** guide (legacy) if

- You're maintaining an existing legacy Elytra node
- You are not setting up a new installation

### Use the **Both Same Machine** guide (legacy) if

- You're maintaining an existing single-server legacy Elytra deployment
- For a **new** single-server setup, combine the [Panel Manual](./hydrodactyl-panel-manual.md) with the [Wings Manual](./wings-manual.md) instead, or use the automated installer's "Install both Panel and Wings" option

## 🔄 Manual vs Automated Installer

We also provide an [automated installer](../install.sh) that can:

- Install everything with a single command
- Automatically configure all components
- Set up SSL certificates
- Configure firewalls
- Verify installations

**Use the automated installer if you:**

- Want a quick, one-command installation
- Are setting up a standard configuration
- Prefer automated configuration

**Use these manual guides if you:**

- Want to learn how each component works
- Need custom configurations
- Are troubleshooting an existing installation
- Want to install components separately
- Are using non-standard environments

## ⚙️ Prerequisites for All Guides

Before starting any manual installation, ensure you have:

- **Root access** to a fresh Linux server (Ubuntu 22.04+, Debian 11+, Rocky Linux 8+, or AlmaLinux 8+)
- **Domain name(s)** pointed to your server IP(s)
- **Server specifications** meeting minimum requirements:
  - Panel Only: 2 cores, 2GB RAM, 20GB SSD
  - Wings Only: 2 cores, 2GB RAM, 20GB SSD
  - Elytra Only (legacy): 2 cores, 2GB RAM, 20GB SSD
  - Both Same Machine (legacy): 4 cores, 4GB RAM, 50GB SSD
- **Supported virtualization** (KVM, VMware, Xen - OpenVZ/LXC not supported for Wings or Elytra)

## 🔧 Common Configuration

All installations require:

- MariaDB (MySQL) database server
- Redis cache server
- Nginx web server
- PHP 8.4 with required extensions
- SSL/TLS certificates (Let's Encrypt recommended)

Wings/Wings-RS and Elytra additionally require:

- Docker Engine
- Swap accounting enabled (for game server containers)

## 🆘 Getting Help

If you encounter issues with manual installation:

1. **Check the Troubleshooting section** in the specific guide
2. **Review logs**: `journalctl -u <service>` for systemd services
3. **Check our GitHub Issues**:
   - [Hydrodactyl Issues](https://github.com/BlueprintFramework/hydrodactyl/issues)
   - [Wings Issues](https://github.com/pterodactyl/wings/issues)
   - [Wings-RS Issues](https://github.com/calagopus/wings/issues)
   - [Elytra Issues (legacy)](https://github.com/pyrohost/elytra/issues)
4. **Community Support**: Join our Discord community

## 📖 Guide Structure

Each manual guide follows this structure:

1. **System Requirements** - Hardware and software prerequisites
2. **Step-by-Step Instructions** - Detailed commands and configurations
3. **Verification Steps** - How to confirm everything works
4. **Troubleshooting** - Common issues and solutions
5. **Post-Installation** - Recommended next steps and maintenance

## 🎓 Learning Path

New to Hydrodactyl? Follow this path:

1. **Start with the [Panel Manual](./hydrodactyl-panel-manual.md) and [Wings Manual](./wings-manual.md)** - Get Panel and Wings running (or use the automated installer's "Install both Panel and Wings" option for a quicker start)
2. **Experiment and learn** - Understand how components interact
3. **Read individual guides** - Dive deeper into each component
4. **Plan your architecture** - Decide if you need separate servers
5. **Scale up** - Use separate guides for production deployment

## 📝 Contributing

Found an error in a guide? Want to improve documentation?

- Submit a PR to the [hydrodactyl-installer repository](https://github.com/itzzjustmateo/hydro-install)
- Report issues via GitHub Issues
- Suggest improvements based on your experience

## 🔗 Quick Links

- [Main Installer](../install.sh) - Automated one-command installer
- [Panel Guide](./hydrodactyl-panel-manual.md) - Panel-only installation
- [Wings Guide](./wings-manual.md) - Daemon-only installation (recommended)
- [Elytra Guide](./elytra-manual.md) (legacy) - Legacy daemon-only installation
- [Combined Guide](./both-same-machine.md) (legacy) - Panel + legacy Elytra on same server

---

**Happy hosting!** 🎮🚀
