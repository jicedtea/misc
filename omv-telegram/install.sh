#!/usr/bin/env bash
# Forward OpenMediaVault notifications to Telegram
#
# Installs a notification sink script in /usr/share/openmediavault/notification/sink.d.
# Postfix runs every script there (run-parts) for each notification OMV sends, so every
# mail notification (monitoring alerts, SMART, RAID, cron, logins...) also reaches a
# Telegram chat through a bot. The bot token and chat ID are written into the script.
#
# Usage:
#   bash install.sh                                        (interactive)
#   bash install.sh install --token TOKEN --chat-id ID [--thread-id N] [--no-test] [-y]
#   bash install.sh test                                   (send a test message)
#   bash install.sh uninstall
#
# The token can also come from the TELEGRAM_BOT_TOKEN environment variable, so it
# does not show up in the process list.
#
# Via curl:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/omv-telegram/install.sh)"
#
# More info:
#   https://docs.openmediavault.org/en/latest/administration/general/notifications.html
#   https://forum.openmediavault.org/index.php?thread/14919-guide-use-telegram-as-notification-service/
set -euo pipefail

# ---------------------------------------------------------------- defaults
MODE=""
TOKEN_ARG=${TELEGRAM_BOT_TOKEN:-}
CHAT_ARG=""
THREAD_ARG=""
NO_TEST=0
ASSUME_YES=0
SINK_DIR=/usr/share/openmediavault/notification/sink.d
SINK_FILE=$SINK_DIR/20telegram
API=https://api.telegram.org

# ---------------------------------------------------------------- helpers
c_info=$'\e[1;34m'; c_ok=$'\e[1;32m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_off=$'\e[0m'
info() { echo "${c_info}==>${c_off} $*"; }
ok()   { echo "${c_ok}[OK]${c_off} $*"; }
warn() { echo "${c_warn}[WARN]${c_off} $*" >&2; }
die()  { echo "${c_err}[ERROR]${c_off} $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $0 [install|test|uninstall] [options]

Options:
  --token TOKEN    Bot token from @BotFather (or env TELEGRAM_BOT_TOKEN)
  --chat-id ID     Chat to send to: user ID, group ID (-100...) or @channelname
  --thread-id N    Topic (message thread) ID in a forum group, optional
  --no-test        Do not send a test message after installing
  -y, --yes        Non-interactive, never prompt

Examples:
  $0
  TELEGRAM_BOT_TOKEN=123:abc $0 install --chat-id 123456789 -y
  $0 test
  $0 uninstall
EOF
	exit "${1:-0}"
}

# Prompts read from /dev/tty so they still work when the script is piped into bash
INTERACTIVE=0
{ : </dev/tty; } 2>/dev/null && INTERACTIVE=1

# ask VAR "Prompt" [default] [secret]
ask() {
	local __var=$1 __prompt=$2 __def=${3:-} __secret=${4:-} __ans="" __shown
	if [[ $INTERACTIVE -eq 1 ]]; then
		__shown=$__def
		[[ -n $__secret && -n $__def ]] && __shown="keep $(mask "$__def")"
		if [[ -n $__secret ]]; then
			read -r -s -p "  $__prompt${__shown:+ [$__shown]}: " __ans </dev/tty || true
			echo
		else
			read -r -p "  $__prompt${__shown:+ [$__shown]}: " __ans </dev/tty || true
		fi
	fi
	printf -v "$__var" '%s' "${__ans:-$__def}"
}

# choose VAR "Title" default "value|label" ...   (VAR receives the value)
choose() {
	local __var=$1 __title=$2 __def=$3 __i=1 __n __pick __defn=1 __opt
	shift 3
	echo "${c_info}?${c_off} $__title"
	for __opt in "$@"; do
		[[ ${__opt%%|*} == "$__def" ]] && __defn=$__i
		echo "    $__i) ${__opt#*|}"
		__i=$((__i + 1))
	done
	__n=$#
	while :; do
		ask __pick "Choose 1-$__n" "$__defn"
		[[ $__pick =~ ^[0-9]+$ ]] && ((__pick >= 1 && __pick <= __n)) && break
		warn "Enter a number from 1 to $__n"
	done
	__opt=${!__pick}
	printf -v "$__var" '%s' "${__opt%%|*}"
}

confirm() {   # confirm "Question" [Y|N default]
	local __yn __def=${2:-Y}
	ask __yn "$1 ($([[ $__def == Y ]] && echo Y/n || echo y/N))" "$__def"
	[[ $__yn =~ ^[Yy] ]]
}

mask() {   # 123456:ABCdef...xyz -> 123456:***xyz
	local t=$1
	[[ ${#t} -gt 12 ]] || { echo "***"; return; }
	echo "${t%%:*}:***${t: -3}"
}

valid_token()  { [[ $1 =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]]; }
valid_chat()   { [[ $1 =~ ^-?[0-9]+$ || $1 =~ ^@[A-Za-z][A-Za-z0-9_]{4,}$ ]]; }
valid_thread() { [[ -z $1 || $1 =~ ^[0-9]+$ ]]; }

# Current settings, from the sink script
installed_value() {   # installed_value BOT_TOKEN|CHAT_ID|THREAD_ID
	[[ -f $SINK_FILE ]] || return 0
	# Values were written with printf %q: valid tokens / IDs need no quoting
	sed -n "s/^$1=//p" "$SINK_FILE" | head -n1 | sed "s/^'\(.*\)'\$/\1/"
}

# Telegram getMe: prints the bot's @username, fails on a bad token or no network
bot_username() {   # bot_username TOKEN
	local r
	r=$(curl -sS --max-time 15 "$API/bot$1/getMe" 2>&1) || { warn "Cannot reach $API: $r"; return 1; }
	[[ $r == *'"ok":true'* ]] || { warn "Telegram refused the token: $r"; return 1; }
	sed -n 's/.*"username":"\([^"]*\)".*/\1/p' <<<"$r"
}

# The user postfix runs the sink scripts as (pipe transport in master.cf)
pipe_user() {
	local cf=/etc/postfix/master.cf
	[[ -f $cf ]] || return 0
	# Join the continuation lines of every service, keep the one that runs sink.d
	awk '/^[^[:space:]#]/ { if (s) print s; s=$0; next }
	     /^[[:space:]]+[^[:space:]#]/ { s=s" "$0 }
	     END { if (s) print s }' "$cf" |
		grep -E 'notification|sink\.d' | grep -oE 'user=[^[:space:]:]+' | head -n1 | cut -d= -f2
}

# ---------------------------------------------------------------- sink script
write_sink() {   # write_sink FILE TOKEN CHAT THREAD
	{
		echo '#!/bin/bash'
		echo '# Written by omv-telegram/install.sh: forwards OMV notifications to Telegram.'
		echo '# Postfix runs it through run-parts for every notification. Re-run the installer'
		echo '# to change the settings. Test: bash install.sh test'
		printf 'BOT_TOKEN=%q\n' "$2"
		printf 'CHAT_ID=%q\n' "$3"
		printf 'THREAD_ID=%q\n' "$4"
		cat <<'SINK'

# Character counts and the hostname in upper case need a UTF-8 locale
export LC_ALL=C.UTF-8
MAX_BODY=3500   # Telegram allows 4096 characters per message

SUBJECT=${OMV_NOTIFICATION_SUBJECT:-}
MSG_FILE=${OMV_NOTIFICATION_MESSAGE_FILE:-${1:-}}

ICON="ℹ️"
case ${SUBJECT,,} in
	*error*)                                        ICON="🔴" ;;
	*warning*)                                      ICON="⚠️" ;;
	monitoring\ alert*|monitoring\ restart*)        ICON="🚨" ;;
	cron*|cron-apt\ *|anacron\ *)                   ICON="🕐" ;;
	*security*|*"was used to log in to the openmediavault"*) ICON="🔒" ;;
	pending\ configuration*)                        ICON="⚙️" ;;
	*smart*)                                        ICON="💽" ;;
esac

# OMV_NOTIFICATION_DATE may hold several Date headers, one per line: use the first
DATE_FIRST=$(printf '%s\n' "${OMV_NOTIFICATION_DATE:-}" | head -n1)
DATE_FMT=""
[[ -n $DATE_FIRST ]] && DATE_FMT=$(date -d "$DATE_FIRST" '+%H:%M:%S %d/%m/%Y' 2>/dev/null)
[[ -n $DATE_FMT ]] || DATE_FMT=$(date '+%H:%M:%S %d/%m/%Y')

BODY=""
[[ -n $MSG_FILE && -r $MSG_FILE ]] && BODY=$(cat -- "$MSG_FILE")
if [[ ${#BODY} -gt $MAX_BODY ]]; then
	BODY="${BODY:0:$MAX_BODY}
[... truncated, $(( ${#BODY} - MAX_BODY )) more characters]"
fi

esc() {   # HTML escaping for parse_mode=HTML
	# Quoted replacements: in bash 5.2 an unquoted & stands for the matched text
	local s=${1//'&'/'&amp;'}
	s=${s//'<'/'&lt;'}
	printf '%s' "${s//'>'/'&gt;'}"
}

HOST=$(hostname)
TEXT="$ICON <i>$DATE_FMT</i> · [$(esc "${HOST^^}")] <b>$(esc "$SUBJECT")</b>"
[[ -n $BODY ]] && TEXT+=$'\n\n'"<pre>$(esc "$BODY")</pre>"

ARGS=(--data-urlencode "chat_id=$CHAT_ID" --data-urlencode "text=$TEXT"
	--data "parse_mode=HTML" --data "disable_web_page_preview=true")
[[ -n $THREAD_ID ]] && ARGS+=(--data "message_thread_id=$THREAD_ID")

RESP=$(curl -sS --max-time 20 --retry 2 "${ARGS[@]}" \
	"https://api.telegram.org/bot$BOT_TOKEN/sendMessage" 2>&1)
if [[ $RESP != *'"ok":true'* ]]; then
	logger -t omv-telegram "sendMessage failed: $RESP" 2>/dev/null || true
	echo "omv-telegram: sendMessage failed: $RESP" >&2
	# A failure must not hold up the other sinks or the mail: only report it when testing
	[[ ${OMV_TELEGRAM_STRICT:-0} == 1 ]] && exit 1
fi
exit 0
SINK
	} >"$1"
}

# Restrict the script (it holds the token) to root and the postfix pipe user
set_perms() {   # set_perms FILE
	local u g
	u=$(pipe_user)
	if [[ -n $u ]] && g=$(id -gn "$u" 2>/dev/null) && [[ $u != root ]]; then
		chown "root:$g" "$1"
		chmod 0750 "$1"
		ok "$1: mode 0750, group $g (postfix runs the sinks as $u)"
	else
		chown root:root "$1"
		chmod 0755 "$1"
		warn "Cannot tell which user postfix runs the sinks as, $1 is world-readable (it holds the token)"
	fi
}

send_test() {
	local tmp rc=0 u
	[[ -x $SINK_FILE ]] || die "$SINK_FILE not found, install first"
	tmp=$(mktemp)
	printf 'Test message from %s.\nIf you can read this, OMV notifications reach Telegram.\n' "$(hostname -f 2>/dev/null || hostname)" >"$tmp"
	chmod 0644 "$tmp"
	u=$(pipe_user)
	info "Sending a test message${u:+ as $u}"
	# Run it as postfix would, so a permission problem shows up now
	if [[ -n $u && $u != root ]] && id "$u" >/dev/null 2>&1 && command -v runuser >/dev/null; then
		runuser -u "$u" -- env OMV_TELEGRAM_STRICT=1 \
			OMV_NOTIFICATION_SUBJECT="Telegram notification test" \
			OMV_NOTIFICATION_DATE="$(date -R)" OMV_NOTIFICATION_MESSAGE_FILE="$tmp" \
			"$SINK_FILE" || rc=$?
	else
		OMV_TELEGRAM_STRICT=1 OMV_NOTIFICATION_SUBJECT="Telegram notification test" \
			OMV_NOTIFICATION_DATE="$(date -R)" OMV_NOTIFICATION_MESSAGE_FILE="$tmp" \
			"$SINK_FILE" || rc=$?
	fi
	rm -f "$tmp"
	[[ $rc -eq 0 ]] || die "Test message failed (see above). Did you send /start to the bot, or add it to the group?"
	ok "Test message sent, check the Telegram chat"
}

# ---------------------------------------------------------------- args
if [[ $# -gt 0 ]]; then
	case "$1" in
		install|test|uninstall) MODE=$1; shift ;;
		-h|--help) usage 0 ;;
		-*) ;;
		*) usage 1 ;;
	esac
fi

while [[ $# -gt 0 ]]; do
	case "$1" in
		--token)     [[ $# -ge 2 ]] || die "Missing value for $1"; TOKEN_ARG=$2; shift 2 ;;
		--token=*)   TOKEN_ARG=${1#*=}; shift ;;
		--chat-id)   [[ $# -ge 2 ]] || die "Missing value for $1"; CHAT_ARG=$2; shift 2 ;;
		--chat-id=*) CHAT_ARG=${1#*=}; shift ;;
		--thread-id) [[ $# -ge 2 ]] || die "Missing value for $1"; THREAD_ARG=$2; shift 2 ;;
		--thread-id=*) THREAD_ARG=${1#*=}; shift ;;
		--no-test)   NO_TEST=1; shift ;;
		-y|--yes)    ASSUME_YES=1; shift ;;
		-h|--help)   usage 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done
[[ $ASSUME_YES -eq 1 ]] && INTERACTIVE=0

[[ $EUID -eq 0 ]] || die "Run as root"
command -v omv-salt >/dev/null || die "omv-salt not found, this is not an OpenMediaVault system"
[[ -d $SINK_DIR ]] || die "$SINK_DIR not found, unsupported OpenMediaVault version"

CUR_TOKEN=$(installed_value BOT_TOKEN)
CUR_CHAT=$(installed_value CHAT_ID)
CUR_THREAD=$(installed_value THREAD_ID)

if [[ -z $MODE ]]; then
	MODE=install
	if [[ -f $SINK_FILE && $INTERACTIVE -eq 1 ]]; then
		info "Installed: $SINK_FILE, chat $CUR_CHAT${CUR_THREAD:+ topic $CUR_THREAD}, bot token $(mask "$CUR_TOKEN")"
		choose MODE "What do you want to do?" test \
			"test|Send a test message" \
			"install|Change the bot token / chat" \
			"uninstall|Uninstall"
	fi
fi

# ---------------------------------------------------------------- test / uninstall
if [[ $MODE == test ]]; then
	send_test
	exit 0
fi

if [[ $MODE == uninstall ]]; then
	if [[ -f $SINK_FILE ]]; then
		rm -f -- "$SINK_FILE"
		ok "Removed $SINK_FILE, notifications no longer go to Telegram"
	else
		warn "$SINK_FILE not found, not installed"
	fi
	exit 0
fi

# ---------------------------------------------------------------- install
command -v curl >/dev/null || die "curl is required: apt install curl"

if [[ $INTERACTIVE -eq 1 ]]; then
	if [[ -z $CUR_TOKEN && -z $TOKEN_ARG ]]; then
		cat <<EOF

  1. In Telegram, talk to @BotFather: /newbot, it gives you the bot token.
  2. Send /start to your bot (or add it to a group / channel).
  3. Find the chat ID: open $API/bot<TOKEN>/getUpdates after
     sending the bot a message, look for "chat":{"id":...}. Groups start with -100.

EOF
	fi
	while :; do
		ask BOT_TOKEN "Bot token" "${TOKEN_ARG:-$CUR_TOKEN}" secret
		valid_token "$BOT_TOKEN" || { warn "A bot token looks like 123456789:AAF... (digits, colon, 35 characters)"; continue; }
		if BOT_NAME=$(bot_username "$BOT_TOKEN"); then
			ok "Bot: @$BOT_NAME"
			break
		fi
		confirm "Use this token anyway?" N && break
	done
	while :; do
		ask CHAT_ID "Chat ID (user ID, group -100..., or @channel)" "${CHAT_ARG:-$CUR_CHAT}"
		valid_chat "$CHAT_ID" && break
		warn "Enter a number like 123456789 or -1001234567890, or @channelname"
	done
	while :; do
		ask THREAD_ID "Topic ID in a forum group (Enter = none)" "${THREAD_ARG:-$CUR_THREAD}"
		[[ $THREAD_ID == none ]] && THREAD_ID=""
		valid_thread "$THREAD_ID" && break
		warn "Enter a number, or nothing"
	done
else
	BOT_TOKEN=${TOKEN_ARG:-$CUR_TOKEN}
	CHAT_ID=${CHAT_ARG:-$CUR_CHAT}
	THREAD_ID=${THREAD_ARG:-$CUR_THREAD}
	[[ -n $BOT_TOKEN ]] || die "Missing --token (or TELEGRAM_BOT_TOKEN)"
	[[ -n $CHAT_ID ]] || die "Missing --chat-id"
	valid_token "$BOT_TOKEN" || die "Invalid bot token"
	BOT_NAME=$(bot_username "$BOT_TOKEN") || die "Cannot check the bot token"
	ok "Bot: @$BOT_NAME"
fi
valid_chat "$CHAT_ID" || die "Invalid chat ID: $CHAT_ID"
valid_thread "$THREAD_ID" || die "Invalid topic ID: $THREAD_ID"

echo
info "Summary"
echo "    Sink script : $SINK_FILE"
echo "    Bot         : ${BOT_NAME:+@$BOT_NAME }($(mask "$BOT_TOKEN"))"
echo "    Chat        : $CHAT_ID${THREAD_ID:+, topic $THREAD_ID}"
echo
if [[ $INTERACTIVE -eq 1 ]]; then
	confirm "Proceed?" || die "Cancelled"
fi

TMP_SINK=$(mktemp "$SINK_DIR/.20telegram.XXXXXX")
trap 'rm -f "$TMP_SINK"' EXIT
write_sink "$TMP_SINK" "$BOT_TOKEN" "$CHAT_ID" "$THREAD_ID"
bash -n "$TMP_SINK" || die "Generated script has a syntax error"
set_perms "$TMP_SINK"
mv -f "$TMP_SINK" "$SINK_FILE"
trap - EXIT
ok "Wrote $SINK_FILE"

if [[ $NO_TEST -eq 0 ]]; then
	if [[ $INTERACTIVE -eq 0 ]] || confirm "Send a test message now?"; then
		send_test
	fi
fi

cat <<EOF

  Notifications only flow when they are enabled in the web UI:
    System > Notification > Settings: enable, fill in SMTP (any working server)
    System > Notification > Events: pick what to be notified about
  End to end test: "Send a test email" in System > Notification > Settings
  Test Telegram only: bash install.sh test
  Errors are logged: journalctl -t omv-telegram
  Remove: bash install.sh uninstall
EOF
