#!/usr/bin/env bash
# Make Docker wait for its data disks at boot on Debian / Ubuntu / Proxmox VE
#
# Installs a systemd service required by docker.service. The service waits up to 2
# minutes for the paths you enter to exist on a mounted disk (not on the root filesystem).
# Paths can be mount points, folders on a disk or symlinks to them. If one is not ready
# Docker does not start, so containers never write to the system disk by mistake.
#
# Usage:
#   bash install.sh                      (interactive: enter the paths)
#   bash install.sh install --path /volume1/appdata --path /volume2/storage -y
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
  --path PATH    Path Docker waits for (repeat for several)
  --no-restart   Do not restart Docker now, the change applies at the next boot
  -y, --yes      Non-interactive, never prompt

Examples:
  $0
  $0 install --path /volume1/appdata --path /volume2/storage -y
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

confirm() {
	local __yn
	ask __yn "$1 (Y/n)" "Y"
	[[ $__yn =~ ^[Yy] ]]
}

# parse_paths "INPUT": numbers from MOUNTED or paths, separated by spaces or commas.
# Fills WAIT_PATHS, warns and returns 1 on the first bad entry.
parse_paths() {
	local m tokens=()
	WAIT_PATHS=()
	read -r -a tokens <<<"${1//,/ }"
	[[ ${#tokens[@]} -gt 0 ]] || { warn "Enter at least one path"; return 1; }
	for m in "${tokens[@]}"; do
		if [[ $m =~ ^[0-9]+$ ]]; then
			((m >= 1 && m <= ${#MOUNTED[@]})) || { warn "No mount point number $m"; return 1; }
			m=${MOUNTED[m - 1]}
		fi
		[[ $m == /* ]] || { warn "$m: not an absolute path"; return 1; }
		[[ $m == / ]] || m=${m%/}   # no realpath: a symlink must stay a symlink
		# Spaces, % and $ have a special meaning in unit files and in the check
		[[ $m =~ ^/[A-Za-z0-9._/@:+-]*$ ]] || { warn "$m: only letters, digits and . _ / @ : + - are supported"; return 1; }
		# Not ready now means the service fails to start, and Docker with it
		[[ -d $m ]] || { warn "$m does not exist, mount the disk or create it first"; return 1; }
		[[ $(findmnt -nT "$m" -o TARGET) != / ]] || { warn "$m is on the root filesystem, not on a mounted disk"; return 1; }
		[[ " ${WAIT_PATHS[*]} " == *" $m "* ]] || WAIT_PATHS+=("$m")
	done
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
		--path)       PATH_ARG="${PATH_ARG:+$PATH_ARG }$2"; shift 2 ;;
		--no-restart) NO_RESTART=1; shift ;;
		-y|--yes)     ASSUME_YES=1; shift ;;
		-h|--help)    usage 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done

[[ $EUID -eq 0 ]] || die "Run as root"
[[ -f /etc/debian_version ]] || die "Only Debian / Ubuntu / Proxmox VE is supported"
[[ $ASSUME_YES -eq 1 ]] && INTERACTIVE=0

CURRENT=""
[[ -f $SERVICE_FILE ]] && CURRENT=$(sed -n 's/.*for p in \([^;]*\); do.*/\1/p' "$SERVICE_FILE")

if [[ -z $MODE ]]; then
	MODE=install
	if [[ -f $SERVICE_FILE && $INTERACTIVE -eq 1 ]]; then
		info "$SERVICE is installed, Docker waits for: ${CURRENT:-nothing}"
		choose MODE "What do you want to do?" install \
			"install|Change the paths" \
			"uninstall|Uninstall"
	fi
fi

# ---------------------------------------------------------------- uninstall
if [[ $MODE == uninstall ]]; then
	if [[ -f $SERVICE_FILE ]]; then
		# Disable first: stopping a unit that docker.service still requires stops Docker too
		systemctl disable "$SERVICE" 2>/dev/null || true
		systemctl stop "$SERVICE" 2>/dev/null || true
		rm -f "$SERVICE_FILE"
		systemctl daemon-reload
		ok "Removed $SERVICE, Docker no longer waits for the paths"
	else
		warn "$SERVICE is not installed"
	fi
	exit 0
fi

# ---------------------------------------------------------------- checks
systemctl cat docker.service >/dev/null 2>&1 || die "docker.service not found, install Docker first"
command -v findmnt >/dev/null || die "findmnt not found (package util-linux)"

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
	while :; do
		ask input "Paths to wait for (numbers or paths, separated by spaces)" "${PATH_ARG:-$CURRENT}"
		parse_paths "$input" && break
	done
else
	[[ -n ${PATH_ARG:-$CURRENT} ]] || die "No paths, use --path PATH"
	parse_paths "${PATH_ARG:-$CURRENT}" || die "Invalid paths"
fi

echo
info "Summary"
echo "    Service : $SERVICE_FILE (required by docker.service)"
echo "    Docker waits for:"
printf '      %s\n' "${WAIT_PATHS[@]}"
echo
if [[ $INTERACTIVE -eq 1 ]]; then
	confirm "Proceed?" || die "Cancelled"
fi

# ---------------------------------------------------------------- service
{
	cat <<EOF
[Unit]
Description=Check paths are backed by mounted disks
After=local-fs.target remote-fs.target
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=180
EOF
	# 40 tries, 3 seconds apart. $$ is a literal $ in a unit file
	printf 'ExecStart=/bin/bash -c '\''for i in $$(seq 40); do ok=1; for p in %s; do [ -d "$$p" ] && [ "$$(findmnt -nT "$$p" -o TARGET)" != "/" ] || { ok=0; echo "not ready: $$p" >&2; }; done; [ $$ok = 1 ] && exit 0; sleep 3; done; exit 1'\''\n' "${WAIT_PATHS[*]}"
	cat <<EOF

[Install]
RequiredBy=docker.service
EOF
} >"$SERVICE_FILE"
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

  Check: systemctl status $SERVICE
         systemctl list-dependencies docker | grep wait-disks
  If a path is not ready 2 minutes after boot, Docker stays down. Fix it, then: systemctl start docker
  Remove: bash install.sh uninstall
EOF
