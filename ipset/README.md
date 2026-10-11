# ipset blacklist for UFW

Blocks known-bad IPs with UFW. The list comes from
[stamparm/ipsum](https://github.com/stamparm/ipsum), a daily feed of IPs seen
on public blacklists, each with a **score** = the number of blacklists it is on.
IPs with a score at or above a threshold (default 3) are loaded into an ipset
named `blacklist`, and UFW drops every packet coming from them.

```
ipsum.txt ──daily──> update_ipset.sh ──> ipset "blacklist" <── UFW before.rules: DROP src in blacklist
                                              │  ▲
                                   shutdown: save  boot: restore (before UFW starts)
                                              ▼  │
                                    /etc/ipset/blacklist.restore
```

## Install

Needs UFW installed. Run as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/ipset/install.sh)"
```

It asks for the minimum score (1-10, default 3) and the daily update time
(default 03:00), then:

1. Installs `ipset` and `curl`
2. Installs `manage_ipset.sh` and `update_ipset.sh` to `/usr/local/bin`, and
   the settings to `/etc/default/ipset-blacklist`
3. Installs and enables `ipset-restore.service` (restores the set at boot,
   before UFW, and saves it at shutdown) and `ipset-update.timer` (daily update)
4. Runs the first update
5. Adds the DROP rules to `/etc/ufw/before.rules` (inside a
   `# >>> ipset-blacklist` block, right after the chain declarations, with a
   backup of the file) and reloads UFW

Non-interactive:

```bash
bash install.sh install -y --min-score 4 --time 04:30
```

Running it again updates the settings and files. It is safe to re-run.

### Upgrading from the old manual setup

If the machine has the old setup (cron job calling `update_ipset.sh`,
`ipset-save.service`, DROP rules pasted by hand into `before.rules`), the installer
removes the cron job and `ipset-save.service` and replaces the hand-added rules
with its own block. The set name and save file are unchanged, so the current
list is kept.

## Usage

```bash
manage_ipset.sh status                        # entries, last save, next update
systemctl start ipset-update.service          # update now
journalctl -u ipset-update -u ipset-restore   # logs
iptables -L ufw-before-input -v -n | grep blacklist   # packets dropped so far
ipset test blacklist 1.2.3.4                  # is this IP blocked?
```

Change the minimum score in `/etc/default/ipset-blacklist` and the update time
in `/etc/systemd/system/ipset-update.timer`, or just run the installer again.

## How updates stay safe

- The new list is built in a temporary set and swapped in with `ipset swap`, so
  the blacklist is never empty during an update.
- If the download fails or returns fewer than 100 IPs, the current list is kept.
- After each update the set is saved, so a crash or power loss does not lose it.

## Uninstall

```bash
bash install.sh uninstall
```

Removes the UFW rules (and reloads UFW), the services and timer, the scripts,
the settings, the saved list and the `blacklist` set. The `ipset` package is
kept.

## Notes

- Only IPv4. ipsum does not list IPv6 addresses.
- The rules use `ufw-before-input` and `ufw-before-forward`, so they apply to
  traffic to the host and traffic routed through it (containers, VMs on a bridge).
- On Proxmox VE, UFW and the built-in Proxmox firewall both manage iptables. The
  installer warns when `pve-firewall` is running.
