# winpe-grub

Adds a WinPE rescue system to the GRUB menu of a Debian / Ubuntu / Proxmox VE
machine. No USB stick needed: GRUB loop-mounts the ISO from the disk and boots
WinPE through [wimboot](https://github.com/ipxe/wimboot), on BIOS and UEFI.

Handy to reset a Windows password, clone or repair disks, or run Windows tools on
a headless box.

## Size limit: small WinPE only

GRUB loads `boot.wim` (plus `BCD` and `boot.sdi`) into memory as the initrd of
wimboot, and only below about 900 MB (`0x37FFFFFF`). Anything bigger fails at
boot with `the size of initrd is bigger than addr_max`, on BIOS and on UEFI.
The installer reads the ISO and **refuses it when these files add up to more than
800 MB**.

| WinPE | `boot.wim` | Works |
|---|---|---|
| Built with the [Windows ADK](https://learn.microsoft.com/windows-hardware/get-started/adk-install) (`copype`) | a few hundred MB | yes |
| [PhoenixPE](https://github.com/PhoenixPE/PhoenixPE), with a few apps | depends on the apps | yes, if under 800 MB |
| `boot.wim` of a Windows 10 / 11 install ISO (Shift+F10 = cmd, Repair) | about 500 - 700 MB | usually |
| Hiren's BootCD PE, Sergei Strelec, Gandalf's... | 2 - 4 GB | **no** |

When booted through wimboot, WinPE only sees what is **inside `boot.wim`**. The
rest of the ISO is not visible. With PhoenixPE, set the apps you want to
"Run from RAM" so they are packed into `boot.wim`, and keep the list short.

### Build a WinPE with the Windows ADK

On a Windows PC, install the Windows ADK and its WinPE add-on, then in the
"Deployment and Imaging Tools Environment" as administrator:

```bat
copype amd64 C:\WinPE
MakeWinPEMedia /ISO C:\WinPE C:\WinPE.iso
```

Copy `C:\WinPE.iso` to the Linux machine, for example to `/boot/WinPE.iso`.

## Install

Run on the machine, as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/winpe-grub/install.sh)"
```

The installer:

1. Asks for the ISO and the name of the GRUB menu entry (default `WinPE`)
2. Mounts the ISO, finds the BCD (BIOS and UEFI), `boot.sdi` and `boot.wim`, and
   refuses it if they are over 800 MB together
3. Downloads `wimboot` to `/boot/wimboot`
4. Writes `/etc/grub.d/43_winpe`, runs `update-grub` and checks `grub.cfg`

The entry finds wimboot and the ISO by filesystem UUID, so it works with a
separate `/boot`, LVM, RAID, ZFS or an ISO on another disk. The ISO stays where
it is: do not move or delete it, or the entry breaks.

Run the installer again to see the status, use another ISO or name, or
uninstall.

Non-interactive:

```bash
bash install.sh install --iso /boot/WinPE.iso -y
bash install.sh install --iso /srv/iso/PhoenixPE.iso --title "PhoenixPE" -y
```

Options:

| Option | Meaning |
|---|---|
| `--iso FILE` | WinPE ISO to boot |
| `--title NAME` | Name in the GRUB menu (default `WinPE`) |
| `--delete-iso` | `uninstall`: also delete the ISO |
| `-y`, `--yes` | Non-interactive, never prompt |

## Boot it

Pick the entry in the GRUB menu. To boot it once from a remote shell,
`GRUB_DEFAULT=saved` must be set in `/etc/default/grub` (then `update-grub`):

```bash
grub-reboot 'WinPE' && reboot
```

## Status / uninstall

```bash
bash install.sh status
bash install.sh uninstall              # asks whether to delete the ISO
bash install.sh uninstall --delete-iso
```

`/boot/wimboot` is kept on uninstall. Entries from the earlier Hiren's-only
version (`/etc/grub.d/43_hbcd`) are replaced or removed too.

## Notes

- **Secure Boot:** wimboot is not signed for the distribution's shim, so GRUB
  refuses to load it. Turn Secure Boot off to use the entry.
- **Proxmox VE on ZFS with UEFI** boots with systemd-boot, not GRUB, so the entry
  never shows up. The installer warns when it detects this.
- The ISO must be on a disk GRUB can read (not encrypted).
- On Ubuntu the menu is hidden by default (`GRUB_TIMEOUT_STYLE=hidden`): hold
  Shift (BIOS) or press Esc (UEFI) at boot.
- The ISO path may only contain letters, digits and `. _ / + @ : -`. The menu
  name may also contain spaces and `( )`.
