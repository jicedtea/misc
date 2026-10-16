#!/usr/bin/env bash
# IP blacklist for UFW, from stamparm/ipsum
#
# Loads known-bad IPs (listed on >= N public blacklists) into an ipset and drops
# them in UFW. The set is restored at boot before UFW starts, saved on shutdown
# and refreshed daily by a systemd timer.
#
# Usage:
#   bash install.sh                      (interactive)
#   bash install.sh install [options]
#   bash install.sh uninstall
#
# Via curl:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/ipset/install.sh)"
set -euo pipefail

# ---------------------------------------------------------------- defaults
MODE=""
MIN_SCORE=3
UPDATE_TIME="03:00"
ASSUME_YES=0
IPSET_NAME=blacklist
SAVE_FILE=/etc/ipset/blacklist.restore
CONFIG=/etc/default/ipset-blacklist
BIN_DIR=/usr/local/bin
UNIT_DIR=/etc/systemd/system
UFW_RULES=/etc/ufw/before.rules
SCRIPTS=(manage_ipset.sh update_ipset.sh)
UNITS=(ipset-restore.service ipset-update.service ipset-update.timer)
MARK_BEGIN="# >>> ipset-blacklist"
MARK_END="# <<< ipset-blacklist"
RAW_URL="https://raw.githubusercontent.com/jicedtea/misc/main/ipset"

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
  --min-score N    Keep IPs listed on at least N blacklists (1-10)  (default: $MIN_SCORE)
                   Higher = fewer IPs, fewer false positives
  --time HH:MM     Daily update time                                (default: $UPDATE_TIME)
  -y, --yes        Non-interactive, never prompt

Examples:
  $0
  $0 install -y --min-score 4
  $0 uninstall
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

# ask_valid VAR "Prompt" default regex "error message"
ask_valid() {
	local __var=$1 __prompt=$2 __def=$3 __re=$4 __msg=$5 __val
	while :; do
		ask __val "$__prompt" "$__def"
		[[ $__val =~ $__re ]] && break
		[[ $INTERACTIVE -eq 1 ]] || die "$__prompt: $__msg"
		warn "$__msg"
	done
	printf -v "$__var" '%s' "$__val"
}

confirm() {
	local __yn
	ask __yn "$1 (Y/n)" "Y"
	[[ $__yn =~ ^[Yy] ]]
}

ufw_active() { ufw status 2>/dev/null | grep -q '^Status: active'; }
block_remove() { [[ -f $1 ]] && sed -i "\|^$MARK_BEGIN|,\|^$MARK_END|d" "$1"; return 0; }

# ---------------------------------------------------------------- args
if [[ $# -gt 0 ]]; then
	case "$1" in
		install|uninstall) MODE=$1; shift ;;
		-h|--help) usage 0 ;;
		-*) ;;
		*) usage 1 ;;
	esac
fi

while [[ $# -gt 0 ]]; do
	case "$1" in
		--min-score) MIN_SCORE=$2; shift 2 ;;
		--time)      UPDATE_TIME=$2; shift 2 ;;
		-y|--yes)    ASSUME_YES=1; shift ;;
		-h|--help)   usage 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done

[[ $EUID -eq 0 ]] || die "Run as root"
[[ -f /etc/debian_version ]] || die "Only Debian / Ubuntu / Proxmox VE is supported"
[[ $ASSUME_YES -eq 1 ]] && INTERACTIVE=0
MODE=${MODE:-install}

# ---------------------------------------------------------------- uninstall
if [[ $MODE == uninstall ]]; then
	if [[ $INTERACTIVE -eq 1 ]]; then
		confirm "Remove the UFW rules, services and the '$IPSET_NAME' ipset?" || die "Cancelled"
	fi
	if grep -qF "$MARK_BEGIN" "$UFW_RULES" 2>/dev/null; then
		cp -a "$UFW_RULES" "$UFW_RULES.bak.$(date +%Y%m%d-%H%M%S)"
		block_remove "$UFW_RULES"
		ok "Removed rules from $UFW_RULES"
		ufw_active && ufw reload >/dev/null && ok "UFW reloaded"
	fi
	systemctl disable --now ipset-update.timer 2>/dev/null || true
	systemctl disable --now ipset-restore.service 2>/dev/null || true
	for u in "${UNITS[@]}"; do rm -f "$UNIT_DIR/$u"; done
	systemctl daemon-reload
	systemctl reset-failed ipset-restore.service ipset-update.service 2>/dev/null || true
	if grep -q -- "--match-set $IPSET_NAME " "$UFW_RULES" 2>/dev/null; then
		warn "$UFW_RULES still has other rules using '$IPSET_NAME' (added by hand?). Keeping the set"
	else
		ipset destroy "$IPSET_NAME" 2>/dev/null && ok "Destroyed ipset '$IPSET_NAME'" || true
	fi
	for s in "${SCRIPTS[@]}"; do rm -f "$BIN_DIR/$s"; done
	rm -f "$CONFIG" "$SAVE_FILE"
	ok "IP blacklist removed (ipset package kept)"
	exit 0
fi

# ---------------------------------------------------------------- checks
command -v ufw >/dev/null 2>&1 || die "UFW is not installed. This tool adds its rules to UFW: install and configure UFW first (apt install ufw)"
[[ -f $UFW_RULES ]] || die "$UFW_RULES not found"
if systemctl is-active --quiet pve-firewall 2>/dev/null; then
	warn "pve-firewall is running. UFW and the Proxmox firewall both manage iptables and can conflict"
fi
ufw_active || warn "UFW is installed but not active. The rules take effect once you run: ufw enable"

# ---------------------------------------------------------------- inputs
if [[ $INTERACTIVE -eq 1 ]]; then
	echo
	echo "  ipsum gives each IP a score = number of public blacklists it appears on."
	echo "  3 is a good balance; lower blocks more IPs but risks false positives."
	ask_valid MIN_SCORE "Minimum score (1-10)" "$MIN_SCORE" '^([1-9]|10)$' "Enter a number from 1 to 10"
	ask_valid UPDATE_TIME "Daily update time (HH:MM)" "$UPDATE_TIME" '^([01][0-9]|2[0-3]):[0-5][0-9]$' "Use HH:MM, e.g. 03:00"
fi
[[ $MIN_SCORE =~ ^([1-9]|10)$ ]] || die "--min-score must be 1-10"
[[ $UPDATE_TIME =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "--time must be HH:MM"

# Old setup (cron + ipset-save.service) to migrate
OLD_CRON=$(crontab -l 2>/dev/null | grep -E 'update_ipset\.sh' || true)
OLD_SAVE_UNIT=0; [[ -f $UNIT_DIR/ipset-save.service ]] && OLD_SAVE_UNIT=1
# Rules added by hand from the old note.txt (outside our marker block)
MANUAL_RULES=""
if ! grep -qF "$MARK_BEGIN" "$UFW_RULES"; then
	MANUAL_RULES=$(grep -- "--match-set $IPSET_NAME src" "$UFW_RULES" 2>/dev/null || true)
fi

echo
info "Summary"
echo "    Source     : stamparm/ipsum, score >= $MIN_SCORE"
echo "    ipset      : $IPSET_NAME (saved to $SAVE_FILE)"
echo "    UFW rules  : DROP input + forward from $IPSET_NAME -> $UFW_RULES"
echo "    Update     : daily at $UPDATE_TIME (ipset-update.timer)"
[[ -n $OLD_CRON ]]       && echo "    Migrate    : remove old cron job: $OLD_CRON"
[[ $OLD_SAVE_UNIT -eq 1 ]] && echo "    Migrate    : remove old ipset-save.service"
[[ -n $MANUAL_RULES ]]   && echo "    Migrate    : replace hand-added rules in $UFW_RULES"
echo
if [[ $INTERACTIVE -eq 1 ]]; then
	confirm "Proceed?" || die "Cancelled"
fi

# ---------------------------------------------------------------- packages
info "Installing ipset and curl"
export DEBIAN_FRONTEND=noninteractive
if ! command -v ipset >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
	apt-get update -qq
	apt-get install -y -qq ipset curl >/dev/null
fi
ok "$(ipset --version | head -1)"

# ---------------------------------------------------------------- files
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
for f in "${SCRIPTS[@]}" "${UNITS[@]}"; do
	if [[ -n $SRC_DIR && -f $SRC_DIR/$f ]]; then
		cp "$SRC_DIR/$f" "$TMP_DIR/$f"
	else
		curl -fsSL "$RAW_URL/$f" -o "$TMP_DIR/$f" || die "Download failed: $RAW_URL/$f"
	fi
	sed -i 's/\r$//' "$TMP_DIR/$f"   # in case of a Windows checkout
done
[[ -n $SRC_DIR && -f $SRC_DIR/manage_ipset.sh ]] && info "Using local files from $SRC_DIR" || info "Downloaded files from $RAW_URL"

for s in "${SCRIPTS[@]}"; do
	install -o root -g root -m 755 "$TMP_DIR/$s" "$BIN_DIR/$s"
done
sed -i "s|^OnCalendar=.*|OnCalendar=*-*-* $UPDATE_TIME:00|" "$TMP_DIR/ipset-update.timer"
for u in "${UNITS[@]}"; do
	install -o root -g root -m 644 "$TMP_DIR/$u" "$UNIT_DIR/$u"
done
cat >"$CONFIG" <<EOF
# Settings for manage_ipset.sh / update_ipset.sh (written by ipset/install.sh)
IPSET_NAME="$IPSET_NAME"
SAVE_FILE="$SAVE_FILE"
MIN_SCORE=$MIN_SCORE
SOURCE_URL="https://raw.githubusercontent.com/stamparm/ipsum/master/ipsum.txt"
EOF
ok "Installed scripts to $BIN_DIR, units to $UNIT_DIR, config to $CONFIG"

# ---------------------------------------------------------------- migrate old setup
if [[ -n $OLD_CRON ]]; then
	crontab -l 2>/dev/null | grep -vE 'update_ipset\.sh' | crontab -
	ok "Removed old cron job (now ipset-update.timer)"
fi
if [[ $OLD_SAVE_UNIT -eq 1 ]]; then
	systemctl disable ipset-save.service 2>/dev/null || true
	rm -f "$UNIT_DIR/ipset-save.service"
	ok "Removed old ipset-save.service (saving now happens when ipset-restore.service stops)"
fi

# ---------------------------------------------------------------- services
systemctl daemon-reload
systemctl enable ipset-restore.service >/dev/null 2>&1
# Creates the set (or loads the saved one) before UFW references it
systemctl restart ipset-restore.service || die "ipset-restore.service failed: journalctl -u ipset-restore"
ok "ipset '$IPSET_NAME' ready: $($BIN_DIR/manage_ipset.sh status | head -1)"

info "Downloading the blacklist (first update)"
if systemctl start ipset-update.service; then
	journalctl -u ipset-update.service -n 3 --no-pager -o cat 2>/dev/null | sed 's/^/    /' || true
else
	warn "First update failed (journalctl -u ipset-update). The timer will try again"
fi
systemctl enable --now ipset-update.timer >/dev/null 2>&1
ok "Daily update at $UPDATE_TIME enabled"

# ---------------------------------------------------------------- UFW rules
cp -a "$UFW_RULES" "$UFW_RULES.bak.$(date +%Y%m%d-%H%M%S)"
if [[ -n $MANUAL_RULES ]]; then
	sed -i -E "\#^-A ufw-before-(input|forward) -m set --match-set $IPSET_NAME src -j DROP\$#d" "$UFW_RULES"
fi
block_remove "$UFW_RULES"
cat >"$TMP_DIR/rules" <<EOF
$MARK_BEGIN
# Drop traffic from IPs in the '$IPSET_NAME' ipset (stamparm/ipsum), see ipset/install.sh
-A ufw-before-input -m set --match-set $IPSET_NAME src -j DROP
-A ufw-before-forward -m set --match-set $IPSET_NAME src -j DROP
$MARK_END
EOF
# Right after the chain declarations, so it runs before every ACCEPT rule
# (or before COMMIT if the file has no "# End required lines" marker)
after=0; grep -q '^# End required lines' "$UFW_RULES" && after=1
awk -v f="$TMP_DIR/rules" -v after="$after" '
	function emit(  l) { while ((getline l < f) > 0) print l; done = 1 }
	!after && /^COMMIT/ && !done { emit() }
	{ print }
	after && /^# End required lines/ && !done { emit() }
' "$UFW_RULES" >"$TMP_DIR/before.rules"
grep -qF "$MARK_BEGIN" "$TMP_DIR/before.rules" || die "Could not find where to add the rules in $UFW_RULES"
cat "$TMP_DIR/before.rules" >"$UFW_RULES"
ok "Rules added to $UFW_RULES (backup kept next to it)"

if ufw_active; then
	if ufw reload >/dev/null; then
		ok "UFW reloaded"
	else
		warn "ufw reload failed. Check $UFW_RULES or restore the backup"
	fi
fi

# ---------------------------------------------------------------- done
cat <<EOF

${c_ok}[OK]${c_off} IP blacklist installed.

  Status      : manage_ipset.sh status
  Update now  : systemctl start ipset-update.service
  Logs        : journalctl -u ipset-update -u ipset-restore
  Dropped pkts: iptables -L ufw-before-input -v -n | grep $IPSET_NAME
  Settings    : $CONFIG (min score), $UNIT_DIR/ipset-update.timer (time)
EOF
