#!/usr/bin/env bash
# PCIe passthrough fix for Proxmox VE on the Dell Wyse 5070 (PCIe slot / extended chassis)
#
#   setup     : kernel options (IOMMU, ACS override), bind the card in the PCIe slot to
#               vfio-pci at boot (before the host driver), keep it out of D3 idle.
#               Works for any card: NIC (Intel i226 / i225 / X520...), GPU (AMD Radeon...)
#   check     : read-only report of IOMMU, IOMMU groups, the card's driver and power state
#   uninstall : undo the host changes made by setup
#
# Steps 1-3 of:
#   https://liamtc.tech/posts/pcie-passthrough-dell-wyse-5070-amd-radeon/
#
# Usage:
#   bash install.sh                      (interactive wizard)
#   bash install.sh setup [options]
#   bash install.sh check
#   bash install.sh uninstall
#
# Via curl:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/pcie-passthrough/install.sh)"
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/pcie-passthrough/install.sh)" install.sh check
set -euo pipefail

# ---------------------------------------------------------------- defaults
MODE=""
DEV_ARG=""           # comma separated PCI addresses, e.g. 01:00.0
ACS=1                # 1 = pcie_acs_override=downstream,multifunction
D3=1                 # 1 = vfio-pci disable_idle_d3=1 (card stays in D0 while unused)
ASSUME_YES=0
GRUB_FILE=/etc/default/grub
SDBOOT_FILE=/etc/kernel/cmdline
MODULES_FILE=/etc/modules
MODPROBE_FILE=/etc/modprobe.d/vfio.conf
GPU_MODPROBE_FILE=/etc/modprobe.d/gpu-passthrough.conf
BLACKLIST_FILE=/etc/modprobe.d/blacklist.conf
STATE_DIR=/var/lib/pcie-passthrough
STATE_FILE=$STATE_DIR/state
MARK_BEGIN="# >>> pcie-passthrough"
MARK_END="# <<< pcie-passthrough"
MANAGED="# Managed by pcie-passthrough/install.sh"
ACS_OPT=pcie_acs_override=downstream,multifunction
PCI=/sys/bus/pci/devices

# ---------------------------------------------------------------- helpers
c_info=$'\e[1;34m'; c_ok=$'\e[1;32m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_off=$'\e[0m'
info() { echo "${c_info}==>${c_off} $*"; }
ok()   { echo "${c_ok}[OK]${c_off} $*"; }
warn() { echo "${c_warn}[WARN]${c_off} $*" >&2; }
die()  { echo "${c_err}[ERROR]${c_off} $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $0 [setup|check|uninstall] [options]

Run without arguments for an interactive wizard. Options given on the
command line become the defaults in the wizard (or are used as-is with -y).

Setup options:
  --dev ADDR[,ADDR]  PCI address of the card(s), e.g. 01:00.0. All functions of
                     the same slot (ports of a multi-port NIC, GPU HDMI audio) are included.
  --no-acs           Do not add $ACS_OPT
  --no-d3            Do not add disable_idle_d3=1 to vfio-pci
  -y, --yes          Non-interactive, never prompt

Examples:
  $0
  $0 check
  $0 setup -y --dev 01:00.0
  $0 setup -y --dev 01:00.0 --no-acs
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

confirm_no() {
	local __yn
	ask __yn "$1 (y/N)" "N"
	[[ $__yn =~ ^[Yy] ]]
}

# ask_yn VAR "Question" current(0|1)   -> VAR = 0|1, default = current
ask_yn() {
	local __var=$1 __q=$2 __cur=$3 __v
	if [[ $__cur -eq 1 ]]; then
		if confirm "$__q"; then __v=1; else __v=0; fi
	else
		if confirm_no "$__q"; then __v=1; else __v=0; fi
	fi
	printf -v "$__var" '%s' "$__v"
}

# ---------------------------------------------------------------- pci helpers
# norm_addr 01:00.0 -> 0000:01:00.0
norm_addr() {
	local a=${1,,}
	[[ $a =~ ^[0-9a-f]{4}: ]] || a="0000:$a"
	printf '%s' "$a"
}
pci_class()  { cat "$PCI/$1/class"; }
pci_vendor() { sed 's/^0x//' "$PCI/$1/vendor"; }
pci_id()     { printf '%s:%s' "$(pci_vendor "$1")" "$(sed 's/^0x//' "$PCI/$1/device")"; }
pci_desc()   { lspci -s "$1" 2>/dev/null | cut -d' ' -f2- || echo "unknown device"; }
pci_driver() { [[ -e $PCI/$1/driver ]] && basename "$(readlink "$PCI/$1/driver")" || echo "-"; }
pci_group()  { [[ -e $PCI/$1/iommu_group ]] && basename "$(readlink "$PCI/$1/iommu_group")" || echo "-"; }
pci_power()  { [[ -f $PCI/$1/power_state ]] && cat "$PCI/$1/power_state" || echo "-"; }
pci_bootvga() { [[ -f $PCI/$1/boot_vga ]] && cat "$PCI/$1/boot_vga" || echo 0; }
is_gpu()     { [[ $(pci_class "$1") == 0x03* ]]; }
# all functions in the same slot: 0000:01:00.0 -> 0000:01:00.0 0000:01:00.1 ...
slot_funcs() {
	local f
	for f in "$PCI/${1%.*}".*; do [[ -e $f ]] && basename "$f"; done
}

# Devices behind a PCIe port (bus != 00), no bridges: the slot card and the onboard NIC
list_cards() {
	local d a
	for d in "$PCI"/*; do
		a=$(basename "$d")
		[[ ${a:5:2} == 00 ]] && continue
		[[ $(cat "$d/class") == 0x0604* ]] && continue
		echo "$a"
	done
}

# Network interfaces of a device and the bridge they are in: "enp1s0(vmbr0) ..."
pci_netifs() {
	local n out=""
	for n in "$PCI/$1"/net/*; do
		[[ -e $n ]] || continue
		n=$(basename "$n")
		if [[ -e /sys/class/net/$n/master ]]; then
			out+="$n($(basename "$(readlink "/sys/class/net/$n/master")")) "
		else
			out+="$n "
		fi
	done
	printf '%s' "${out% }"
}

iommu_active() { [[ -n $(ls -A /sys/kernel/iommu_groups 2>/dev/null) ]]; }

# ---------------------------------------------------------------- kernel cmdline helpers
# GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub is always updated.
# On systemd-boot (ZFS on UEFI) the cmdline lives in /etc/kernel/cmdline, so it is updated too.
uses_systemd_boot() {
	[[ -f $SDBOOT_FILE ]] && command -v proxmox-boot-tool >/dev/null \
		&& proxmox-boot-tool status 2>/dev/null | grep -q 'uefi'
}

boot_type() { if uses_systemd_boot; then echo systemd-boot; else echo grub; fi; }

re_esc() { printf '%s' "${1//./[.]}"; }   # literal dot in ERE
grub_has() { grep -Eq "^GRUB_CMDLINE_LINUX_DEFAULT=\"([^\"]* )?$(re_esc "$1")( [^\"]*)?\"" "$GRUB_FILE"; }
sdboot_has() { grep -Eq "(^| )$(re_esc "$1")( |\$)" "$SDBOOT_FILE"; }

backup() { cp -a "$1" "$1.bak.$(date +%Y%m%d-%H%M%S)"; }

# cmdline_add PARAM...  -> prints the params that were actually added
cmdline_add() {
	local p grub_bak=0 sd_bak=0 sd=0
	uses_systemd_boot && sd=1
	for p in "$@"; do
		local added=0
		if [[ -f $GRUB_FILE ]] && ! grub_has "$p"; then
			[[ $grub_bak -eq 1 ]] || { backup "$GRUB_FILE"; grub_bak=1; }
			sed -i -E "s|^(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*)\"|\1 $p\"|; s|^(GRUB_CMDLINE_LINUX_DEFAULT=\") |\1|" "$GRUB_FILE"
			added=1
		fi
		if [[ $sd -eq 1 ]] && ! sdboot_has "$p"; then
			[[ $sd_bak -eq 1 ]] || { backup "$SDBOOT_FILE"; sd_bak=1; }
			sed -i "1 s|\$| $p|" "$SDBOOT_FILE"
			added=1
		fi
		[[ $added -eq 1 ]] && echo "$p"
	done
	return 0
}

cmdline_remove() {
	local p
	for p in "$@"; do
		p=$(re_esc "$p")
		[[ -f $GRUB_FILE ]] && sed -i -E "/^GRUB_CMDLINE_LINUX_DEFAULT=/ { s/([\" ])$p( |\")/\1\2/; s/  +/ /g; s/\" /\"/; s/ \"\$/\"/ }" "$GRUB_FILE"
		[[ -f $SDBOOT_FILE ]] && sed -i -E "1 s/(^| )$p( |\$)/\1\2/; 1 s/  +/ /g; 1 s/^ +//; 1 s/ +\$//" "$SDBOOT_FILE"
	done
	return 0
}

refresh_boot() {
	if command -v proxmox-boot-tool >/dev/null && proxmox-boot-tool status >/dev/null 2>&1; then
		proxmox-boot-tool refresh
	else
		update-grub
	fi
}

# ---------------------------------------------------------------- marker block helpers
# Our lines live between MARK_BEGIN / MARK_END so they can be updated and removed cleanly
block_remove() { [[ -f $1 ]] && sed -i "\|^$MARK_BEGIN|,\|^$MARK_END|d" "$1"; return 0; }
# block_write FILE LINE...
block_write() {
	local f=$1; shift
	block_remove "$f"
	{ echo "$MARK_BEGIN"; printf '%s\n' "$@"; echo "$MARK_END"; } >>"$f"
}

state_get() { [[ -f $STATE_FILE ]] && sed -n "s/^$1=//p" "$STATE_FILE" || true; }
state_set() {
	mkdir -p "$STATE_DIR"
	touch "$STATE_FILE"
	sed -i "/^$1=/d" "$STATE_FILE"
	echo "$1=$2" >>"$STATE_FILE"
}

# ---------------------------------------------------------------- args
if [[ $# -gt 0 ]]; then
	case "$1" in
		setup|check|uninstall) MODE=$1; shift ;;
		-h|--help) usage 0 ;;
		-*) ;;
		*) usage 1 ;;
	esac
fi

while [[ $# -gt 0 ]]; do
	case "$1" in
		--dev)      DEV_ARG=$2; shift 2 ;;
		--no-acs)   ACS=0; shift ;;
		--no-d3)    D3=0; shift ;;
		-y|--yes)   ASSUME_YES=1; shift ;;
		-h|--help)  usage 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done

[[ $EUID -eq 0 ]] || die "Run as root"
command -v pveversion >/dev/null || die "Only Proxmox VE is supported"
command -v lspci >/dev/null || die "lspci not found. Install it with: apt install pciutils"
[[ $ASSUME_YES -eq 1 ]] && INTERACTIVE=0
if [[ -z $MODE ]]; then
	[[ $INTERACTIVE -eq 1 ]] || usage 1
	echo
	echo "  PCIe passthrough fix for Proxmox VE (Dell Wyse 5070)"
	echo
	choose MODE "What do you want to do?" setup \
		"setup|Set up passthrough of the PCIe card" \
		"check|Check the current state (read-only)" \
		"uninstall|Undo the host changes made by this script"
fi

PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)

# ---------------------------------------------------------------- check
if [[ $MODE == check ]]; then
	info "Host"
	echo "    Machine    : $PRODUCT"
	echo "    Proxmox    : $(pveversion)"
	echo "    Kernel     : $(uname -r)"
	echo "    Bootloader : $(boot_type)"
	echo "    Cmdline    : $(cat /proc/cmdline)"
	echo
	if iommu_active; then
		ok "IOMMU is active ($(ls /sys/kernel/iommu_groups | wc -l) groups)"
	else
		warn "IOMMU is not active. Enable 'Virtualization' and 'VT for Direct I/O' in the BIOS"
	fi
	if [[ -e /sys/firmware/acpi/tables/DMAR ]]; then
		ok "ACPI DMAR table present (VT-d on in the BIOS)"
	else
		warn "No ACPI DMAR table: VT-d is off in the BIOS"
	fi
	grep -qw pcie_acs_override /proc/cmdline && ok "ACS override is on"
	if [[ -d /sys/module/vfio_pci ]]; then
		ok "module vfio_pci loaded (disable_idle_d3=$(cat /sys/module/vfio_pci/parameters/disable_idle_d3 2>/dev/null || echo ?))"
	else
		warn "module vfio_pci not loaded"
	fi
	[[ -f $MODPROBE_FILE ]] && { echo; info "$MODPROBE_FILE"; sed 's/^/    /' "$MODPROBE_FILE"; }
	echo
	info "Devices behind PCIe ports"
	for a in $(list_cards); do
		g=$(pci_group "$a")
		nets=$(pci_netifs "$a")
		echo "    ${a#0000:}  [$(pci_id "$a")]  $(pci_desc "$a")"
		echo "        driver=$(pci_driver "$a")  group=$g  power=$(pci_power "$a")${nets:+  net=$nets}"
		if [[ $g != - ]]; then
			for d in /sys/kernel/iommu_groups/"$g"/devices/*; do
				d=$(basename "$d")
				[[ $d == "$a" ]] && continue
				echo "        same group: ${d#0000:} $(pci_desc "$d")"
			done
		fi
	done
	echo
	echo "  driver 'vfio-pci' and power 'D0' mean the card is ready for a VM."
	echo "  Every device in the card's IOMMU group goes to the VM together."
	exit 0
fi

# ---------------------------------------------------------------- uninstall
if [[ $MODE == uninstall ]]; then
	if [[ $INTERACTIVE -eq 1 ]]; then
		confirm "Remove kernel options, vfio-pci binding, modules and blacklist added by this script?" || die "Cancelled"
	fi
	if grep -qF "$MARK_BEGIN" "$MODULES_FILE" 2>/dev/null; then
		block_remove "$MODULES_FILE"
		ok "Removed modules from $MODULES_FILE"
	fi
	if grep -qF "$MARK_BEGIN" "$BLACKLIST_FILE" 2>/dev/null; then
		block_remove "$BLACKLIST_FILE"
		grep -q '[^[:space:]]' "$BLACKLIST_FILE" || rm -f "$BLACKLIST_FILE"
		ok "Removed driver blacklist from $BLACKLIST_FILE"
	fi
	if grep -qxF "$MANAGED" "$MODPROBE_FILE" 2>/dev/null; then
		rm -f "$MODPROBE_FILE"
		ok "Removed $MODPROBE_FILE"
	fi
	added=$(state_get CMDLINE_ADDED)
	if [[ -n $added ]]; then
		# shellcheck disable=SC2086
		cmdline_remove $added
		info "Refreshing bootloader"
		refresh_boot
		ok "Removed kernel options: $added"
	fi
	rm -rf "$STATE_DIR"
	info "Rebuilding initramfs"
	update-initramfs -u -k all
	echo
	ok "Host changes removed. Reboot to apply."
	warn "PCI devices in VM configs are not touched. Remove them under VM > Hardware"
	exit 0
fi

# ---------------------------------------------------------------- setup: checks
[[ $PRODUCT == *"Wyse 5070"* ]] || warn "Made for the Dell Wyse 5070, this is: $PRODUCT"
grep -q GenuineIntel /proc/cpuinfo || die "Intel CPU (VT-d) required"
if [[ ! -e /sys/firmware/acpi/tables/DMAR ]]; then
	warn "VT-d is off. In the BIOS enable Virtualization Support > 'Virtualization' and 'VT for Direct I/O'"
	warn "The kernel options are still written, they take effect once VT-d is on"
fi
if [[ -f $GPU_MODPROBE_FILE ]] && grep -q '^options vfio-pci' "$GPU_MODPROBE_FILE"; then
	warn "$GPU_MODPROBE_FILE (gpu-passthrough --bind) also sets vfio-pci ids, only one of them is used."
	warn "Run 'gpu-passthrough uninstall' or pass the GPU here instead"
fi

# ---------------------------------------------------------------- setup: device selection
mapfile -t CARDS < <(list_cards)
[[ ${#CARDS[@]} -gt 0 ]] || die "No device behind a PCIe port found. Is the card seated and powered?"

DEVS=()
if [[ $INTERACTIVE -eq 1 && -z $DEV_ARG ]]; then
	echo
	info "Devices behind PCIe ports (the slot card and the onboard NIC)"
	i=1; def=""
	for a in "${CARDS[@]}"; do
		nets=$(pci_netifs "$a")
		echo "    $i) ${a#0000:}  [$(pci_id "$a")]  $(pci_desc "$a")"
		echo "         driver=$(pci_driver "$a")  group=$(pci_group "$a")${nets:+  net=$nets}"
		# default: the first device that is not the onboard Realtek NIC
		[[ -z $def && $(pci_vendor "$a") != 10ec ]] && def=$i
		i=$((i + 1))
	done
	ask_valid picks "Device(s) to pass through, e.g. 1 or 1,2" "${def:-1}" '^[0-9]+(,[0-9]+)*$' "Enter numbers separated by commas"
	for n in ${picks//,/ }; do
		((n >= 1 && n <= ${#CARDS[@]})) || die "No device number $n"
		DEVS+=("${CARDS[n - 1]}")
	done
elif [[ -n $DEV_ARG ]]; then
	for g in ${DEV_ARG//,/ }; do
		a=$(norm_addr "$g")
		[[ -e $PCI/$a ]] || die "PCI device $g not found. List devices with: lspci -nn"
		DEVS+=("$a")
	done
else
	die "--dev is required with -y. List devices with: bash install.sh check"
fi

# Every function of each selected slot and their vendor:device IDs
FUNCS=(); IDS=(); GPU=0
for a in "${DEVS[@]}"; do
	for f in $(slot_funcs "$a"); do
		[[ " ${FUNCS[*]} " == *" $f "* ]] && continue
		FUNCS+=("$f")
		is_gpu "$f" && GPU=1
		id=$(pci_id "$f")
		[[ " ${IDS[*]} " == *" $id "* ]] || IDS+=("$id")
	done
done

# ---------------------------------------------------------------- setup: options
if [[ $INTERACTIVE -eq 1 ]]; then
	echo
	echo "  The Wyse 5070 puts the slot in the same IOMMU group as other devices."
	echo "  $ACS_OPT splits them into separate groups."
	echo "  It trusts isolation the hardware does not prove: only for a host you control."
	ask_yn ACS "Add the ACS override?" "$ACS"
	echo
	echo "  disable_idle_d3=1 keeps the card in D0 while no VM uses it. Fixes cards"
	echo "  (e.g. Intel i226) that do not wake up from D3 and make the VM fail to start."
	ask_yn D3 "Disable D3 idle in vfio-pci?" "$D3"
fi

# Kernel options (step 1)
CMDLINE=(intel_iommu=on iommu=pt)
[[ $ACS -eq 1 ]] && CMDLINE+=("$ACS_OPT")
# GPU: keep the generic framebuffer (sysfb/simplefb) off the card at boot
[[ $GPU -eq 1 ]] && CMDLINE+=(initcall_blacklist=sysfb_init)

# vfio-pci options + softdeps (step 3): vfio-pci loads before the host driver and claims the IDs
VFIO_OPTS="ids=$(IFS=,; echo "${IDS[*]}")"
[[ $D3 -eq 1 ]] && VFIO_OPTS+=" disable_idle_d3=1"
[[ $GPU -eq 1 ]] && VFIO_OPTS+=" disable_vga=1"

DRIVERS=(); BLACKLIST=()
for f in "${FUNCS[@]}"; do
	d=$(pci_driver "$f")
	[[ $d == - || $d == vfio-pci ]] || DRIVERS+=("${d//-/_}")
	if is_gpu "$f"; then
		case "$(pci_vendor "$f")" in
			1002) DRIVERS+=(amdgpu radeon); BLACKLIST+=(amdgpu radeon) ;;
			10de) DRIVERS+=(nouveau); BLACKLIST+=(nouveau) ;;
		esac
	fi
	[[ $(pci_class "$f") == 0x0403* ]] && DRIVERS+=(snd_hda_intel)
done
mapfile -t DRIVERS < <(printf '%s\n' "${DRIVERS[@]}" | grep -v '^$' | sort -u)
mapfile -t BLACKLIST < <(printf '%s\n' "${BLACKLIST[@]}" | grep -v '^$' | sort -u)
SOFTDEPS=()
for d in "${DRIVERS[@]}"; do
	modinfo -n "$d" >/dev/null 2>&1 && SOFTDEPS+=("$d")
done

# ---------------------------------------------------------------- setup: sanity checks
for f in "${FUNCS[@]}"; do
	for n in $(pci_netifs "$f"); do
		if [[ $n == *"("* ]]; then
			br=${n#*(}
			warn "${f#0000:} has ${n%%(*} in bridge ${br%)}"
			warn "If that is the management network the host goes offline after the reboot"
		fi
	done
	[[ $(pci_bootvga "$f") == 1 ]] && warn "${f#0000:} is the host's boot display. The host console goes blank, keep SSH / web UI working"
	g=$(pci_group "$f")
	if [[ $g != - ]]; then
		for d in /sys/kernel/iommu_groups/"$g"/devices/*; do
			d=$(basename "$d")
			[[ " ${FUNCS[*]} " == *" $d "* ]] && continue
			[[ $(pci_class "$d") == 0x0604* ]] && continue   # PCI bridges are fine
			warn "${f#0000:} shares IOMMU group $g with ${d#0000:} ($(pci_desc "$d"))$([[ $ACS -eq 1 ]] && echo ', the ACS override should split them')"
		done
	fi
done
for id in "${IDS[@]}"; do
	for d in "$PCI"/*; do
		d=$(basename "$d")
		[[ $(pci_id "$d") == "$id" ]] || continue
		[[ " ${FUNCS[*]} " == *" $d "* ]] && continue
		warn "${d#0000:} has the same ID $id and will also be bound to vfio-pci"
	done
done
if [[ -f $MODPROBE_FILE ]] && ! grep -qxF "$MANAGED" "$MODPROBE_FILE"; then
	warn "$MODPROBE_FILE exists and was not written by this script. It is backed up and replaced"
fi

# ---------------------------------------------------------------- setup: summary
echo
info "Summary"
echo "    Machine      : $PRODUCT"
echo "    Kernel       : $(uname -r), $(boot_type)"
echo "    Kernel opts  : ${CMDLINE[*]}"
for f in "${FUNCS[@]}"; do
	echo "    Device       : ${f#0000:} [$(pci_id "$f")] $(pci_desc "$f")  (driver now: $(pci_driver "$f"))"
done
echo "    $MODPROBE_FILE:"
echo "        options vfio-pci $VFIO_OPTS"
for d in "${SOFTDEPS[@]}"; do echo "        softdep $d pre: vfio-pci"; done
echo "    Modules      : vfio vfio_iommu_type1 vfio_pci -> $MODULES_FILE"
[[ ${#BLACKLIST[@]} -gt 0 ]] && echo "    Blacklist    : ${BLACKLIST[*]} -> $BLACKLIST_FILE"
echo
if [[ $INTERACTIVE -eq 1 ]]; then
	confirm "Proceed?" || die "Cancelled"
fi

# ---------------------------------------------------------------- setup: kernel cmdline (step 1)
REBOOT=0
prev=$(state_get CMDLINE_ADDED)
# ACS override turned off since the last run: take it back out
if [[ $ACS -eq 0 && " $prev " == *" $ACS_OPT "* ]]; then
	cmdline_remove "$ACS_OPT"
	prev=$(printf '%s\n' $prev | grep -vxF "$ACS_OPT" | tr '\n' ' ' | sed 's/ $//' || true)
	state_set CMDLINE_ADDED "$prev"
	REBOOT=2
	ok "Removed kernel option: $ACS_OPT"
fi
mapfile -t new < <(cmdline_add "${CMDLINE[@]}")
if [[ ${#new[@]} -gt 0 ]]; then
	state_set CMDLINE_ADDED "$(printf '%s\n' $prev "${new[@]}" | sort -u | tr '\n' ' ' | sed 's/ $//')"
	REBOOT=2
	ok "Added kernel options: ${new[*]}"
else
	ok "Kernel options already set: ${CMDLINE[*]}"
fi
if [[ $REBOOT -eq 2 ]]; then
	info "Refreshing bootloader"
	refresh_boot
	REBOOT=1
fi

# ---------------------------------------------------------------- setup: vfio-pci binding (step 3)
{
	echo "$MANAGED"
	echo "options vfio-pci $VFIO_OPTS"
	for d in "${SOFTDEPS[@]}"; do echo "softdep $d pre: vfio-pci"; done
} >"$MODPROBE_FILE.new"
if ! cmp -s "$MODPROBE_FILE.new" "$MODPROBE_FILE"; then
	[[ -f $MODPROBE_FILE ]] && ! grep -qxF "$MANAGED" "$MODPROBE_FILE" && backup "$MODPROBE_FILE"
	REBOOT=1
fi
mv "$MODPROBE_FILE.new" "$MODPROBE_FILE"
ok "vfio-pci will claim ${IDS[*]} at boot ($MODPROBE_FILE)"

# vfio-pci in /etc/modules so it also loads when the host driver is blacklisted
block_remove "$MODULES_FILE"
missing=()
for m in vfio vfio_iommu_type1 vfio_pci; do
	grep -Eq "^[[:space:]]*$m([[:space:]]|\$)" "$MODULES_FILE" 2>/dev/null || missing+=("$m")
done
if [[ ${#missing[@]} -gt 0 ]]; then
	block_write "$MODULES_FILE" "${missing[@]}"
	[[ "${missing[*]}" == "$(state_get MODULES_ADDED)" ]] || REBOOT=1
	state_set MODULES_ADDED "${missing[*]}"
	ok "Modules in $MODULES_FILE: ${missing[*]}"
else
	ok "Modules already in $MODULES_FILE"
fi

# GPU drivers blacklisted on the host (step 3)
if [[ ${#BLACKLIST[@]} -gt 0 ]]; then
	lines=()
	for m in "${BLACKLIST[@]}"; do lines+=("blacklist $m"); done
	old=$(sed -n "\|^$MARK_BEGIN|,\|^$MARK_END|p" "$BLACKLIST_FILE" 2>/dev/null || true)
	block_write "$BLACKLIST_FILE" "${lines[@]}"
	[[ $old == "$(sed -n "\|^$MARK_BEGIN|,\|^$MARK_END|p" "$BLACKLIST_FILE")" ]] || REBOOT=1
	ok "Blacklisted ${BLACKLIST[*]} in $BLACKLIST_FILE"
elif grep -qF "$MARK_BEGIN" "$BLACKLIST_FILE" 2>/dev/null; then
	block_remove "$BLACKLIST_FILE"
	grep -q '[^[:space:]]' "$BLACKLIST_FILE" || rm -f "$BLACKLIST_FILE"
	REBOOT=1
	ok "Removed old driver blacklist from $BLACKLIST_FILE"
fi

if [[ $REBOOT -eq 1 ]]; then
	info "Rebuilding initramfs"
	update-initramfs -u -k all
fi

state_set DEVICES "${FUNCS[*]}"

# ---------------------------------------------------------------- done
echo
ok "PCIe passthrough setup done"
if [[ $REBOOT -eq 1 ]]; then
	echo
	echo "  Reboot the host, then check with:"
	echo "    bash install.sh check"
	echo "    lspci -nnk -s ${FUNCS[0]#0000:}    (Kernel driver in use: vfio-pci)"
fi
echo
echo "  Then add the card to a VM in the GUI: VM > Hardware > Add > PCI Device"
echo "    - Raw Device ${FUNCS[0]#0000:}, tick All Functions, q35 machine + PCI-Express"
[[ $GPU -eq 1 ]] && echo "    - GPU: OVMF (UEFI). AMD cards that do not reset between VM starts need vendor-reset"
exit 0
