# GPU Passthrough for Proxmox VE

Sets up a Proxmox VE host to pass a GPU through to VMs, following the 3os.org
guides. Two types:

| Type | What it does | Guide |
|---|---|---|
| `full` | A whole GPU (discrete or Intel iGPU) goes to **one** VM | [GPU](https://3os.org/infrastructure/proxmox/gpu-passthrough/gpu-passthrough-to-vm/), [iGPU](https://3os.org/infrastructure/proxmox/gpu-passthrough/igpu-passthrough-to-vm/) |
| `gvt` | Intel **GVT-g** splits the iGPU into virtual GPUs for **several** VMs. Intel gen 5-10 only (Broadwell to Comet Lake) | [iGPU split](https://3os.org/infrastructure/proxmox/gpu-passthrough/igpu-split-passthrough/) |

## Before you start

- Enable **Intel VT-d** or **AMD-Vi / IOMMU** in the BIOS/UEFI. For GVT-g also
  keep the iGPU enabled (and give it enough memory, if the BIOS has a DVMT /
  aperture setting).
- Make sure **SSH or the web UI** works. Passing through the GPU the host boots
  on (often the iGPU) blanks the host console.
- The passed-through GPU's output does **not** show in noVNC/SPICE. Connect a
  monitor or set up remote desktop in the guest.

## Install

Run on the Proxmox node, as root.

### Interactive

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/gpu-passthrough/install.sh)"
```

The wizard asks for:

1. Mode: setup / check / uninstall
2. Type: full / GVT-g
3. **full:** which GPU(s), whether to blacklist the host GPU drivers, whether
   to bind to `vfio-pci` at boot
4. Confirmation of the summary

The script only prepares the host. Reboot when it finishes, run the `check`
mode, then add the GPU to a VM in the GUI (see [Add the GPU to a VM](#add-the-gpu-to-a-vm)).

### Non-interactive

```bash
URL=https://raw.githubusercontent.com/jicedtea/misc/main/gpu-passthrough/install.sh

# Only prepare the host (kernel options + VFIO modules)
bash -c "$(curl -fsSL $URL)" install.sh setup -y

# Discrete GPU at 01:00.0, host GPU drivers blacklisted
bash -c "$(curl -fsSL $URL)" install.sh setup -y --gpu 01:00.0 --blacklist

# Whole Intel iGPU, forced vfio-pci binding
bash -c "$(curl -fsSL $URL)" install.sh setup -y --gpu 00:02.0 --bind

# GVT-g
bash -c "$(curl -fsSL $URL)" install.sh setup -y --type gvt
```

Find the GPU address with `lspci -nnk | grep -A3 -E "VGA|3D|Display"`.

## Options

| Option | Default | Notes |
|---|---|---|
| `--type full\|gvt` | `full` | |
| `--gpu ADDR[,ADDR]` | | full: PCI address, e.g. `01:00.0` or `00:02.0`. All functions of the slot (HDMI audio, USB-C...) are included. GVT-g always uses `00:02.0` |
| `--blacklist` | off (wizard: on for NVIDIA/AMD) | Blacklist `radeon nouveau nvidia nvidiafb nvidia-gpu`. Always on for GVT-g |
| `--bind` | off | full: bind to `vfio-pci` at boot. Only needed if Proxmox can't take the GPU from the host driver by itself |
| `-y` | | Non-interactive |

## What `setup` does

1. **Kernel options** in `GRUB_CMDLINE_LINUX_DEFAULT` of `/etc/default/grub`
   (backed up first), then `update-grub` / `proxmox-boot-tool refresh`:

   | Option | When |
   |---|---|
   | `intel_iommu=on` | every Intel host |
   | `i915.enable_gvt=1 iommu=pt` | GVT-g |

   On a systemd-boot host (ZFS on UEFI) the same options also go into
   `/etc/kernel/cmdline`, which is what that bootloader reads.
2. **Modules** in `/etc/modules` (inside a `# >>> gpu-passthrough` block):
   `vfio vfio_iommu_type1 vfio_pci`, plus `kvmgt` for GVT-g.
3. **Driver blacklist** (GVT-g, or full with `--blacklist`). Instead of
   `modprobe.blacklist=` on the kernel command line, a block is added to
   `/etc/modprobe.d/blacklist.conf`:
   ```
   blacklist radeon
   blacklist nouveau
   blacklist nvidia
   blacklist nvidiafb
   blacklist nvidia-gpu
   ```
   The script warns if a device on the host currently uses one of these.
4. **Checks** (full). Warns if the GPU is the host's boot display, shares its
   IOMMU group with an unrelated device, or (with `--bind`) another device has
   the same vendor:device ID.
5. **vfio-pci binding** (full with `--bind`). Writes
   `/etc/modprobe.d/gpu-passthrough.conf`:
   ```
   options vfio-pci ids=10de:2204,10de:1aef
   softdep nouveau pre: vfio-pci
   softdep snd_hda_intel pre: vfio-pci
   ...
   ```
6. Runs `update-initramfs -u -k all` if anything changed.

VM configs are never touched.

Running `setup` again is safe. It skips what is already in place.

### Not done on purpose

The GVT-g guide also puts `pcie_acs_override=downstream,multifunction`,
`vfio_iommu_type1.allow_unsafe_interrupts=1`, `video=efifb:off video=vesa:off`
and `kvm.ignore_msrs=1` on the command line. The script leaves them out: ACS
override and unsafe interrupts weaken isolation, and the passthrough guide
says to use them only for a specific, verified hardware problem. Add them by
hand if you need them. `vfio_virqfd` is also skipped, it is built into `vfio`
since kernel 6.2.

## Check

```bash
bash install.sh check
```

Prints the kernel, bootloader, command line, IOMMU status, loaded VFIO
modules, blacklisted drivers still loaded, GVT-g types with free instances,
and, for every GPU, each function with its ID, driver and IOMMU group.

- **full:** a driver of `vfio-pci` (or none) means the GPU is free for a VM.
- **GVT-g:** the iGPU keeps `i915`. Types look like `i915-GVTg_V5_4`. A lower
  last number means more video memory per VM and fewer VMs.

More checks from the guides:

```bash
dmesg | grep -e DMAR -e IOMMU -e AMD-Vi
pvesh get /nodes/$(hostname)/hardware/pci --pci-class-blacklist ""
lspci -nnk -s 01:00.0
dmesg -w   # watch while starting the VM
```

## Add the GPU to a VM

After the reboot, shut the VM down, then VM > Hardware > Add > PCI Device:

- **full:** select the GPU, tick **All Functions** (HDMI audio etc.), use a
  `q35` machine with **PCI-Express** ticked. Use OVMF (UEFI) only if the GPU
  ROM supports UEFI, otherwise SeaBIOS. Tick **Primary GPU** only if the guest
  should use it as its main display.
- **GVT-g:** select `0000:00:02.0` and an **MDev Type** (`check` lists them).
  Windows: `q35` + PCI-Express. Linux: `i440fx` works too. ROM-Bar stays on.

## Uninstall

```bash
bash install.sh uninstall
```

Removes the kernel options the script added, the `/etc/modules` block, the
`/etc/modprobe.d/blacklist.conf` block and `/etc/modprobe.d/gpu-passthrough.conf`,
then rebuilds the initramfs. PCI devices in VM configs are kept. Remove them
under VM > Hardware.

## Notes

- **Guest drivers:** Windows: install the latest Intel/NVIDIA/AMD driver and
  check Device Manager. Linux: `ls -la /dev/dri` should show `renderD128`.
- **Reset bugs:** if the GPU does not reset cleanly between VM starts, check
  the GPU firmware and vendor docs first. `vendor-reset` only covers the AMD
  families it lists, not NVIDIA RTX.
- **Intel 11th gen and newer** do not support GVT-g. They use SR-IOV, which is
  not covered.
