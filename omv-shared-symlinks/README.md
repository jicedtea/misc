# omv-shared-symlinks

Gives every OpenMediaVault shared folder a short, stable path:

```
/shared/<shared folder name>  ->  /srv/dev-disk-by-uuid-.../<folder>
```

Useful for Docker volumes, scripts and backups: `/shared/appdata` instead of
`/srv/dev-disk-by-uuid-05f38b68-b391-4d13-9da1-51407caf8a5f/appdata`.

It installs the Salt state by NiltonVolpato from
[openmediavault/openmediavault#2010](https://github.com/openmediavault/openmediavault/issues/2010),
with a configurable directory, as `/srv/salt/omv/deploy/systemd/99symlinks.sls`.
OMV applies it every time it deploys the `systemd` configuration, so new shared
folders get a link, renamed ones are updated and removed ones are deleted.

> **Warning:** the state cleans the directory (`clean: True`). Anything in it that
> is not a link to a shared folder is **deleted**, real files and folders too.
> The installer refuses a directory that holds anything other than symlinks.

## Install

Run on the OMV machine, as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/omv-shared-symlinks/install.sh)"
```

The installer:

1. Checks that this is OpenMediaVault (`omv-salt`)
2. Asks for the directory (default `/shared`) and refuses system directories and
   directories that hold real files or folders
3. Asks whether to lock the directory with `chattr +i` (default yes), so nothing
   else can create files in it. The state unlocks it while it updates the links
4. Writes the Salt state and runs `omv-salt deploy run systemd`
5. Lists the links

Run the installer again to change the directory or uninstall. When the directory
changes, the links in the old one are removed.

Non-interactive:

```bash
bash install.sh install --dir /shared -y
```

Only print the Salt state, install nothing:

```bash
bash install.sh print --dir /shared
```

Options:

| Option | Meaning |
|---|---|
| `-d`, `--dir DIR` | Directory that holds the links (default `/shared`) |
| `--no-lock` | Do not lock the directory with `chattr +i` |
| `-y`, `--yes` | Non-interactive, never prompt |

## Uninstall

```bash
bash install.sh uninstall
```

Removes the Salt state, unlocks the directory, deletes its symlinks and the
directory itself when it is empty. The shared folders are not touched.

## Notes

- If a new shared folder has no link yet, apply the state by hand:
  `omv-salt deploy run systemd`.
- With the lock on, `rm`, `mv` or `touch` in the directory fail with
  `Operation not permitted`. Check with `lsattr -d /shared`.
- The directory path may only contain letters, digits and `. _ - /`.
  Shared folder names can contain anything OMV allows.
- Written for OpenMediaVault 7 (Debian 12). The state file lives in
  `/srv/salt/omv/deploy/systemd/`, which an OMV upgrade does not remove.
