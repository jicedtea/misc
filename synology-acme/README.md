# acme.sh for Synology DSM

Installs [acme.sh](https://github.com/acmesh-official/acme.sh) on a Synology
NAS, issues a certificate through your DNS provider's API and deploys it to
DSM, following the
[Synology NAS Guide](https://github.com/acmesh-official/acme.sh/wiki/Synology-NAS-Guide).

DNS-01 validation needs no open ports, works for wildcard certificates, and
avoids the DSM built-in Let's Encrypt failing when the domain has an AAAA record.

## Install

SSH into the NAS, become root with `sudo -i`, then run:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/synology-acme/install.sh)"
```

The wizard asks for:

1. Account email
2. Domain(s), e.g. `nas.example.com` or `example.com,*.example.com` (the first
   one is the main name)
3. DNS provider: Cloudflare (asks for `CF_Token`, optional `CF_Account_ID`) or
   any other [acme.sh DNS API](https://github.com/acmesh-official/acme.sh/wiki/dnsapi)
   (enter its credentials as `NAME=value`)
4. Certificate authority: Let's Encrypt (default) or ZeroSSL
5. Key type: ECDSA P-384 (default, as in the guide), P-256, RSA 2048/4096
6. How the deploy hook logs in to DSM:
   - **Temporary admin** (default): the hook creates a temporary admin user,
     deploys, then deletes it. No password is stored.
   - **Existing admin**: username and password, saved by acme.sh for renewals.
     With 2FA, the hook asks for a code and a device name.
7. DSM certificate description. Empty replaces the default certificate,
   otherwise a new certificate with that description is created
8. Confirmation of the summary (secrets are masked)

Secrets are typed without echo.

### Non-interactive

```bash
bash install.sh install -y \
  --email me@example.com \
  --domain example.com,*.example.com \
  --dns dns_cf --dns-var CF_Token=xxxxxxxx
```

| Option | Default | Notes |
|---|---|---|
| `--email ADDR` | | Required |
| `--domain LIST` | | Required, comma separated |
| `--dns NAME` | `dns_cf` | acme.sh DNS API name |
| `--dns-var NAME=VAL` | | DNS credential, repeat as needed. Exported env vars work too |
| `--ca NAME` | `letsencrypt` | `letsencrypt` or `zerossl` |
| `--keylength LEN` | `ec-384` | `ec-256`, `ec-384`, `2048`, `4096` |
| `--auth temp\|user` | `temp` | `user` reads `SYNO_USERNAME` / `SYNO_PASSWORD` from the environment |
| `--cert-desc TEXT` | empty | DSM certificate description |
| `-y` | | Non-interactive |

## What the script does

1. Checks it runs as root on Synology DSM.
2. Installs acme.sh to `/usr/local/share/.acme.sh` with `--nocron` (or
   upgrades it if already there).
3. `acme.sh --issue --server <ca> -d ... --dns <api> --keylength <len>`.
   If the certificate is still valid, it is not renewed.
4. `acme.sh --deploy --deploy-hook synology_dsm` with `SYNO_USE_TEMP_ADMIN=1`
   or `SYNO_USERNAME` / `SYNO_PASSWORD`, plus `SYNO_CERTIFICATE` /
   `SYNO_CREATE` when a description is given.

acme.sh saves the DNS credentials and the deploy settings, so renewals need no
input.

## Automatic renewal

DSM Security Advisor flags custom cron jobs, so use Task Scheduler instead.
The script does not create the task, you add it once:

**Control Panel > Task Scheduler > Create > Scheduled Task > User-defined script**

- **General:** name `Renew certificate`, user `root`
- **Schedule:** weekly, e.g. Saturday 11:00
- **Task Settings > User-defined script:**
  ```bash
  /usr/local/share/.acme.sh/acme.sh --cron --home /usr/local/share/.acme.sh
  ```

## Uninstall

```bash
bash install.sh uninstall
```

Runs `acme.sh --uninstall` and deletes `/usr/local/share/.acme.sh` (account,
saved credentials, issued certificates). Certificates already imported into DSM
are kept. Delete the Task Scheduler task by hand.

## Troubleshooting

- **acme.sh broken after a DSM update:**
  ```bash
  /usr/local/share/.acme.sh/acme.sh --force --upgrade --nocron --home /usr/local/share/.acme.sh
  ```
- **Temporary admin left behind** (script interrupted with Ctrl+C): delete it
  in Control Panel > User & Group.
- **curl error 16 (HTTP/2)** during deploy: harmless, the NAS lacks some HTTP/2
  dependencies. The deploy still succeeds.
- **Force a renewal:**
  ```bash
  /usr/local/share/.acme.sh/acme.sh --renew --force -d nas.example.com --home /usr/local/share/.acme.sh
  ```
