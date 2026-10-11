#!/usr/bin/env bash
# CPU frequency governor at boot for Debian / Ubuntu / Proxmox VE
#
# Installs cpupower (linux-cpupower, or linux-tools on Ubuntu), lets you pick one of the governors the CPU supports
# and installs a systemd service that sets it on every boot.
#
# Usage:
#   bash install.sh                          (interactive: pick a governor)
#   bash install.sh install --governor schedutil -y
#   bash install.sh uninstall
#
# Via curl:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/cpupower/install.sh)"
set -euo pipefail

# ---------------------------------------------------------------- defaults
MODE=""
GOVERNOR=""
ASSUME_YES=0
SERVICE=cpupower.service
SERVICE_FILE=/etc/systemd/system/$SERVICE
CPUFREQ=/sys/devices/system/cpu/cpu0/cpufreq

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
  --governor NAME   Governor to set at boot, e.g. schedutil, performance, powersave
                    (asked if omitted; must be one the CPU driver supports)
  -y, --yes         Non-interactive, never prompt

Examples:
  $0
  $0 install -y --governor performance
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
	local __ans
	ask __ans "$1 (Y/n)" "Y"
	[[ $__ans =~ ^[Yy] ]]
}

read_sys() { cat "$CPUFREQ/$1" 2>/dev/null || true; }

# describe GOVERNOR DRIVER
describe() {
	case "$1" in
		performance)  echo "always the highest frequency: lowest latency, most power and heat" ;;
		powersave)
			if [[ $2 == intel_pstate || $2 == amd-pstate* ]]; then
				echo "$2 picks the frequency itself, favouring efficiency (normal default)"
			else
				echo "always the lowest frequency: least power, slowest"
			fi ;;
		schedutil)    echo "follows the scheduler's CPU load: balanced (kernel default)" ;;
		ondemand)     echo "jumps to high frequency as soon as load rises" ;;
		conservative) echo "raises the frequency gradually with load" ;;
		*)            echo "" ;;
	esac
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
		--governor) GOVERNOR=$2; shift 2 ;;
		-y|--yes)   ASSUME_YES=1; shift ;;
		-h|--help)  usage 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done

[[ $EUID -eq 0 ]] || die "Run as root"
[[ -f /etc/debian_version ]] || die "Only Debian / Ubuntu / Proxmox VE is supported"
[[ $ASSUME_YES -eq 1 ]] && INTERACTIVE=0
MODE=${MODE:-install}

# ---------------------------------------------------------------- uninstall
if [[ $MODE == uninstall ]]; then
	if [[ -f $SERVICE_FILE ]]; then
		systemctl disable --now "$SERVICE" 2>/dev/null || true
		rm -f "$SERVICE_FILE"
		systemctl daemon-reload
		ok "Removed $SERVICE (the current governor stays until the next reboot)"
	else
		warn "$SERVICE is not installed"
	fi
	echo "  cpupower (linux-cpupower / linux-tools) is kept"
	exit 0
fi

# ---------------------------------------------------------------- cpufreq support
[[ -d $CPUFREQ ]] || die "No CPU frequency scaling on this machine ($CPUFREQ missing). Is it a VM, or is the cpufreq driver disabled in the BIOS?"
DRIVER=$(read_sys scaling_driver)
CURRENT=$(read_sys scaling_governor)
read -r -a GOVERNORS <<<"$(read_sys scaling_available_governors)"
# userspace needs a fixed frequency, not useful for a boot-time profile
mapfile -t GOVERNORS < <(printf '%s\n' "${GOVERNORS[@]}" | grep -vx userspace || true)
[[ ${#GOVERNORS[@]} -gt 0 ]] || die "The $DRIVER driver reports no usable governors"

# ---------------------------------------------------------------- install linux-cpupower
# Debian / Proxmox: linux-cpupower. Ubuntu: cpupower comes with linux-tools for the
# running kernel; /usr/bin/cpupower is a wrapper that needs the tools of the booted
# kernel, so the kernel flavour's metapackage (e.g. linux-tools-generic) is installed
# too, otherwise the service fails after the next kernel upgrade.
ubuntu_tools_pkgs() {
	local meta
	printf '%s\n' linux-tools-common "linux-tools-$(uname -r)"
	# installed kernel metapackage, e.g. linux-image-generic or linux-image-generic-hwe-24.04
	meta=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-image-*' 2>/dev/null \
		| awk '$1 == "ii" && $2 !~ /[0-9]+\.[0-9]+\.[0-9]+-/ { print $2; exit }')
	[[ -n $meta ]] && echo "${meta/linux-image-/linux-tools-}"
	return 0
}
cpupower_works() { command -v cpupower >/dev/null 2>&1 && cpupower --version >/dev/null 2>&1; }

OS_ID=$(. /etc/os-release 2>/dev/null && echo "${ID:-}")
info "Checking cpupower"
if ! cpupower_works; then
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	if [[ $OS_ID == ubuntu ]]; then
		mapfile -t pkgs < <(ubuntu_tools_pkgs)
		info "Installing ${pkgs[*]}"
		apt-get install -y -qq "${pkgs[@]}" >/dev/null || die "Installing ${pkgs[*]} failed"
	else
		apt-get install -y -qq linux-cpupower >/dev/null || die "Installing linux-cpupower failed"
	fi
fi
cpupower_works || die "cpupower does not run (on Ubuntu: apt install linux-tools-$(uname -r))"
CPUPOWER=$(command -v cpupower)
ok "cpupower: $CPUPOWER"

# ---------------------------------------------------------------- pick a governor
# Default: the governor of an existing service, otherwise the current one
if [[ -z $GOVERNOR && -f $SERVICE_FILE ]]; then
	GOVERNOR=$(sed -n 's/.*frequency-set -g \([a-z_]*\).*/\1/p' "$SERVICE_FILE")
fi
if [[ $INTERACTIVE -eq 1 ]]; then
	echo
	echo "  CPU driver      : ${DRIVER:-unknown}"
	echo "  Current governor: ${CURRENT:-unknown}"
	echo
	opts=()
	for g in "${GOVERNORS[@]}"; do
		mark=""; [[ $g == "$CURRENT" ]] && mark=" (current)"
		opts+=("$g|$(printf '%-13s' "$g") $(describe "$g" "$DRIVER")$mark")
	done
	choose GOVERNOR "Governor to set at boot" "${GOVERNOR:-$CURRENT}" "${opts[@]}"
fi
[[ -n $GOVERNOR ]] || die "--governor is required with -y. Available: ${GOVERNORS[*]}"
[[ " ${GOVERNORS[*]} " == *" $GOVERNOR "* ]] || die "Governor '$GOVERNOR' is not supported by the $DRIVER driver. Available: ${GOVERNORS[*]}"

if systemctl is-active --quiet power-profiles-daemon.service 2>/dev/null; then
	warn "power-profiles-daemon is running and may change the governor again later"
fi

echo
info "Summary"
echo "    Driver   : $DRIVER"
echo "    Governor : $CURRENT -> $GOVERNOR"
echo "    Service  : $SERVICE_FILE (runs at every boot)"
echo
if [[ $INTERACTIVE -eq 1 ]]; then
	confirm "Proceed?" || die "Cancelled"
fi

# ---------------------------------------------------------------- service
cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Set CPU governor to $GOVERNOR
After=multi-user.target
After=power-profiles-daemon.service

[Service]
Type=oneshot
ExecStart=$CPUPOWER frequency-set -g $GOVERNOR

[Install]
WantedBy=multi-user.target
EOF
ok "Wrote $SERVICE_FILE"

systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1
# oneshot: restart runs it again now, even if it already ran at boot
systemctl restart "$SERVICE" || die "$SERVICE failed: journalctl -u $SERVICE"
ok "$SERVICE enabled and started"

total=0; wrong=0
for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
	[[ -f $f ]] || continue
	total=$((total + 1))
	[[ $(cat "$f") == "$GOVERNOR" ]] || wrong=$((wrong + 1))
done
if [[ $wrong -eq 0 ]]; then
	ok "Governor is now $GOVERNOR on all $total CPUs"
else
	warn "$wrong of $total CPUs are not on $GOVERNOR. Check: cpupower frequency-info"
fi

cat <<EOF

  Check: cpupower frequency-info
  Change: run this script again, or edit $SERVICE_FILE
EOF
