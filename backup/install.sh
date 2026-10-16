#!/usr/bin/env bash
# Proxmox VE backup hook installer
#
# Installs vzbackup.sh as a vzdump hook script. After every backup job it
# uploads a tarball of the host config (/etc, /var/lib/pve-cluster, /root)
# and syncs the dump directory to an rclone remote, then sends a notification
# through the Proxmox notification system (mail to root -> system-mail).
#
# Usage:
#   bash install.sh                          (asks for the remote path)
#   bash install.sh --remote GD:Backup/pve   (non-interactive)
#   bash install.sh uninstall
#
# Via curl:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/backup/install.sh)"
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/backup/install.sh)" install.sh --remote GD:Backup/pve
set -euo pipefail

# ---------------------------------------------------------------- defaults
MODE=install
REMOTE_PATH=""
DUMP_DIR="/var/lib/vz/dump"
NOTIFY=""            # always | failure | never   (asked if omitted, default always)
TARGET=/root/vzbackup.sh
VZDUMP_CONF=/etc/vzdump.conf
RCLONE_CONF=/root/.config/rclone/rclone.conf
RAW_URL="https://raw.githubusercontent.com/jicedtea/misc/main/backup"

# ---------------------------------------------------------------- helpers
c_info=$'\e[1;34m'; c_ok=$'\e[1;32m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_off=$'\e[0m'
info() { echo "${c_info}==>${c_off} $*"; }
ok()   { echo "${c_ok}[OK]${c_off} $*"; }
warn() { echo "${c_warn}[WARN]${c_off} $*" >&2; }
die()  { echo "${c_err}[ERROR]${c_off} $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $0 [install|uninstall] [options]

Options:
  --remote PATH    rclone destination, e.g. GD:Backup/pve   (asked if omitted)
  --dump-dir DIR   Local vzdump directory to sync           (default: $DUMP_DIR)
  --notify WHEN    always | failure | never                 (default: always)
  -h, --help       Show this help
EOF
	exit "${1:-0}"
}

# Prompts read from /dev/tty so they still work when the script is piped into bash
INTERACTIVE=0
{ : </dev/tty; } 2>/dev/null && INTERACTIVE=1

# ask VAR "Prompt" [default]
ask() {
	local __var=$1 __prompt=$2 __def=${3:-} __ans=""
	if [[ $INTERACTIVE -eq 1 ]]; then
		read -r -p "  $__prompt${__def:+ [$__def]}: " __ans </dev/tty || true
	fi
	printf -v "$__var" '%s' "${__ans:-$__def}"
}

confirm() {
	local __yn
	ask __yn "$1 (Y/n)" "Y"
	[[ $__yn =~ ^[Yy] ]]
}

# "remote:path" - no quotes, $, backticks or backslashes since it is written into a shell script
REMOTE_RE='^[A-Za-z0-9_.-]+:[^"$`\\]*$'

# ---------------------------------------------------------------- args
if [[ $# -gt 0 ]]; then
	case "$1" in
		install|uninstall) MODE=$1; shift ;;
	esac
fi

while [[ $# -gt 0 ]]; do
	case "$1" in
		--remote)   REMOTE_PATH=$2; shift 2 ;;
		--dump-dir) DUMP_DIR=$2; shift 2 ;;
		--notify)   NOTIFY=$2; shift 2 ;;
		-h|--help)  usage 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done

[[ $EUID -eq 0 ]] || die "This script must run as root"

# ---------------------------------------------------------------- uninstall
if [[ $MODE == uninstall ]]; then
	if [[ -f $VZDUMP_CONF ]] && grep -q '^script:' "$VZDUMP_CONF"; then
		cp -a "$VZDUMP_CONF" "$VZDUMP_CONF.bak.$(date +%Y%m%d%H%M%S)"
		sed -i '/^script:/d' "$VZDUMP_CONF"
		ok "Removed hook from $VZDUMP_CONF"
	fi
	rm -f "$TARGET"
	ok "Removed $TARGET (rclone and its config are left in place)"
	exit 0
fi

# ---------------------------------------------------------------- rclone
info "Checking rclone"
if ! command -v rclone >/dev/null 2>&1; then
	apt-get update -qq
	apt-get install -y rclone
fi
ok "$(rclone version 2>/dev/null | head -n1)"

remotes() { rclone --config "$RCLONE_CONF" listremotes 2>/dev/null || true; }

if [[ -z $(remotes) ]]; then
	warn "No rclone remote configured in $RCLONE_CONF"
	[[ $INTERACTIVE -eq 1 ]] || die "Run 'rclone config' first"
	if confirm "Run 'rclone config' now?"; then
		rclone --config "$RCLONE_CONF" config </dev/tty
	fi
	[[ -n $(remotes) ]] || die "No rclone remote configured. Run 'rclone config' and try again"
fi

# ---------------------------------------------------------------- remote path
if [[ -z $REMOTE_PATH ]]; then
	[[ $INTERACTIVE -eq 1 ]] || die "--remote is required when there is no terminal"
	echo "  Configured remotes: $(remotes | tr '\n' ' ')"
	while :; do
		ask REMOTE_PATH "Remote path (remote:path, e.g. GD:Backup/$(hostname -s))"
		[[ $REMOTE_PATH =~ $REMOTE_RE ]] && break
		warn "Use the form remote:path, without quotes, \$, backticks or backslashes"
	done
fi
[[ $REMOTE_PATH =~ $REMOTE_RE ]] || die "Invalid remote path: $REMOTE_PATH"
REMOTE_PATH=${REMOTE_PATH%/}

remotes | grep -qxF "${REMOTE_PATH%%:*}:" \
	|| die "Remote '${REMOTE_PATH%%:*}' not found. Configured: $(remotes | tr '\n' ' ')"

info "Testing access to $REMOTE_PATH"
if rclone --config "$RCLONE_CONF" mkdir "$REMOTE_PATH"; then
	ok "Remote is reachable"
else
	warn "Could not access $REMOTE_PATH"
	confirm "Install anyway?" || exit 1
fi

# ---------------------------------------------------------------- notification
if [[ -z $NOTIFY ]]; then
	NOTIFY=always
	if [[ $INTERACTIVE -eq 1 ]]; then
		echo "  Send a notification after each upload (Proxmox notification system)?"
		echo "    1) always   2) only on failure   3) never"
		while :; do
			ask pick "Choose 1-3" "1"
			case $pick in
				1) NOTIFY=always; break ;;
				2) NOTIFY=failure; break ;;
				3) NOTIFY=never; break ;;
			esac
			warn "Enter 1, 2 or 3"
		done
	fi
fi
[[ $NOTIFY =~ ^(always|failure|never)$ ]] || die "--notify must be always, failure or never"
if [[ $NOTIFY != never ]] && ! command -v sendmail >/dev/null 2>&1; then
	warn "sendmail not found: notifications can't be sent (Proxmox ships postfix, install it with: apt install postfix)"
fi

# ---------------------------------------------------------------- hook script
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
if [[ -n $SRC_DIR && -f $SRC_DIR/vzbackup.sh ]]; then
	info "Using local $SRC_DIR/vzbackup.sh"
	cp "$SRC_DIR/vzbackup.sh" "$TMP_DIR/vzbackup.sh"
else
	info "Downloading $RAW_URL/vzbackup.sh"
	command -v curl >/dev/null 2>&1 || die "curl is required (apt install curl)"
	curl -fsSL "$RAW_URL/vzbackup.sh" -o "$TMP_DIR/vzbackup.sh" || die "Download failed"
fi

# Drop CRLF in case the file was checked out on Windows, then set the config values
sed -i 's/\r$//' "$TMP_DIR/vzbackup.sh"
grep -q '^remotePath=' "$TMP_DIR/vzbackup.sh" || die "vzbackup.sh has no remotePath= line"
grep -q '^notify=' "$TMP_DIR/vzbackup.sh" || die "vzbackup.sh has no notify= line (outdated file?)"
awk -v r="$REMOTE_PATH" -v d="$DUMP_DIR" -v n="$NOTIFY" '
	/^remotePath=/ { print "remotePath=\"" r "\""; next }
	/^dumpDir=/    { print "dumpDir=\"" d "\""; next }
	/^notify=/     { print "notify=\"" n "\"                # always | failure | never"; next }
	{ print }
' "$TMP_DIR/vzbackup.sh" >"$TMP_DIR/vzbackup.out"

# vzdump runs the hook directly, so it must be executable
install -o root -g root -m 700 "$TMP_DIR/vzbackup.out" "$TARGET"
chmod 700 "$TARGET"
[[ -x $TARGET ]] || die "$TARGET is not executable"
ok "Installed $TARGET (mode 700, executable)"

# ---------------------------------------------------------------- vzdump.conf
touch "$VZDUMP_CONF"
cp -a "$VZDUMP_CONF" "$VZDUMP_CONF.bak.$(date +%Y%m%d%H%M%S)"
if grep -q '^script:' "$VZDUMP_CONF"; then
	current=$(sed -n 's/^script:[[:space:]]*//p' "$VZDUMP_CONF" | head -n1)
	[[ $current == "$TARGET" ]] || warn "Replacing existing hook script: $current"
	sed -i "s|^script:.*|script: $TARGET|" "$VZDUMP_CONF"
else
	echo "script: $TARGET" >>"$VZDUMP_CONF"
fi
ok "Hook registered in $VZDUMP_CONF"

cat <<EOF

${c_ok}Done.${c_off}
  Hook script : $TARGET
  Remote path : $REMOTE_PATH/{config,dump}
  Dump dir    : $DUMP_DIR
  Notify      : $NOTIFY

The hook runs at the end of every vzdump job (job-end). Test it with:
  $TARGET job-end

Note: the dump folder is mirrored with 'rclone sync', so backups pruned
locally are also deleted on the remote.
EOF
if [[ $NOTIFY != never ]]; then
	cat <<EOF

Notifications are mailed to root and routed by Datacenter > Notifications
(type system-mail). Make sure root@pam has an email and a matcher exists:
  pveum user modify root@pam -email you@example.com
  pvesh get /cluster/notifications/matchers
EOF
fi
