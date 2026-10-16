# misc

Small tools and installers for homelab machines (Debian / Ubuntu, Proxmox VE
and Synology DSM). Each tool lives in its own folder with its own `install.sh` and
`README.md`.

| Tool | Platform | What it does |
|---|---|---|
| [backup](backup/) | Proxmox | vzdump hook that uploads host config and backup dumps to an rclone remote after every backup job. |
| [cpupower](cpupower/) | Debian / Ubuntu / Proxmox | Installs `cpupower`, lets you pick a CPU governor the CPU supports and sets it at every boot with a systemd service. |
| [disk-health](disk-health/) | Debian / Ubuntu / Proxmox | Monitors SMART data of SATA/NVMe disks, runs scheduled short/long self-tests and mails alerts and weekly reports (through Proxmox VE notifications on Proxmox). |
| [gpu-passthrough](gpu-passthrough/) | Proxmox | Prepares the host for GPU / Intel iGPU passthrough or Intel GVT-g (split iGPU): kernel options, VFIO modules, driver blacklist. |
| [ipset](ipset/) | Debian / Ubuntu / Proxmox (UFW) | Blocks known-bad IPs from [stamparm/ipsum](https://github.com/stamparm/ipsum) with an ipset and UFW rules. Restored at boot, updated daily. |
| [nut](nut/) | Debian / Ubuntu / Proxmox | Installs and configures [Network UPS Tools](https://networkupstools.org/) as server or client, so machines shut down cleanly on power loss. |
| [turbo-unlock](turbo-unlock/) | Debian / Ubuntu / Proxmox | Clears the BIOS turbo lock (MSR `0x1a0` bit 38) at every boot, e.g. Dell Wyse 5070 stuck at 1.5 GHz. |
| [synology-acme](synology-acme/) | Synology | Installs acme.sh, issues a certificate through a DNS API (Let's Encrypt / ZeroSSL) and deploys it to DSM. |

## Requirements

- Debian 12+ / Ubuntu 22.04+, Proxmox VE 8/9, or Synology DSM 7
- Root access (`sudo -i`)
- `curl` to install from GitHub

## Quick start

Run on the machine, as root.

### Install several tools at once

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/install.sh)"
```

The installer detects the machine and only offers the tools for it:

| Machine | Tools offered |
|---|---|
| Debian / Ubuntu | cpupower, disk-health, ipset, nut, turbo-unlock |
| Proxmox VE | the above + backup, gpu-passthrough |
| Synology DSM | synology-acme |

A checklist lets you pick the tools (Space to select, Enter to install). Each
selected tool then runs its own installer and wizard, one after the other.
A failed tool does not stop the others, and a summary is printed at the end.

Pick tools without the menu:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/install.sh)" install.sh disk-health nut
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/install.sh)" install.sh all
```

From a local checkout, `bash install.sh` uses the files in the checkout.

### Install one tool

See each tool's README for options and details.

```bash
# Backup hook (asks for the rclone remote path)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/backup/install.sh)"

# CPU governor at boot (lists the governors your CPU supports)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/cpupower/install.sh)"

# Turbo unlock (Dell Wyse 5070 stuck at 1.5 GHz)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/turbo-unlock/install.sh)"

# Disk Health Monitor
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/disk-health/install.sh)"

# GPU passthrough (interactive wizard: setup / check / uninstall)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/gpu-passthrough/install.sh)"

# ipset blacklist for UFW (needs UFW installed)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/ipset/install.sh)"

# NUT (interactive wizard: server / client / uninstall)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/nut/install.sh)"

# acme.sh for Synology DSM (run on the NAS after sudo -i)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/synology-acme/install.sh)"
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
├── cpupower/          CPU governor at boot (systemd service)
├── disk-health/       SMART monitor script, systemd services/timers, installer
├── gpu-passthrough/   GPU / iGPU / GVT-g passthrough host setup
├── ipset/             UFW IP blacklist (ipsum) with boot restore and daily update
├── nut/               NUT installer for UPS server/client
├── synology-acme/     acme.sh installer for Synology DSM
└── turbo-unlock/      BIOS turbo lock fix at boot (systemd service)
```
