# misc

Small tools and installers for Proxmox VE / Debian homelab nodes. Each tool
lives in its own folder with its own `install.sh` and `README.md`.

| Tool | What it does |
|---|---|
| [backup](backup/) | vzdump hook that uploads host config and backup dumps to an rclone remote after every backup job. |
| [disk-health](disk-health/) | Monitors SMART data of SATA/NVMe disks, runs scheduled short/long self-tests and sends alerts and weekly reports through Proxmox VE notifications. |
| [gpu-passthrough](gpu-passthrough/) | Prepares the host for GPU / Intel iGPU passthrough or Intel GVT-g (split iGPU): kernel options, VFIO modules, driver blacklist. |
| [nut](nut/) | Installs and configures [Network UPS Tools](https://networkupstools.org/) as server or client, so machines shut down cleanly on power loss. |

## Requirements

- Proxmox VE 8/9 or Debian 12+
- Root access on each node
- `curl` to install from GitHub

## Quick start

Run on the node, as root.

### Install several tools at once

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/install.sh)"
```

A checklist lets you pick the tools (Space to select, Enter to install). Each
selected tool then runs its own installer and wizard, one after the other.
A failed tool does not stop the others, and a summary is printed at the end.

Pick tools without the menu:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/install.sh)" install.sh disk-health nut
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/install.sh)" install.sh all
```

`GITHUB_REPO` and `GITHUB_REF` (e.g. a tag) choose where the installers are
downloaded from. From a local checkout, `bash install.sh` uses the files in the
checkout.

### Install one tool

See each tool's README for options and details.

```bash
# Backup hook (asks for the rclone remote path)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/backup/install.sh)"

# Disk Health Monitor
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/disk-health/install.sh)"

# GPU passthrough (interactive wizard: setup / check / uninstall)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/gpu-passthrough/install.sh)"

# NUT (interactive wizard: server / client / uninstall)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/nut/install.sh)"
```

From a local checkout: `bash nut/install.sh` and `bash gpu-passthrough/install.sh` work as-is. `disk-health/install.sh`
always downloads its files from GitHub, so use the manual install steps in
[disk-health/README.md](disk-health/README.md#manual-install-without-github) instead.

> **Security note:** these scripts run as root. Only pipe them from a repo you
> own or trust, and prefer pinning a tag or commit instead of `main`.

## Layout

```
.
├── install.sh         installer for all tools (pick from a menu)
├── backup/            vzdump hook script + installer (rclone upload)
├── disk-health/       SMART monitor script, systemd services/timers, installer
├── gpu-passthrough/   GPU / iGPU / GVT-g passthrough host setup
└── nut/               NUT installer for UPS server/client
```
