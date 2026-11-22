# gpu-drivers

Installs the Intel media driver (VA-API / Quick Sync) and the NVIDIA driver on
Debian 12 / 13, Proxmox VE 8 / 9 and OpenMediaVault, e.g. for hardware
transcoding in Jellyfin / Plex / Frigate, or to share the GPU with LXC and Docker
containers.

## Install

Run on the machine, as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/gpu-drivers/install.sh)"
```

The wizard lists the Intel and NVIDIA GPUs it finds, asks what to install, shows
a summary and asks before changing anything. Run it again to update or change
the options. The previous choices are the defaults.

```
==> GPUs on this machine (Proxmox VE 9.1 (Debian GNU/Linux 13 (trixie)))
    00:02.0  VGA compatible controller: Intel Corporation Alder Lake-N [UHD Graphics]  driver=i915
    01:00.0  VGA compatible controller: NVIDIA Corporation AD107 [GeForce RTX 4060]  driver=nouveau
                  Turing to Ada / Hopper (GTX 16, RTX 20-40)
```

### Intel

| Package | What for |
|---|---|
| `intel-media-va-driver-non-free` | VA-API + QSV driver (`iHD`), Broadwell (gen 8) and newer, with encoding |
| `i965-va-driver-shaders` | VA-API driver for older iGPUs (`i965`), libva falls back to it |
| `libvpl2`, `libmfx-gen1.2` | Quick Sync runtime (oneVPL), Tiger Lake and newer |
| `libmfx1` | Quick Sync runtime (Media SDK) up to Ice Lake, if the release has it |
| `intel-opencl-icd` | OpenCL (HDR tone mapping), Debian 12 only: Debian 13 does not ship it |
| `vainfo`, `intel-gpu-tools` | `vainfo` and `intel_gpu_top` |
| `firmware-intel-graphics` / `firmware-misc-nonfree` | GuC / HuC / DMC firmware. Not on Proxmox: `pve-firmware` has it |

**HuC firmware.** Before 12th gen (Alder Lake) the i915 driver does not load the
HuC firmware, so low-power encoding (VDENC, needed for HEVC / AV1 encoding on
iGPUs like Jasper Lake / N5105 or Coffee Lake) is off. The installer reads the HuC
state from debugfs and, only when it is off, writes `options i915 enable_guc=2`
to `/etc/modprobe.d/gpu-drivers-i915.conf` (reboot needed). Newer iGPUs and the
`xe` driver (Lunar Lake, Battlemage) load it themselves and are left alone, and so
is a host with GVT-g (`i915.enable_gvt=1`), which does not work with GuC / HuC.
Force it with `--guc 2` (HuC only) or `--guc 3` (GuC submission + HuC), or remove
it with `--guc off`.

### NVIDIA

Two sources:

| Source | Driver | When |
|---|---|---|
| `nvidia` (default) | NVIDIA's CUDA apt repo for Debian 12 / 13, newest branches | Turing (GTX 16 / RTX 20) and newer, Blackwell (RTX 50) included. Maxwell / Pascal / Volta on Debian 12 (branch 580) |
| `debian` | Debian non-free: 535 on Debian 12, 550 on Debian 13 | Maxwell / Pascal / Volta on Debian 13 (NVIDIA's debian13 repo has no 580). No Blackwell |

The generation is read from the PCI device ID. Kepler and older (470 legacy
driver) are not supported.

- **Branch.** From NVIDIA's repo the driver is kept on one branch with NVIDIA's
  `nvidia-driver-pinning-<branch>` package: `apt upgrade` brings the minor updates
  of that branch, never a new branch. Default: the newest branch, 580 for
  Maxwell / Pascal / Volta. Change it with `--branch N`.
- **Kernel modules.** `open` (NVIDIA's recommendation for Turing and newer, the
  only choice on the newest branches such as 620, the script checks) or
  `proprietary` (needed before Turing).
  Built with DKMS for the running kernel and every later kernel.
- **Kernel headers.** `linux-headers-$(uname -r)` + the metapackage of the
  installed kernel (`linux-headers-amd64`...). On a Proxmox kernel:
  `proxmox-headers-$(uname -r)` + `proxmox-default-headers`, plus
  `proxmox-headers-X.Y` when an opt-in kernel series is installed.
- **Profile.** `compute` (default on servers): CUDA, NVENC / NVDEC, `nvidia-smi`,
  `nvidia-persistenced`, no X / desktop packages. `desktop` (default when the
  machine boots to `graphical.target`): + the X / Wayland / OpenGL / Vulkan
  driver and `nvidia-settings`.
- **nouveau** is blacklisted (the packages do it, the script checks) and the
  initramfs rebuilt. If nouveau was loaded, reboot.
- **Secure Boot.** DKMS signs the module with `/var/lib/dkms/mok.pub`. If that
  key is not enrolled yet, the wizard offers to run `mokutil --import` (you type a
  one-time password), then on the next boot choose Enroll MOK in the blue MOK
  Manager screen and enter that password.
- **Docker** (`--container-toolkit`, NVIDIA repo only): installs
  `nvidia-container-toolkit` and, if Docker is installed, runs
  `nvidia-ctk runtime configure --runtime=docker` (backup of `daemon.json` in
  `/var/lib/gpu-drivers/backup`). Test: `docker run --rm --gpus all debian nvidia-smi`.
- **LXC** (`--lxc-nodes`, default on Proxmox): enables
  `gpu-drivers-nvidia-nodes.service`, which runs `nvidia-modprobe -c0 -u` at boot,
  before the containers start, so `/dev/nvidia0`, `/dev/nvidiactl`,
  `/dev/nvidia-uvm` and `/dev/nvidia-uvm-tools` exist. Pass them to the container
  (Proxmox: CT > Resources > Add > Device Passthrough) and install the same driver
  version inside it without the kernel module (`NVIDIA-Linux-x86_64-<version>.run
  --no-kernel-module`). The host version is in `nvidia-smi`.

Switching between the `nvidia` and `debian` sources needs
`bash install.sh uninstall --nvidia` first. A driver installed with NVIDIA's
`.run` file must be removed first with `nvidia-uninstall`.

### Apt sources

The non-free packages need the `contrib`, `non-free` and `non-free-firmware`
components. The installer adds the missing ones to the Debian entries only: the
sources whose Release file says `Origin: Debian` (main, updates, security,
backports), in `sources.list`, `*.list` and deb822 `*.sources` files. Proxmox,
OpenMediaVault, Docker and other repos are not touched. Changed files are backed
up to `/var/lib/gpu-drivers/backup`.

### Non-interactive

```bash
bash install.sh install -y                                   # whatever GPUs are found
bash install.sh install -y --no-nvidia                       # Intel only
bash install.sh install -y --nvidia --container-toolkit      # NVIDIA + Docker runtime
bash install.sh install -y --nvidia --branch 580             # stay on branch 580
bash install.sh install -y --nvidia --nvidia-source debian   # Debian's driver
```

All options: `bash install.sh --help`.

## Check

```bash
bash install.sh check
```

Read-only: GPUs and their kernel driver, installed packages, `vainfo` per Intel
render node, HuC state, NVIDIA module / DKMS / `nvidia-smi`, device nodes,
Secure Boot key, Docker runtime.

## Uninstall

```bash
bash install.sh uninstall              # both
bash install.sh uninstall --nvidia     # NVIDIA only
bash install.sh uninstall --intel      # Intel only
```

Purges the packages this script installed (and the libraries they pulled in
that nothing else needs), NVIDIA's apt repo and pinning package, the nvidia
Docker runtime, the boot service and the modprobe files, then rebuilds the
initramfs. Kernel headers, firmware packages and the components added to the
apt sources are kept. Reboot afterwards.

## Notes

- Services that use `/dev/dri/renderD*` need the `render` group:
  `usermod -aG render jellyfin`.
- If `gpu-passthrough` blacklisted the NVIDIA drivers, or a GPU is bound to
  `vfio-pci` for a VM, the host driver cannot use it. The installer warns.
- After a major Debian upgrade (12 to 13) with NVIDIA's repo, run
  `bash install.sh uninstall --nvidia` and install again, the repo is per release.
