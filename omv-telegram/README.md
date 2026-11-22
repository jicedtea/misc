# omv-telegram

Sends every **OpenMediaVault** notification to a Telegram chat through a bot:
monitoring alerts, SMART, RAID, scheduled tasks, cron-apt, web UI logins and the
rest of the events in *System > Notification > Events*.

OMV sends its notifications as mail through postfix. Postfix also runs every
executable script in `/usr/share/openmediavault/notification/sink.d` (with
run-parts) for each notification
([OMV docs](https://docs.openmediavault.org/en/latest/administration/general/notifications.html#third-party-notifications)).
The installer writes `sink.d/20telegram`, which posts the subject and the message
to the Telegram Bot API. Based on the
[forum guide](https://forum.openmediavault.org/index.php?thread/14919-guide-use-telegram-as-notification-service/).

A message looks like:

```
🔴 10:00:00 22/11/2026 · [NAS] SMART error (Health) detected on host: nas

<the notification text, in a monospace block>
```

The icon depends on the subject: 🔴 error, ⚠️ warning, 🚨 monitoring alert /
restart, 🕐 cron / cron-apt / anacron, 🔒 security and web UI logins,
⚙️ pending configuration, 💽 SMART, ℹ️ the rest.

## Before you install

1. In Telegram, talk to [@BotFather](https://t.me/BotFather): `/newbot`. It gives
   you the **bot token** (`123456789:AAF...`).
2. Send `/start` to your bot, or add it to a group or channel (as admin for a channel).
3. Find the **chat ID**: send the bot a message, then open
   `https://api.telegram.org/bot<TOKEN>/getUpdates` and look for
   `"chat":{"id":...}`. User IDs are positive, groups start with `-100`. A public
   channel can also be given as `@channelname`.
4. In the OMV web UI, enable notifications: *System > Notification > Settings*,
   with a working SMTP server, and pick the events in *System > Notification > Events*.
   Without this OMV sends nothing, so the sink never runs.

## Install

Run on the OMV machine, as root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/omv-telegram/install.sh)"
```

The installer:

1. Checks that this is OpenMediaVault
2. Asks for the bot token (hidden input) and checks it with Telegram (`getMe`)
3. Asks for the chat ID and, for a forum group, the topic ID (optional)
4. Writes `/usr/share/openmediavault/notification/sink.d/20telegram`. It holds the
   token, so it is readable only by root and the group of the user postfix runs
   the sinks as (read from `/etc/postfix/master.cf`). If that user cannot be found
   the file stays world-readable, with a warning
5. Sends a test message, as the postfix user, so a permission problem shows up now

Run it again to send a test message, change the bot or chat, or uninstall. Running
it again always overwrites the sink script.

Non-interactive (the token from the environment stays out of the process list):

```bash
TELEGRAM_BOT_TOKEN='123456789:AAF...' bash install.sh install --chat-id -1001234567890 -y
```

Options:

| Option | Meaning |
|---|---|
| `--token TOKEN` | Bot token (or the `TELEGRAM_BOT_TOKEN` environment variable) |
| `--chat-id ID` | User ID, group ID (`-100...`) or `@channelname` |
| `--thread-id N` | Topic ID in a forum group (optional) |
| `--no-test` | Do not send a test message |
| `-y`, `--yes` | Non-interactive, never prompt |

## Test

```bash
bash install.sh test
```

sends a test message through the sink script only. For a full test of OMV and
postfix, use *Send a test email* in *System > Notification > Settings*.

## Uninstall

```bash
bash install.sh uninstall
```

Removes the sink script. The OMV notification settings are not touched.

## Notes

- The message is sent as HTML, with the subject and text escaped, so `_`, `*` or
  `<` in a subject do not break it. Text longer than 3500 characters is cut, since
  Telegram allows 4096 per message.
- A failed send never blocks the mail or the other sinks. It is logged:
  `journalctl -t omv-telegram`. The usual causes are a bot that never got `/start`,
  a bot not in the group, or a wrong chat ID.
- The sink file is not owned by any package, so OMV upgrades keep it.
- Written for OpenMediaVault 7 (Debian 12).
