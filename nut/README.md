# NUT installer

Installer for [Network UPS Tools](https://networkupstools.org/) on Debian / Ubuntu / Proxmox VE, so your machines shut down cleanly when the power goes out.

```
            USB
   UPS ─────────── [ SERVER ]  nut-server + upsmon (primary)
                        │  tcp/3493
             ┌──────────┼──────────┐
         [ CLIENT ] [ CLIENT ] [ CLIENT ]   upsmon (secondary)
```

- **server**: the machine with the UPS USB cable. Runs the driver, `upsd` (port 3493) and `upsmon` as primary.
- **client**: every other machine. Runs only `upsmon` as secondary, watching the UPS through the server.

## Install

### Interactive

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/nut/install.sh)"
```

The wizard asks for:

1. Mode: server / client / uninstall
2. Server IP (client only), UPS name, driver and port (server only), username, password
3. Shutdown policy: on low battery, or after N seconds on battery
4. Notification email
5. Confirmation of the summary

Press Enter to accept the `[default]` shown for each prompt.

```
? Install mode
    1) Server - this machine has the UPS USB cable
    2) Client - watch a UPS on another NUT server
    3) Uninstall NUT
  Choose 1-3 [1]: 2

==> Configure client (press Enter to keep the [default])
  NUT server IP: 10.0.0.1
  UPS name on the server [ups]:
  Username [monuser]:
  Password: secret
? When to shut down this machine?
    1) When the UPS reports low battery (or the server sends FSD)
    2) After N seconds on battery
  Choose 1-2 [1]: 2
  Seconds on battery before shutdown [60]:
  ...
```

When the server install finishes, it prints the client command with IP, username and password filled in.

### Non-interactive

Pass the mode and options, plus `-y` to skip all prompts:

```bash
# Server
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/nut/install.sh)" install.sh server -y

# Client
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/nut/install.sh)" install.sh client -y --server 10.0.0.1 --pass <password>
```

Without `-y`, options given on the command line become the defaults in the wizard.

## Shutdown policy

| Option | Behaviour |
|---|---|
| (default) | Shut down only when the UPS reports **low battery** (LOWBATT) or the server sends FSD |
| `--timer 60` | Shut down after **60 seconds on battery**. Cancelled if power returns first |

With `--timer` on the **server**, the server sets FSD when the timer expires, so **all clients shut down too**. With `--timer` on a **client**, only that client shuts down.

Tip: let clients go early (`--timer 60`) and keep the server on the default (wait for low battery).

## Options

| Option | Default | Notes |
|---|---|---|
| `--ups NAME` | `ups` | UPS name, must match on server and clients |
| `--timer N` | `0` | Seconds on battery before shutdown, `0` = wait for low battery |
| `--email ADDR` | `root` | Notification recipient, only used if `mail` is installed |
| `--driver NAME` | `usbhid-ups` | Server. Use `nut-scanner -U` to detect |
| `--port PORT` | `auto` | Server |
| `--server IP` | | Client, required with `-y` |
| `--user NAME` | `monuser` | Username clients log in to the server with |
| `--pass PASS` | random (server) | Required for clients with `-y` |
| `-y` | | Non-interactive |

Uninstall: `bash install.sh uninstall`

## What the script does

1. Backs up an existing `/etc/nut` to `/etc/nut.bak.<timestamp>`.
2. Installs packages: `nut` on the server, `nut-client` on clients.
3. Writes the config to `/etc/nut`:

| File | Server | Client |
|---|---|---|
| `nut.conf` | `MODE=netserver` | `MODE=netclient` |
| `ups.conf` | driver, `offdelay=60` | not used |
| `upsd.conf` | `LISTEN 0.0.0.0 3493` | not used |
| `upsd.users` | `admin`, `monmaster` (primary), `monuser` (secondary), random passwords | not used |
| `upsmon.conf` | `MONITOR ups@localhost ... primary` | `MONITOR ups@<server> ... secondary` |
| `upssched.conf` | depends on the policy | depends on the policy |
| `upssched-cmd` | logs to syslog, sends mail, runs `upsmon -c fsd` | same |

4. Restarts `nut-driver`, `nut-server` and `nut-monitor`, then checks the UPS with `upsc`.

## Reference templates

`netserver/`, `netclient/low-battery/`, `netclient/by-second/` and `upssched-cmd` are the original hand-made configs, kept for reference. Values are placeholders (`<UPS_NAME>`, `<SERVER_IP>`, `<MON_USER>`, `<MON_PASSWORD>`, `<ADMIN_PASSWORD>`, `<MONMASTER_PASSWORD>`, `<SHUTDOWN_TIMER>`). `install.sh` does not use these files; it generates its own config.

## Checking

```bash
upsc ups@localhost            # on the server
upsc ups@10.0.0.1 ups.status  # on a client: OL = on line, OB = on battery, LB = low battery
journalctl -u nut-monitor -f  # follow the log
upsmon -c fsd                 # CAREFUL: simulates a power failure, the machine really shuts down
```

## Notes

- If a firewall is enabled (Proxmox Firewall, UFW...), allow **tcp/3493** on the server from the clients.
- When a Proxmox host shuts down, `pve-guests` stops VMs/CTs first. Install the QEMU guest agent in VMs for fast, clean shutdowns.
- To power hosts back on automatically, enable "Restore on AC power loss" (or "Power On") in the BIOS. The server sets `offdelay=60`, so the UPS cuts its output after the server shuts down and the machines see power return.
- Uses the NUT 2.8+ keywords `primary` / `secondary` (Proxmox 8/9). The old `master` / `slave` still work.
