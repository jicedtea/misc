# backup

vzdump hook script for Proxmox VE. At the end of every backup job it:

1. tars the host config (`/etc`, `/var/lib/pve-cluster`, `/root`) and moves it to `<remote>/config`
2. syncs the local dump directory (`/var/lib/vz/dump`) to `<remote>/dump`

Uploads go through [rclone](https://rclone.org/), so any rclone remote works
(Google Drive, SharePoint, S3, SFTP, ...).

## Install

Run on the node, as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/backup/install.sh)"
```

The installer:

- installs `rclone` if missing and offers to run `rclone config` when no remote exists
- asks for the remote path (`remote:path`, e.g. `GD:Backup/pve1`) and checks it is reachable
- writes `/root/vzbackup.sh` with that path
- adds `script: /root/vzbackup.sh` to `/etc/vzdump.conf` (a timestamped backup of the old file is kept)

Non-interactive:

```bash
bash install.sh --remote GD:Backup/pve1 [--dump-dir /var/lib/vz/dump]
```

Remove the hook (rclone and its config stay):

```bash
bash install.sh uninstall
```

## Notes

- The dump folder uses `rclone sync`: backups pruned locally are also deleted on the remote.
- Test without waiting for a job: `/root/vzbackup.sh job-end`
