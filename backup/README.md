# backup

vzdump hook script for Proxmox VE. At the end of every backup job it:

1. tars the host config (`/etc`, `/var/lib/pve-cluster`, `/root`) and moves it to `<remote>/config`
2. syncs the local dump directory (`/var/lib/vz/dump`) to `<remote>/dump`
3. sends a notification with the result of each step (see [Notifications](#notifications))

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
- asks when to notify: always (default), only on failure, or never
- writes `/root/vzbackup.sh` with these settings, mode `700` (vzdump runs it directly, so it must be executable)
- adds `script: /root/vzbackup.sh` to `/etc/vzdump.conf` (a timestamped backup of the old file is kept)

Non-interactive:

```bash
bash install.sh --remote GD:Backup/pve1 [--dump-dir /var/lib/vz/dump] [--notify always|failure|never]
```

Remove the hook (rclone and its config stay):

```bash
bash install.sh uninstall
```

## Notifications

Like disk-health, the hook mails `root` with `sendmail`. Proxmox feeds that mail
into its notification stack as type `system-mail` and sends it to the targets
configured under Datacenter > Notifications (email, Gotify, webhook...).

The subject is `Offsite backup OK` or `Offsite backup FAILED`. The body lists
each step (config archive, config upload, dump sync) with its result, duration
and rclone transfer stats, the last 20 lines of output for a failed step, and
the remote's disk usage when the remote supports it.

Make sure the mail is routed:

```bash
pveum user modify root@pam -email you@example.com
pvesh get /cluster/notifications/matchers
```

Change the setting later by editing `notify=` in `/root/vzbackup.sh`
(`always`, `failure` or `never`), or by running the installer again.

When a step fails the hook exits non-zero, so the vzdump task log also shows
the error.

## Notes

- The dump folder uses `rclone sync`: backups pruned locally are also deleted on the remote.
- Test without waiting for a job: `/root/vzbackup.sh job-end`
- `tar` exit code 1 (a file changed while it was read, e.g. logs) is not treated as a failure, the archive is still usable.
