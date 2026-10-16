#!/usr/bin/env bash
# Turbo unlock at boot for Debian / Ubuntu / Proxmox VE
#
# Some BIOSes (e.g. Dell Wyse 5070) set the "turbo disable" bit 38 of IA32_MISC_ENABLE
# (MSR 0x1a0), which keeps the CPU at its base clock (1.5 GHz on the J4105 / J5005).
# Installs msr-tools and a systemd service that clears the bit on every CPU and turns
# turbo back on in the cpufreq driver at every boot.
#
# Usage:
#   bash install.sh                (interactive)
#   bash install.sh install -y
#   bash install.sh uninstall
#
# Via curl:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/turbo-unlock/install.sh)"
set -euo pipefail

# ---------------------------------------------------------------- defaults
MODE=""
ASSUME_YES=0
SERVICE=turbo-unlock.service
SERVICE_FILE=/etc/systemd/system/$SERVICE
SCRIPT_FILE=/usr/local/sbin/turbo-unlock.sh
NO_TURBO=/sys/devices/system/cpu/intel_pstate/no_turbo
BOOST=/sys/devices/system/cpu/cpufreq/boost
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
  -y, --yes   Non-interactive, never prompt

Examples:
  $0
  $0 install -y
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

confirm() {
	local __ans
	ask __ans "$1 (Y/n)" "Y"
	[[ $__ans =~ ^[Yy] ]]
}

mhz() { local k; k=$(cat "$CPUFREQ/$1" 2>/dev/null) && echo "$((k / 1000)) MHz" || echo unknown; }

# Turbo state of the cpufreq driver: on / off / unknown
driver_turbo() {
	if [[ -f $NO_TURBO ]]; then
		[[ $(cat "$NO_TURBO") == 0 ]] && echo on || echo off
	elif [[ -f $BOOST ]]; then
		[[ $(cat "$BOOST") == 1 ]] && echo on || echo off
	else
		echo unknown
	fi
}

# Prints "locked/total": CPUs with MSR 0x1a0 bit 38 set
msr_locked() {
	local d v locked=0 total=0
	for d in /dev/cpu/[0-9]*; do
		[[ -e $d/msr ]] || continue
		total=$((total + 1))
		v=$(rdmsr -p "${d##*/}" -c 0x1a0) || continue
		(( (v >> 38) & 1 )) && locked=$((locked + 1))
	done
	echo "$locked/$total"
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
		-y|--yes)  ASSUME_YES=1; shift ;;
		-h|--help) usage 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done

[[ $EUID -eq 0 ]] || die "Run as root"
[[ -f /etc/debian_version ]] || die "Only Debian / Ubuntu / Proxmox VE is supported"
[[ $ASSUME_YES -eq 1 ]] && INTERACTIVE=0
MODE=${MODE:-install}

# ---------------------------------------------------------------- uninstall
if [[ $MODE == uninstall ]]; then
	if [[ -f $SERVICE_FILE || -f $SCRIPT_FILE ]]; then
		systemctl disable "$SERVICE" 2>/dev/null || true
		rm -f "$SERVICE_FILE" "$SCRIPT_FILE"
		systemctl daemon-reload
		ok "Removed $SERVICE and $SCRIPT_FILE (turbo stays on until the next reboot)"
	else
		warn "$SERVICE is not installed"
	fi
	echo "  msr-tools is kept"
	exit 0
fi

# ---------------------------------------------------------------- checks
grep -qm1 'vendor_id.*GenuineIntel' /proc/cpuinfo || die "Not an Intel CPU, MSR 0x1a0 bit 38 does not apply"
if grep -qm1 '^flags.* hypervisor' /proc/cpuinfo; then
	die "Running in a VM. Run this on the host"
fi
if grep -qs '\[\(integrity\|confidentiality\)\]' /sys/kernel/security/lockdown; then
	die "Kernel lockdown is active (usually Secure Boot), it blocks MSR writes. Disable Secure Boot in the BIOS and run again"
fi

PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
CPU_MODEL=$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -n1)
[[ $PRODUCT == *"Wyse 5070"* ]] || warn "Made for the Dell Wyse 5070, this is: $PRODUCT"

# ---------------------------------------------------------------- install msr-tools
info "Checking msr-tools"
if ! command -v rdmsr >/dev/null 2>&1 || ! command -v wrmsr >/dev/null 2>&1; then
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq msr-tools >/dev/null || die "Installing msr-tools failed"
fi
modprobe msr || die "Cannot load the msr kernel module"
[[ -e /dev/cpu/0/msr ]] || die "/dev/cpu/0/msr is missing after loading the msr module"
ok "msr-tools: $(command -v wrmsr)"

# ---------------------------------------------------------------- state
LOCKED=$(msr_locked)
echo
echo "  Machine     : $PRODUCT"
echo "  CPU         : $CPU_MODEL"
echo "  CPU driver  : $(cat "$CPUFREQ/scaling_driver" 2>/dev/null || echo none)"
echo "  Max freq    : $(mhz cpuinfo_max_freq) (now $(mhz scaling_max_freq) allowed)"
echo "  BIOS lock   : on ${LOCKED%/*} of ${LOCKED#*/} CPUs (MSR 0x1a0 bit 38)"
echo "  Driver turbo: $(driver_turbo)"
echo
if [[ ${LOCKED%/*} == 0 && $(driver_turbo) != off ]]; then
	info "Turbo is not locked right now. The service still clears the lock at every boot"
fi

info "Summary"
echo "    Script  : $SCRIPT_FILE"
echo "    Service : $SERVICE_FILE (runs at every boot)"
echo
warn "Turbo makes the CPU hotter. On a fanless Wyse keep the vents free and watch the temperature (sensors)"
if [[ $INTERACTIVE -eq 1 ]]; then
	confirm "Proceed?" || die "Cancelled"
fi

# ---------------------------------------------------------------- script
cat >"$SCRIPT_FILE" <<'EOF'
#!/bin/sh
# Clears the BIOS "turbo disable" bit (IA32_MISC_ENABLE = MSR 0x1a0, bit 38) on every CPU,
# then turns turbo on in the cpufreq driver. Installed by turbo-unlock/install.sh.
set -eu
modprobe msr

for d in /dev/cpu/[0-9]*; do
	cpu=${d##*/}
	v=$(rdmsr -p "$cpu" -c 0x1a0)
	n=$(( v & ~(1 << 38) ))
	[ "$n" -eq "$(( v ))" ] || wrmsr -p "$cpu" 0x1a0 "$(printf '0x%x' "$n")"
done

NO_TURBO=/sys/devices/system/cpu/intel_pstate/no_turbo
BOOST=/sys/devices/system/cpu/cpufreq/boost
if [ -f "$NO_TURBO" ]; then
	# intel_pstate may still remember "turbo disabled by BIOS" from boot: restart it
	# (passive -> active) so it reads the MSR again, then allow turbo
	if ! echo 0 >"$NO_TURBO" 2>/dev/null; then
		echo passive >/sys/devices/system/cpu/intel_pstate/status
		echo active >/sys/devices/system/cpu/intel_pstate/status
		echo 0 >"$NO_TURBO"
	fi
elif [ -f "$BOOST" ]; then
	echo 1 >"$BOOST"
fi
EOF
chmod 755 "$SCRIPT_FILE"
ok "Wrote $SCRIPT_FILE"

# ---------------------------------------------------------------- service
cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Clear the BIOS turbo lock (MSR 0x1a0 bit 38)
After=systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SCRIPT_FILE

[Install]
WantedBy=multi-user.target
EOF
ok "Wrote $SERVICE_FILE"

systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1
# oneshot + RemainAfterExit: restart runs it again now, even if it already ran at boot
systemctl restart "$SERVICE" || die "$SERVICE failed: journalctl -u $SERVICE"
ok "$SERVICE enabled and started"

# ---------------------------------------------------------------- verify
LOCKED=$(msr_locked)
TURBO=$(driver_turbo)
if [[ ${LOCKED%/*} == 0 ]]; then
	ok "BIOS lock cleared on all ${LOCKED#*/} CPUs"
else
	warn "BIOS lock still set on ${LOCKED%/*} of ${LOCKED#*/} CPUs"
fi
if [[ $TURBO == off ]]; then
	warn "The cpufreq driver still has turbo off. Check: journalctl -u $SERVICE, dmesg | grep -i turbo"
else
	ok "Turbo: $TURBO, max freq $(mhz cpuinfo_max_freq) ($(mhz scaling_max_freq) allowed)"
fi

cat <<EOF

  Check: grep MHz /proc/cpuinfo   (under load, e.g. stress -c $(nproc))
         rdmsr -a -f 38:38 0x1a0  (0 = unlocked)
  Remove: bash install.sh uninstall
EOF
