# PCIe Passthrough for the Dell Wyse 5070

Sets up a Proxmox VE host on a **Dell Wyse 5070** (extended chassis with the
PCIe slot) to pass the card in the slot through to a VM. Works for any card:
a NIC (Intel i226 / i225, X520...) or a GPU (AMD Radeon...).

Follows steps 1-3 of
[PCIe passthrough on the Dell Wyse 5070 (AMD Radeon)](https://liamtc.tech/posts/pcie-passthrough-dell-wyse-5070-amd-radeon/),
plus `disable_idle_d3=1` for cards like the Intel i226 that do not come back
from D3 (the VM fails to start or the card disappears).

For a GPU in a regular PC, or Intel GVT-g, use [gpu-passthrough](../gpu-passthrough/).

## Before you start

- In the BIOS, under **Virtualization Support**, enable **Virtualization** and
  **VT for Direct I/O** (VT-d is off by default on the Wyse 5070).
- Make sure **SSH or the web UI** works over a NIC you keep on the host. The
  script warns if the selected card has an interface in a bridge (e.g. `vmbr0`).

## Install

Run on the Proxmox node, as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/pcie-passthrough/install.sh)"
```

The wizard asks for:

1. Mode: setup / check / uninstall
2. The device(s) to pass through. It lists every device behind a PCIe port
   (the slot card and the onboard Realtek NIC) with ID, driver, IOMMU group
   and network interfaces
3. Whether to add the ACS override and `disable_idle_d3=1` (both on by default)
4. Confirmation of the summary

Reboot when it finishes, run `check`, then add the card to a VM.

Non-interactive:

```bash
URL=https://raw.githubusercontent.com/jicedtea/misc/main/pcie-passthrough/install.sh
bash -c "$(curl -fsSL $URL)" install.sh setup -y --dev 01:00.0
bash -c "$(curl -fsSL $URL)" install.sh setup -y --dev 01:00.0 --no-acs
```

## Options

| Option | Default | Notes |
|---|---|---|
| `--dev ADDR[,ADDR]` | | PCI address, e.g. `01:00.0`. All functions of the slot (ports of a multi-port NIC, GPU HDMI audio) are included. Required with `-y` |
| `--no-acs` | ACS on | Leave out `pcie_acs_override=downstream,multifunction` |
| `--no-d3` | D3 off | Leave out `disable_idle_d3=1` |
| `-y` | | Non-interactive |

## What `setup` does

1. **Kernel options** (step 1) in `GRUB_CMDLINE_LINUX_DEFAULT` of
   `/etc/default/grub` (backed up first, also `/etc/kernel/cmdline` on
   systemd-boot), then `update-grub` / `proxmox-boot-tool refresh`:

   | Option | Why |
   |---|---|
   | `intel_iommu=on iommu=pt` | turn on VT-d, host devices skip IOMMU translation |
   | `pcie_acs_override=downstream,multifunction` | split the slot from the other devices into its own IOMMU group. It trusts isolation the hardware does not prove: only for a host you control |
   | `initcall_blacklist=sysfb_init` | GPU only: the generic framebuffer does not grab the card at boot |

2. **vfio-pci binding** (step 3): writes `/etc/modprobe.d/vfio.conf` (a file
   not written by the script is backed up first). The `ids=` are the
   vendor:device IDs read from the selected card (and every function of its
   slot), the same as `lspci -nn` shows in `[...]`. For an Intel i226:
   ```
   options vfio-pci ids=8086:125c disable_idle_d3=1
   softdep igc pre: vfio-pci
   ```
   For an AMD Radeon RX 550 (`disable_vga=1` is added for GPUs):
   ```
   options vfio-pci ids=1002:699f,1002:aae0 disable_idle_d3=1 disable_vga=1
   softdep amdgpu pre: vfio-pci
   softdep radeon pre: vfio-pci
   softdep snd_hda_intel pre: vfio-pci
   ```
   The `softdep` lines (the card's current host driver, plus the GPU / HDMI
   audio drivers) load `vfio-pci` first, so it claims the card.
3. **Modules** `vfio vfio_iommu_type1 vfio_pci` in `/etc/modules`, so
   `vfio-pci` also loads when the host driver is blacklisted.
4. **Blacklist** (GPU only, step 3): `amdgpu radeon` (AMD) or `nouveau`
   (NVIDIA) in a block of `/etc/modprobe.d/blacklist.conf`.
5. `update-initramfs -u -k all` if anything changed.

Before writing, it warns if the card has a network interface in a bridge, is
the boot display, shares its IOMMU group with another device, or another
device has the same vendor:device ID (it would be bound to `vfio-pci` too).

Running `setup` again is safe. It skips what is already in place.

## Check

```bash
bash install.sh check
```

Prints the cmdline, whether IOMMU / the DMAR table / ACS override are on,
`vfio_pci` and its `disable_idle_d3`, `/etc/modprobe.d/vfio.conf`, and for each
device behind a PCIe port: ID, driver, IOMMU group (and what else is in it),
power state and network interfaces. Ready means `driver=vfio-pci`,
`power=D0`, and nothing else in the group.

The same by hand:

```bash
cat /proc/cmdline
ls /sys/firmware/acpi/tables/DMAR
ls /sys/kernel/iommu_groups/
lspci -nnk -s 01:00     # Kernel driver in use: vfio-pci
```

## Add the card to a VM

VM > Hardware > Add > PCI Device > Raw Device, select the card, tick **All
Functions**, use a `q35` machine with **PCI-Express** ticked. For a GPU use
OVMF (UEFI). AMD cards that do not reset between VM starts need
[vendor-reset](https://github.com/gnif/vendor-reset) (not done by this script).

## Uninstall

```bash
bash install.sh uninstall
```

Removes the kernel options the script added, `/etc/modprobe.d/vfio.conf`, the
`/etc/modules` and `/etc/modprobe.d/blacklist.conf` blocks, then rebuilds the
initramfs. VM configs are not touched.

## Notes

- Only one `options vfio-pci ids=` is used. Do not combine with
  `gpu-passthrough setup --bind`, the script warns if
  `/etc/modprobe.d/gpu-passthrough.conf` sets one.
- `intel_iommu=on iommu=pt` may also be set by gpu-passthrough. Uninstall
  removes the options this script added, even if the other tool still needs
  them: run the other tool's `setup` again afterwards.
