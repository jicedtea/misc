# docker-wait-disks

Makes Docker wait for its data disks at boot on Debian / Ubuntu / Proxmox VE.

Without this, Docker can start before a disk is mounted, or while the disk is
missing. Containers then write into the empty folder under the mount point, and
their data ends up on the system disk.

## Install

Run on the machine, as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/docker-wait-disks/install.sh)"
```

The installer:

1. Checks that `docker.service` exists
2. Lists what is mounted now and asks for the mount points to wait for. Enter
   numbers from the list or paths, separated by spaces
3. Refuses a path that is not mounted right now, because the service would fail
   and Docker could not start
4. Writes `/etc/systemd/system/wait-disks.service`, enables and starts it
5. Asks whether to restart Docker now. Running containers restart too

Example:

```
  Mounted now:
     1) /srv/dev-disk-by-uuid-05f38b68-b391-4d13-9da1-51407caf8a5f
     2) /srv/dev-disk-by-uuid-498fb7dc-49e3-4f0c-bd2a-2a706e7f19fb

  Mount points to wait for (numbers or paths, separated by spaces): 1 2
```

Run the installer again to change the mount points or uninstall. The current
ones are the default.

Non-interactive:

```bash
bash install.sh install --mount /mnt/data --mount /mnt/media -y
```

Options:

| Option | Meaning |
|---|---|
| `--mount PATH` | Mount point Docker waits for, repeat for several |
| `--no-restart` | Do not restart Docker now, the change applies at the next boot |
| `-y`, `--yes` | Non-interactive, never prompt |

## Uninstall

```bash
bash install.sh uninstall
```

Disables and removes the service. Docker keeps running.

## Notes

- If a disk is missing at boot, **Docker stays down** on purpose. Check with
  `systemctl status wait-disks`, fix the disk, then run `systemctl start docker`.
- `RequiresMountsFor=` waits for mounts systemd knows about, usually from
  `/etc/fstab`. A mount made later by something else (a script, for example) is
  not waited for, and the `mountpoint` check then fails.
- Paths with spaces are not supported.
