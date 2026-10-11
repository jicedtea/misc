# misc

Small tools and installers for Proxmox VE / Debian homelab nodes. Each tool
lives in its own folder with its own `install.sh` and `README.md`.

| Tool | What it does |
|---|---|
| [disk-health](disk-health/) | Monitors SMART data of SATA/NVMe disks, runs scheduled short/long self-tests and sends alerts and weekly reports through Proxmox VE notifications. |
| [nut](nut/) | Installs and configures [Network UPS Tools](https://networkupstools.org/) as server or client, so machines shut down cleanly on power loss. |

## Requirements

- Proxmox VE 8/9 or Debian 12+
- Root access on each node
- `curl` or `wget` to install from GitHub

## Quick start

Run on the node, as root. See each tool's README for options and details.

```bash
# Disk Health Monitor
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/disk-health/install.sh)"

# NUT (interactive wizard: server / client / uninstall)
wget -qO- https://raw.githubusercontent.com/jicedtea/misc/main/nut/install.sh | bash
```

From a local checkout: `bash nut/install.sh` works as-is. `disk-health/install.sh`
always downloads its files from GitHub, so use the manual install steps in
[disk-health/README.md](disk-health/README.md#manual-install-without-github) instead.

> **Security note:** these scripts run as root. Only pipe them from a repo you
> own or trust, and prefer pinning a tag or commit instead of `main`.

## Layout

```
.
├── disk-health/   SMART monitor script, systemd services/timers, installer
└── nut/           NUT installer for UPS server/client
```
