#!/usr/bin/env bash
# Make Docker wait for its data disks at boot on OpenMediaVault
#
# Installs a systemd service required by docker.service. The service waits up to 2
# minutes for every OMV shared folder (read from the OMV config at every boot) and the
# extra paths you enter to exist on a mounted disk (not on the root filesystem). If one
# is not ready Docker does not start, so containers never write to the system disk by mistake.
#
# Usage:
#   bash install.sh                      (interactive)
#   bash install.sh install -y           (all shared folders)
#   bash install.sh install --path /opt/appdata -y   (shared folders + a path)
#   bash install.sh uninstall
#
# Via curl:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/docker-wait-disks/install.sh)"
set -euo pipefail

# ---------------------------------------------------------------- defaults
MODE=""
PATH_ARG=""
NO_RESTART=0
ASSUME_YES=0
SERVICE=wait-disks.service
SERVICE_FILE=/etc/systemd/system/$SERVICE
CHECK_BIN=/usr/local/sbin/wait-disks-check

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
Docker always waits for every OMV shared folder.

Options:
  --path PATH    Extra path Docker waits for (repeat for several)
  --no-restart   Do not restart Docker now, the change applies at the next boot
  -y, --yes      Non-interactive, never prompt

Examples:
  $0
  $0 install -y
  $0 install --path /opt/appdata -y
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

# parse_paths "INPUT": numbers from MOUNTED or paths, separated by spaces or commas.
# "none" or nothing = no extra paths. Fills WAIT_PATHS, warns and returns 1 on the first bad entry.
parse_paths() {
	local m tokens=()
	WAIT_PATHS=()
	[[ $1 == none ]] && set -- ""
	read -r -a tokens <<<"${1//,/ }"
	for m in "${tokens[@]}"; do
		if [[ $m =~ ^[0-9]+$ ]]; then
			((m >= 1 && m <= ${#MOUNTED[@]})) || { warn "No mount point number $m"; return 1; }
			m=${MOUNTED[m - 1]}
		fi
		[[ $m == /* ]] || { warn "$m: not an absolute path"; return 1; }
		[[ $m == / ]] || m=${m%/}   # no realpath: a symlink must stay a symlink
		# Spaces, % and $ have a special meaning in unit files
		[[ $m =~ ^/[A-Za-z0-9._/@:+-]*$ ]] || { warn "$m: only letters, digits and . _ / @ : + - are supported"; return 1; }
		# Not ready now means the service fails to start, and Docker with it
		[[ -d $m ]] || { warn "$m does not exist, mount the disk or create it first"; return 1; }
		[[ $(findmnt -nT "$m" -o TARGET) != / ]] || { warn "$m is on the root filesystem, not on a mounted disk"; return 1; }
		[[ " ${WAIT_PATHS[*]} " == *" $m "* ]] || WAIT_PATHS+=("$m")
	done
}

# The check the service runs at boot
write_check() {   # write_check FILE
	cat >"$1" <<'CHECK'
#!/bin/bash
# Written by docker-wait-disks/install.sh, run by wait-disks.service before Docker.
# Waits until every OpenMediaVault shared folder (read from the OMV config) and every
# PATH is a directory on a mounted disk (not on the root filesystem).
#
# Usage: wait-disks-check [--list] [--tries N] [--interval SEC] [PATH...]
#   --list   check once and print every shared folder and path with its state
set -u
LIST=0; TRIES=40; INTERVAL=3; PATHS=()
while [ $# -gt 0 ]; do
	case $1 in
		--list)     LIST=1; TRIES=1 ;;
		--tries)    TRIES=$2; shift ;;
		--interval) INTERVAL=$2; shift ;;
		*)          PATHS+=("$1") ;;
	esac
	shift
done

ready() {   # a directory whose filesystem is not /; fails closed if findmnt fails
	local t
	[ -d "$1" ] || return 1
	t=$(findmnt -nT "$1" -o TARGET 2>/dev/null) || return 1
	[ -n "$t" ] && [ "$t" != / ]
}

# Prints "name<TAB>path" for every OMV shared folder; the path is empty when its
# filesystem is not in the OMV config. Shared folders on the root filesystem are skipped.
omv_shares() {
	local sf mp
	sf=$(omv-confdbadm read conf.system.sharedfolder 2>/dev/null) \
		|| { echo "omv-confdbadm read conf.system.sharedfolder failed"; return 1; }
	mp=$(omv-confdbadm read conf.system.filesystem.mountpoint 2>/dev/null) \
		|| { echo "omv-confdbadm read conf.system.filesystem.mountpoint failed"; return 1; }
	OMV_SF=$sf OMV_MP=$mp python3 - <<'PY'
import json, os, posixpath, sys

try:
    mounts = {m["uuid"]: m for m in (json.loads(os.environ["OMV_MP"]) or [])}
    shares = json.loads(os.environ["OMV_SF"]) or []
    lines = []
    for sf in shares:
        m = mounts.get(sf.get("mntentref"))
        if m is None:
            lines.append("%s\t" % sf["name"])
            continue
        d = (m.get("dir") or "").rstrip("/")
        if not d:
            continue   # on the root filesystem
        # Same path OMV uses: the filesystem's mount dir (/srv/dev-disk-by-uuid-...,
        # /srv/mergerfs/<pool>, ...) + the shared folder's relative path
        lines.append("%s\t%s" % (sf["name"], posixpath.join(d, sf.get("reldirpath") or "").rstrip("/")))
except Exception as e:
    print("unexpected omv-confdbadm output: %s: %s" % (type(e).__name__, e))
    sys.exit(1)
print("\n".join(lines))
PY
}

i=0
while [ "$i" -lt "$TRIES" ]; do
	i=$((i + 1))
	missing=(); report=()
	if list=$(omv_shares 2>&1); then
		while IFS=$'\t' read -r name p; do
			[ -n "$name" ] || continue
			if [ -z "$p" ]; then
				missing+=("shared folder $name: its filesystem is not in the OMV config")
				report+=("NOT READY  shared folder $name (filesystem not in the OMV config)")
			elif ready "$p"; then
				report+=("ready      shared folder $name ($p)")
			else
				missing+=("shared folder $name ($p)")
				report+=("NOT READY  shared folder $name ($p)")
			fi
		done <<<"$list"
	else
		missing+=("OMV shared folders, cannot read the OMV config: $list")
		report+=("NOT READY  OMV shared folders, cannot read the OMV config: $list")
	fi
	for p in "${PATHS[@]}"; do
		if ready "$p"; then report+=("ready      $p"); else missing+=("$p"); report+=("NOT READY  $p"); fi
	done

	if [ "$LIST" = 1 ]; then
		[ ${#report[@]} -eq 0 ] || printf '%s\n' "${report[@]}"
		[ ${#missing[@]} -eq 0 ]
		exit
	fi
	if [ ${#missing[@]} -eq 0 ]; then
		[ "$i" -gt 1 ] && echo "all ready after $(((i - 1) * INTERVAL))s"
		exit 0
	fi
	[ "$i" -eq 1 ] && printf 'waiting for: %s\n' "${missing[@]}"
	[ "$i" -lt "$TRIES" ] && sleep "$INTERVAL"
done
printf 'not ready: %s\n' "${missing[@]}" >&2
exit 1
CHECK
	chmod 755 "$1"
}

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
		--path)          [[ $# -ge 2 ]] || die "Missing value for $1"; PATH_ARG="${PATH_ARG:+$PATH_ARG }$2"; shift 2 ;;
		--no-restart)    NO_RESTART=1; shift ;;
		-y|--yes)        ASSUME_YES=1; shift ;;
		-h|--help)       usage 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done

[[ $EUID -eq 0 ]] || die "Run as root"
command -v omv-confdbadm >/dev/null || die "omv-confdbadm not found, only OpenMediaVault is supported"
[[ $ASSUME_YES -eq 1 ]] && INTERACTIVE=0

# Current extra paths, from the service file (old installs had the check inline)
CURRENT=""
if [[ -f $SERVICE_FILE ]]; then
	exec_line=$(sed -n 's/^ExecStart=//p' "$SERVICE_FILE" | head -n1)
	if [[ $exec_line == "$CHECK_BIN"* ]]; then
		for w in ${exec_line#"$CHECK_BIN"}; do
			case $w in
				-*) ;;
				*) CURRENT="${CURRENT:+$CURRENT }$w" ;;
			esac
		done
	else
		CURRENT=$(sed -n 's/.*for p in \([^;]*\); do.*/\1/p' "$SERVICE_FILE")
	fi
fi

describe_current() {
	echo "all shared folders${CURRENT:+ + $CURRENT}"
}

if [[ -z $MODE ]]; then
	MODE=install
	if [[ -f $SERVICE_FILE && $INTERACTIVE -eq 1 ]]; then
		info "$SERVICE is installed, Docker waits for: $(describe_current)"
		choose MODE "What do you want to do?" install \
			"install|Change what Docker waits for" \
			"uninstall|Uninstall"
	fi
fi

# ---------------------------------------------------------------- uninstall
if [[ $MODE == uninstall ]]; then
	if [[ -f $SERVICE_FILE ]]; then
		# Disable first: stopping a unit that docker.service still requires stops Docker too
		systemctl disable "$SERVICE" 2>/dev/null || true
		systemctl stop "$SERVICE" 2>/dev/null || true
		rm -f "$SERVICE_FILE" "$CHECK_BIN"
		systemctl daemon-reload
		ok "Removed $SERVICE, Docker no longer waits for the disks"
	else
		rm -f "$CHECK_BIN"
		warn "$SERVICE is not installed"
	fi
	exit 0
fi

# ---------------------------------------------------------------- checks
systemctl cat docker.service >/dev/null 2>&1 || die "docker.service not found, install Docker first"
command -v findmnt >/dev/null || die "findmnt not found (package util-linux)"
command -v python3 >/dev/null || die "python3 not found"

# ---------------------------------------------------------------- paths
MOUNTED=()
mapfile -t MOUNTED < <(findmnt -rn --real -o TARGET 2>/dev/null | grep -vE '^/$|^/(boot|snap|run|var/lib/docker)(/|$)|\\x' || true)
WAIT_PATHS=()
if [[ $INTERACTIVE -eq 1 ]]; then
	if [[ ${#MOUNTED[@]} -gt 0 ]]; then
		echo
		echo "  Mounted now:"
		for i in "${!MOUNTED[@]}"; do
			printf '    %2d) %s\n' "$((i + 1))" "${MOUNTED[i]}"
		done
		echo
	fi
	echo "  Docker waits for every shared folder. Paths outside the shared folders can be added."
	while :; do
		ask input "Other paths to wait for (numbers or paths, none = only the shared folders)" "${PATH_ARG:-${CURRENT:-none}}"
		parse_paths "$input" && break
	done
else
	parse_paths "${PATH_ARG:-$CURRENT}" || die "Invalid paths"
fi

CHECK_ARGS=("${WAIT_PATHS[@]}")

# Everything must be ready now, otherwise the service fails and Docker with it
TMP_CHECK=$(mktemp)
trap 'rm -f "$TMP_CHECK"' EXIT
write_check "$TMP_CHECK"
echo
info "Summary"
echo "    Service : $SERVICE_FILE (required by docker.service)"
echo "    Check   : $CHECK_BIN ${CHECK_ARGS[*]}"
echo "    Docker waits for:"
if ! report=$(bash "$TMP_CHECK" --list "${CHECK_ARGS[@]}"); then
	echo "$report" | sed 's/^/      /'
	die "Not everything is ready now, so Docker could not start. Mount it, fix the shared folder or leave it out"
fi
echo "$report" | sed 's/^/      /'
echo
if [[ $INTERACTIVE -eq 1 ]]; then
	confirm "Proceed?" || die "Cancelled"
fi

# ---------------------------------------------------------------- service
install -m 755 "$TMP_CHECK" "$CHECK_BIN"
ok "Wrote $CHECK_BIN"

cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Check the Docker data disks are mounted
After=local-fs.target remote-fs.target
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=180
# Up to 40 tries, 3 seconds apart
ExecStart=$CHECK_BIN ${CHECK_ARGS[*]}

[Install]
RequiredBy=docker.service
EOF
ok "Wrote $SERVICE_FILE"

systemctl daemon-reload
# enable --now, not restart: restarting a unit that docker.service requires restarts Docker too
systemctl enable --now "$SERVICE" >/dev/null 2>&1 || die "$SERVICE failed: journalctl -u $SERVICE"
ok "$SERVICE enabled and started"
systemctl --no-pager status "$SERVICE" || true

# ---------------------------------------------------------------- docker
if [[ $NO_RESTART -eq 1 ]]; then
	info "Docker not restarted, the dependency applies from the next boot or Docker restart"
elif confirm "Restart Docker now? (running containers restart too)"; then
	systemctl restart docker || die "Docker failed to restart: journalctl -u docker"
	ok "Docker restarted"
else
	info "Docker not restarted, the dependency applies from the next boot or Docker restart"
fi

cat <<EOF

  Check: $CHECK_BIN --list ${CHECK_ARGS[*]}
         systemctl status $SERVICE
  If something is not ready 2 minutes after boot, Docker stays down. Fix it, then: systemctl start docker
  Remove: bash install.sh uninstall
EOF
