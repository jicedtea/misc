# winpe-grub

Adds [Hiren's BootCD PE](https://www.hirensbootcd.org/) (a WinPE 11 rescue
system) to the GRUB menu of a Debian / Ubuntu / Proxmox VE machine. No USB stick
needed: GRUB loop-mounts the ISO from the disk and boots WinPE through
[wimboot](https://github.com/ipxe/wimboot), on BIOS and UEFI.

Handy to reset a Windows password, clone or repair disks, or run Windows tools on
a headless box.

## Install

Run on the machine, as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/winpe-grub/install.sh)"
```

The installer:

1. Downloads `HBCD_PE_x64.iso` (about 3 GB) to `/boot`, after checking the free
   space. An interrupted download resumes when you run it again
2. Verifies the sha256 if you give one with `--sha256`, otherwise prints it so
   you can compare it with [hirensbootcd.org/download](https://www.hirensbootcd.org/download/)
3. Downloads `wimboot` to `/boot/wimboot`
4. Mounts the ISO, finds the BCD (BIOS and UEFI), `boot.sdi` and `boot.wim`
5. Writes `/etc/grub.d/43_hbcd`, runs `update-grub` and checks `grub.cfg`

The entry finds wimboot and the ISO by filesystem UUID, so it works with a
separate `/boot`, LVM, RAID, ZFS or an ISO on another disk.

Run the installer again to see the status, reinstall or uninstall.

Non-interactive, with checksum:

```bash
bash install.sh install --sha256 <hash from hirensbootcd.org> -y
```

Use an ISO you already have (it is not moved):

```bash
bash install.sh install --iso /srv/iso/HBCD_PE_x64.iso
```

Options:

| Option | Meaning |
|---|---|
| `--iso-dir DIR` | Where to download the ISO (default `/boot`) |
| `--iso FILE` | Use this ISO instead of downloading one |
| `--sha256 HASH` | Verify the ISO |
| `--delete-iso` | `uninstall`: also delete the ISO |
| `-y`, `--yes` | Non-interactive, never prompt |

The environment variables `ISO_DIR` and `HBCD_SHA256` work as well.

## Boot it

Pick **Hirens BootCD PE** in the GRUB menu. To boot it once from a remote shell,
`GRUB_DEFAULT=saved` must be set in `/etc/default/grub` (then `update-grub`):

```bash
grub-reboot 'Hirens BootCD PE' && reboot
```

## Status / uninstall

```bash
bash install.sh status
bash install.sh uninstall              # asks whether to delete the ISO
bash install.sh uninstall --delete-iso
```

`/boot/wimboot` is kept on uninstall.

## Notes

- **Secure Boot:** wimboot is not signed for the distribution's shim, so GRUB
  refuses to load it. Turn Secure Boot off to use the entry.
- **Proxmox VE on ZFS with UEFI** boots with systemd-boot, not GRUB, so the entry
  never shows up. The installer warns when it detects this.
- `/boot` is often a small partition. If it has less than 4 GB free, use
  `--iso-dir` with a folder on a bigger disk that GRUB can read (not encrypted).
- On Ubuntu the menu is hidden by default (`GRUB_TIMEOUT_STYLE=hidden`): hold
  Shift (BIOS) or press Esc (UEFI) at boot.
- The ISO path may only contain letters, digits and `. _ / + @ : -`.
