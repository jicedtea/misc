# docker-wait-disks

Makes Docker wait at boot until every shared folder of an **OpenMediaVault**
machine is on a mounted disk.

Without this, Docker can start before a disk is mounted, or while the disk is
missing. Containers then write into the empty folder under the mount point, and
their data ends up on the system disk.

The list of shared folders is read from the OMV config (`omv-confdbadm`) at
every boot, so shared folders added or removed in the web UI are picked up
without running the installer again. The path of each shared folder is the one
OMV uses: the mount directory of its filesystem plus its relative path, for
example `/srv/dev-disk-by-uuid-05f38b68-.../appdata` or
`/srv/mergerfs/pool/data` on a mergerfs pool.

A shared folder or path counts as ready when it is a directory and is not on the
root filesystem. The service checks every 3 seconds, for up to 2 minutes.

## Install

Run on the OMV machine, as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/docker-wait-disks/install.sh)"
```

The installer:

1. Checks that this is OpenMediaVault and that `docker.service` exists
2. Lists what is mounted now and asks for extra paths outside the shared
   folders, if any (`none` = only the shared folders)
3. Checks everything once and refuses if something is not ready right now,
   because the service would fail and Docker could not start
4. Writes `/usr/local/sbin/wait-disks-check` and
   `/etc/systemd/system/wait-disks.service`, enables and starts the service
5. Asks whether to restart Docker now. Running containers restart too

Example:

```
  Mounted now:
     1) /srv/dev-disk-by-uuid-05f38b68-b391-4d13-9da1-51407caf8a5f
     2) /srv/dev-disk-by-uuid-498fb7dc-49e3-4f0c-bd2a-2a706e7f19fb
     3) /srv/mergerfs/pool

  Docker waits for every shared folder. Paths outside the shared folders can be added.
  Other paths to wait for (numbers or paths, none = only the shared folders) [none]:

==> Summary
    Service : /etc/systemd/system/wait-disks.service (required by docker.service)
    Check   : /usr/local/sbin/wait-disks-check
    Docker waits for:
      ready      shared folder appdata (/srv/dev-disk-by-uuid-05f38b68-.../appdata)
      ready      shared folder downloads (/srv/dev-disk-by-uuid-498fb7dc-.../downloads)
      ready      shared folder data (/srv/mergerfs/pool/data)
      ready      shared folder proxmox (/srv/mergerfs/pool/proxmox)
```

Run the installer again to change the extra paths or uninstall. The current
ones are the default.

Non-interactive:

```bash
bash install.sh install -y                          # all shared folders
bash install.sh install --path /opt/appdata -y      # shared folders + a path
```

Options:

| Option | Meaning |
|---|---|
| `--path PATH` | Extra path Docker waits for, repeat for several |
| `--no-restart` | Do not restart Docker now, the change applies at the next boot |
| `-y`, `--yes` | Non-interactive, never prompt |

## Check

```bash
/usr/local/sbin/wait-disks-check --list       # add the extra paths, as in the service
systemctl status wait-disks
```

`--list` checks once and prints every shared folder and path as `ready` or
`NOT READY`.

## Uninstall

```bash
bash install.sh uninstall
```

Disables and removes the service and the check script. Docker keeps running.

## Notes

- If something is not ready after 2 minutes, **Docker stays down** on purpose.
  `systemctl status wait-disks` lists each `not ready` shared folder or path. Fix
  it, then run `systemctl start docker`.
- If the OMV config cannot be read, the check fails too, rather than letting
  Docker start without checking anything.
- Shared folders on the root filesystem (sharerootfs plugin) are skipped: they
  would never be ready.
- A mergerfs pool counts as ready once the pool is mounted and the folder exists
  in it. mergerfs can mount with a branch disk missing, and the folder still
  exists if another branch has it.
- A mount made later by something else (a script, for example) is picked up if it
  appears within the 2 minutes.
- Extra paths cannot contain spaces and cannot be on the root filesystem.
  Shared folder names can contain spaces.
- Installs from before the check script existed are read when you run the
  installer again, and their paths are kept as extra paths.
