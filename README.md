# misc

Small tools and installers for homelab machines (Debian / Ubuntu, Proxmox VE
and Synology DSM). Each tool lives in its own folder with its own `install.sh` and
`README.md`.

| Tool | Platform | What it does |
|---|---|---|
| [backup](backup/) | Proxmox | vzdump hook that uploads host config and backup dumps to an rclone remote after every backup job. |
| [cpupower](cpupower/) | Debian / Ubuntu / Proxmox | Installs `cpupower`, lets you pick a CPU governor the CPU supports and sets it at every boot with a systemd service. |
| [disk-health](disk-health/) | Proxmox | Monitors SMART data of SATA/NVMe disks, runs scheduled short/long self-tests and sends alerts and weekly reports through Proxmox VE notifications. |
| [docker-wait-disks](docker-wait-disks/) | OpenMediaVault | Makes Docker wait at boot for every shared folder (and any extra paths) to exist on a mounted disk, and stay down if one is not ready. |
| [ffmpeg-static](ffmpeg-static/) | Debian / Ubuntu / Proxmox / OMV | Downloads a static `ffmpeg` / `ffprobe` build (FFmpeg-Builds with VA-API, QSV, NVENC, or johnvansickle.com) to `/usr/local/bin`, checksum-verified, updated by running it again. |
| [gpu-drivers](gpu-drivers/) | Debian / Proxmox / OMV | Intel media driver (VA-API / QSV, HuC firmware) and NVIDIA driver (NVIDIA's CUDA repo or Debian, DKMS), with Docker toolkit and LXC device nodes. |
| [gpu-passthrough](gpu-passthrough/) | Proxmox | Prepares the host for GPU / Intel iGPU passthrough or Intel GVT-g (split iGPU): kernel options, VFIO modules, driver blacklist. |
| [pcie-passthrough](pcie-passthrough/) | Proxmox | Dell Wyse 5070: passes the card in the PCIe slot (NIC like Intel i226, or GPU) to a VM: IOMMU, ACS override, vfio-pci binding with D3 idle off. |
| [ipset](ipset/) | Debian / Ubuntu / Proxmox (UFW) | Blocks known-bad IPs from [stamparm/ipsum](https://github.com/stamparm/ipsum) with an ipset and UFW rules. Restored at boot, updated daily. |
| [nut](nut/) | Debian / Ubuntu / Proxmox | Installs and configures [Network UPS Tools](https://networkupstools.org/) as server or client, so machines shut down cleanly on power loss. |
| [turbo-unlock](turbo-unlock/) | Debian / Ubuntu / Proxmox | Clears the BIOS turbo lock (MSR `0x1a0` bit 38) at every boot, e.g. Dell Wyse 5070 stuck at 1.5 GHz. |
| [omv-shared-symlinks](omv-shared-symlinks/) | OpenMediaVault | Keeps a `/shared/<name>` symlink for every shared folder with a Salt state, so paths do not depend on disk UUIDs. |
| [omv-telegram](omv-telegram/) | OpenMediaVault | Sends every OMV notification (alerts, SMART, RAID, cron, logins) to a Telegram chat through a bot, with a notification sink script. |
| [winpe-grub](winpe-grub/) | Debian / Ubuntu / Proxmox | Adds a small WinPE ISO (Windows ADK, PhoenixPE, Windows install ISO) to the GRUB menu and boots it from disk through wimboot. |
| [synology-acme](synology-acme/) | Synology | Installs acme.sh, issues a certificate through a DNS API (Let's Encrypt / ZeroSSL) and deploys it to DSM. |

## Requirements

- Debian 12+ / Ubuntu 22.04+, Proxmox VE 8/9, OpenMediaVault 7, or Synology DSM 7
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
| Ubuntu | cpupower, ffmpeg-static, ipset, nut, turbo-unlock, winpe-grub |
| Debian | the above + gpu-drivers |
| Proxmox VE | the Debian tools + backup, disk-health, gpu-passthrough, pcie-passthrough |
| OpenMediaVault | the Debian tools + docker-wait-disks, omv-shared-symlinks, omv-telegram |
| Synology DSM | synology-acme |

A menu lists the tools. Tools that only run on one OS show it in front of their
description, such as `[Debian]`, `[Proxmox]`, `[OMV]` or `[Synology]`. Picking one runs its own wizard (install / check /
uninstall, depending on the tool), then you are back in the menu to run another.
"Install several tools at once" opens a checklist (Space to select, Enter to
install) and runs the selected installers one after the other. A failed tool
does not stop the others, and a summary is printed when you quit.

Pick tools without the menu:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/install.sh)" install.sh nut cpupower
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

# Disk Health Monitor (Proxmox VE, alerts through PVE notifications)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/disk-health/install.sh)"

# OpenMediaVault: Docker waits for every shared folder at boot
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/docker-wait-disks/install.sh)"

# Static ffmpeg + ffprobe in /usr/local/bin (interactive wizard: install / check / uninstall)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/ffmpeg-static/install.sh)"

# Intel media driver + NVIDIA driver (interactive wizard: install / check / uninstall)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/gpu-drivers/install.sh)"

# GPU passthrough (interactive wizard: setup / check / uninstall)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/gpu-passthrough/install.sh)"

# PCIe slot passthrough on the Dell Wyse 5070 (interactive wizard: setup / check / uninstall)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/pcie-passthrough/install.sh)"

# ipset blacklist for UFW (needs UFW installed)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/ipset/install.sh)"

# NUT (interactive wizard: server / client / uninstall)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/nut/install.sh)"

# /shared/<name> symlinks for the OpenMediaVault shared folders (asks for the directory)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/omv-shared-symlinks/install.sh)"

# OpenMediaVault notifications to Telegram (asks for the bot token and chat ID)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/omv-telegram/install.sh)"

# WinPE ISO in the GRUB menu (asks for the ISO; boot.wim must be under ~800 MB)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/winpe-grub/install.sh)"

# acme.sh for Synology DSM (run on the NAS after sudo -i)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/synology-acme/install.sh)"
```

From a local checkout: `bash nut/install.sh`, `bash gpu-passthrough/install.sh` and `bash pcie-passthrough/install.sh` work as-is. `disk-health/install.sh`
always downloads its files from GitHub, so use the manual install steps in
[disk-health/README.md](disk-health/README.md#manual-install-without-github) instead.

> **Security note:** these scripts run as root. Only pipe them from a repo you
> own or trust, and prefer pinning a tag or commit instead of `main`.

## Layout

```
.
├── install.sh           installer for all tools (pick from a menu)
├── backup/              vzdump hook script + installer (rclone upload)
├── cpupower/            CPU governor at boot (systemd service)
├── disk-health/         SMART monitor script, systemd services/timers, installer
├── docker-wait-disks/   OMV: Docker waits for the shared folders at boot (systemd service)
├── ffmpeg-static/       static ffmpeg / ffprobe build in /usr/local/bin
├── gpu-drivers/         Intel VA-API / QSV + NVIDIA driver (DKMS) for the host
├── gpu-passthrough/     GPU / iGPU / GVT-g passthrough host setup
├── ipset/               UFW IP blacklist (ipsum) with boot restore and daily update
├── nut/                 NUT installer for UPS server/client
├── omv-shared-symlinks/ /shared/<name> symlinks for OMV shared folders (Salt state)
├── omv-telegram/        OMV notifications to Telegram (notification sink script)
├── pcie-passthrough/    Dell Wyse 5070 PCIe slot passthrough (vfio-pci, ACS, D3 fix)
├── synology-acme/       acme.sh installer for Synology DSM
├── turbo-unlock/        BIOS turbo lock fix at boot (systemd service)
└── winpe-grub/          WinPE ISO in the GRUB menu via wimboot
```
