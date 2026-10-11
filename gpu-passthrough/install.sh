#!/usr/bin/env bash
# GPU / iGPU passthrough setup for Proxmox VE
#
#   setup     : prepare the host: kernel options, VFIO modules, driver blacklist,
#               optional vfio-pci binding. Adding the GPU to a VM is done in the GUI. Two types:
#                 full : pass a whole GPU (discrete or iGPU) to one VM
#                 gvt  : Intel GVT-g, split the iGPU into virtual GPUs for several VMs
#   check     : read-only report of IOMMU, VFIO, GVT-g and GPU state (run after the reboot)
#   uninstall : undo the host changes made by setup
#
# Based on:
#   https://3os.org/infrastructure/proxmox/gpu-passthrough/gpu-passthrough-to-vm/
#   https://3os.org/infrastructure/proxmox/gpu-passthrough/igpu-passthrough-to-vm/
#   https://3os.org/infrastructure/proxmox/gpu-passthrough/igpu-split-passthrough/
#
# Usage:
#   bash install.sh                      (interactive wizard)
#   bash install.sh setup [options]
#   bash install.sh check
#   bash install.sh uninstall
#
# Via curl:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/gpu-passthrough/install.sh)"
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/gpu-passthrough/install.sh)" install.sh check
set -euo pipefail

# ---------------------------------------------------------------- defaults
MODE=""
TYPE=""              # full | gvt
GPU_ARG=""           # comma separated PCI addresses, e.g. 01:00.0,00:02.0
BIND=0               # 1 = write vfio-pci ids + softdep so the host never loads the GPU driver
BLACKLIST=""         # 1 = write $BLACKLIST_FILE (always on for gvt)
ASSUME_YES=0
IGPU=0000:00:02.0
GRUB_FILE=/etc/default/grub
SDBOOT_FILE=/etc/kernel/cmdline
MODULES_FILE=/etc/modules
MODPROBE_FILE=/etc/modprobe.d/gpu-passthrough.conf
BLACKLIST_FILE=/etc/modprobe.d/blacklist.conf
BLACKLIST_DRIVERS=(radeon nouveau nvidia nvidiafb nvidia-gpu)
STATE_DIR=/var/lib/gpu-passthrough
STATE_FILE=$STATE_DIR/state
MARK_BEGIN="# >>> gpu-passthrough"
MARK_END="# <<< gpu-passthrough"
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
  --type full|gvt    full = whole GPU to one VM (default)
                     gvt  = Intel GVT-g, split the iGPU between VMs (Intel gen 5-10)
  --gpu ADDR[,ADDR]  PCI address of the GPU(s), e.g. 01:00.0 or 00:02.0 (iGPU).
                     All functions of the same slot (HDMI audio, USB-C...) are included.
                     Not needed for gvt (always $IGPU).
  --blacklist        Blacklist ${BLACKLIST_DRIVERS[*]} on the host
                     ($BLACKLIST_FILE). Always on for gvt.
  --bind             full: bind the GPU to vfio-pci at boot (only needed if Proxmox
                     cannot take the GPU from the host driver by itself)
  -y, --yes          Non-interactive, never prompt

Examples:
  $0
  $0 check
  $0 setup -y
  $0 setup -y --gpu 01:00.0 --blacklist
  $0 setup -y --gpu 00:02.0 --bind
  $0 setup -y --type gvt
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
	local __ans
	ask __ans "$1 (Y/n)" "Y"
	[[ $__ans =~ ^[Yy] ]]
}

confirm_no() {
	local __ans
	ask __ans "$1 (y/N)" "N"
	[[ $__ans =~ ^[Yy] ]]
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
pci_bootvga() { [[ -f $PCI/$1/boot_vga ]] && cat "$PCI/$1/boot_vga" || echo 0; }
# all functions in the same slot: 0000:01:00.0 -> 0000:01:00.0 0000:01:00.1 ...
slot_funcs() {
	local f
	for f in "$PCI/${1%.*}".*; do [[ -e $f ]] && basename "$f"; done
}

list_gpus() {
	local d
	for d in "$PCI"/*; do
		[[ $(cat "$d/class") == 0x03* ]] && basename "$d"
	done
}

# GVT-g types the iGPU offers (only after a reboot with i915.enable_gvt=1 + kvmgt)
mdev_types() {
	local t
	for t in "$PCI/$IGPU"/mdev_supported_types/*; do [[ -d $t ]] && basename "$t"; done
}

iommu_active() { [[ -n $(ls -A /sys/kernel/iommu_groups 2>/dev/null) ]]; }

cpu_vendor() {
	if grep -q GenuineIntel /proc/cpuinfo; then echo intel
	elif grep -q AuthenticAMD /proc/cpuinfo; then echo amd
	else echo other; fi
}

# ---------------------------------------------------------------- kernel cmdline helpers
# GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub is always updated.
# On systemd-boot (ZFS on UEFI) the cmdline lives in /etc/kernel/cmdline, so it is updated too.
uses_systemd_boot() {
	[[ -f $SDBOOT_FILE ]] && command -v proxmox-boot-tool >/dev/null \
		&& proxmox-boot-tool status 2>/dev/null | grep -q 'uefi'
}

boot_type() { if uses_systemd_boot; then echo systemd-boot; else echo grub; fi; }

re_esc() { printf '%s' "${1//./[.]}"; }   # i915.enable_gvt=1 -> i915[.]enable_gvt=1 (literal dot in ERE)
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
		--type)      TYPE=$2; shift 2 ;;
		--gpu)       GPU_ARG=$2; shift 2 ;;
		--blacklist) BLACKLIST=1; shift ;;
		--bind)      BIND=1; shift ;;
		-y|--yes)    ASSUME_YES=1; shift ;;
		-h|--help)   usage 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done
[[ -z $TYPE || $TYPE == full || $TYPE == gvt ]] || die "--type must be full or gvt"

[[ $EUID -eq 0 ]] || die "Run as root"
command -v pveversion >/dev/null || die "Only Proxmox VE is supported"
command -v lspci >/dev/null || die "lspci not found. Install it with: apt install pciutils"
[[ $ASSUME_YES -eq 1 ]] && INTERACTIVE=0
if [[ -z $MODE ]]; then
	[[ $INTERACTIVE -eq 1 ]] || usage 1
	echo
	echo "  GPU passthrough setup for Proxmox VE"
	echo
	choose MODE "What do you want to do?" setup \
		"setup|Set up passthrough" \
		"check|Check the current state (read-only)" \
		"uninstall|Undo the host changes made by this script"
fi

# ---------------------------------------------------------------- check
if [[ $MODE == check ]]; then
	info "Host"
	echo "    Proxmox    : $(pveversion)"
	echo "    Kernel     : $(uname -r)"
	echo "    CPU        : $(cpu_vendor)"
	echo "    Bootloader : $(boot_type)"
	echo "    Cmdline    : $(cat /proc/cmdline)"
	echo
	if iommu_active; then
		ok "IOMMU is active ($(ls /sys/kernel/iommu_groups | wc -l) groups)"
	else
		warn "IOMMU is not active. Enable Intel VT-d / AMD-Vi (IOMMU) in the BIOS/UEFI"
	fi
	dmesg 2>/dev/null | grep -e DMAR -e IOMMU -e AMD-Vi | grep -iE 'enabled|remapping' | head -5 | sed 's/^/    /' || true
	echo
	for m in vfio vfio_iommu_type1 vfio_pci; do
		if [[ -d /sys/module/$m ]]; then ok "module $m loaded"; else warn "module $m not loaded"; fi
	done
	for m in "${BLACKLIST_DRIVERS[@]}"; do
		[[ -d /sys/module/${m//-/_} ]] && warn "module $m is loaded on the host"
	done
	if [[ -f $BLACKLIST_FILE ]] && grep -qF "$MARK_BEGIN" "$BLACKLIST_FILE"; then
		ok "Driver blacklist in $BLACKLIST_FILE"
	fi
	echo
	if [[ -d /sys/module/kvmgt || -d $PCI/$IGPU/mdev_supported_types ]]; then
		info "Intel GVT-g"
		if [[ -d $PCI/$IGPU/mdev_supported_types ]]; then
			for t in $(mdev_types); do
				d=$PCI/$IGPU/mdev_supported_types/$t
				echo "    $t  available=$(cat "$d/available_instances")  $(tr '\n' ' ' <"$d/description" 2>/dev/null)"
			done
		else
			warn "kvmgt is loaded but $IGPU has no GVT-g types. Is i915.enable_gvt=1 on the cmdline? (Intel gen 5-10 only)"
		fi
		echo
	fi
	info "GPUs"
	for a in $(list_gpus); do
		echo "    $a  $(pci_desc "$a")"
		for f in $(slot_funcs "$a"); do
			echo "        $f  [$(pci_id "$f")]  driver=$(pci_driver "$f")  group=$(pci_group "$f")"
		done
		[[ $(pci_bootvga "$a") == 1 ]] && echo "        (boot VGA: the host console is on this GPU)"
	done
	echo
	echo "  Full passthrough: driver 'vfio-pci' or '-' means the GPU is free for a VM."
	echo "  GVT-g: the iGPU keeps driver 'i915'."
	echo "  Full IOMMU groups: pvesh get /nodes/$(hostname)/hardware/pci --pci-class-blacklist \"\""
	exit 0
fi

# ---------------------------------------------------------------- uninstall
if [[ $MODE == uninstall ]]; then
	if [[ $INTERACTIVE -eq 1 ]]; then
		confirm "Remove kernel options, modules, blacklist and vfio-pci binding added by this script?" || die "Cancelled"
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
	if [[ -f $MODPROBE_FILE ]]; then
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

# ---------------------------------------------------------------- setup: type
VENDOR=$(cpu_vendor)
PREV_TYPE=$(state_get TYPE)
if [[ -z $TYPE ]]; then
	if [[ $INTERACTIVE -eq 1 ]]; then
		echo
		choose TYPE "Passthrough type" "${PREV_TYPE:-full}" \
			"full|Full - pass a whole GPU (discrete or iGPU) to one VM" \
			"gvt|GVT-g - split the Intel iGPU into virtual GPUs for several VMs (Intel gen 5-10)"
	else
		TYPE=full
	fi
fi

if [[ $TYPE == gvt ]]; then
	[[ $VENDOR == intel ]] || die "GVT-g needs an Intel CPU with an iGPU"
	[[ -e $PCI/$IGPU && $(pci_vendor "$IGPU") == 8086 ]] || die "No Intel iGPU at ${IGPU#0000:}. Is it enabled in the BIOS?"
	[[ $BIND -eq 0 ]] || die "--bind cannot be used with GVT-g (the host i915 driver must keep the iGPU)"
	BLACKLIST=1
fi

if ! iommu_active; then
	warn "IOMMU is not active yet. Enable Intel VT-d / AMD-Vi (IOMMU) in the BIOS/UEFI"
	[[ $VENDOR == intel ]] && warn "intel_iommu=on is added below, it takes effect after the reboot"
fi

# ---------------------------------------------------------------- setup: GPU selection (full)
GPUS=()
if [[ $TYPE == gvt ]]; then
	GPUS=("$IGPU")
else
	mapfile -t ALL_GPUS < <(list_gpus)
	[[ ${#ALL_GPUS[@]} -gt 0 ]] || die "No GPU found (no PCI device with class 03xx)"

	if [[ $INTERACTIVE -eq 1 && -z $GPU_ARG ]]; then
		echo
		info "GPUs on this host"
		i=1; def=""
		for a in "${ALL_GPUS[@]}"; do
			bv=""; [[ $(pci_bootvga "$a") == 1 ]] && bv="  (host console)"
			echo "    $i) ${a#0000:}  $(pci_desc "$a")  driver=$(pci_driver "$a")$bv"
			[[ -z $def && $(pci_bootvga "$a") != 1 ]] && def=$i
			i=$((i + 1))
		done
		echo "    0) none - only prepare the host (kernel options, VFIO modules)"
		ask_valid picks "GPU(s) to pass through, e.g. 1 or 1,2" "${def:-1}" '^[0-9]+(,[0-9]+)*$' "Enter numbers separated by commas"
		if [[ $picks != 0 ]]; then
			for n in ${picks//,/ }; do
				((n >= 1 && n <= ${#ALL_GPUS[@]})) || die "No GPU number $n"
				GPUS+=("${ALL_GPUS[n - 1]}")
			done
		fi
	elif [[ -n $GPU_ARG ]]; then
		for g in ${GPU_ARG//,/ }; do
			a=$(norm_addr "$g")
			[[ -e $PCI/$a ]] || die "PCI device $g not found. List GPUs with: lspci -nnk | grep -A3 -E \"VGA|3D|Display\""
			GPUS+=("$a")
		done
	fi
fi

# Every function of each selected slot (GPU + HDMI audio + ...) and their vendor:device IDs
FUNCS=(); IDS=(); DISCRETE=0
for a in "${GPUS[@]}"; do
	[[ $(pci_vendor "$a") == 10de || $(pci_vendor "$a") == 1002 ]] && DISCRETE=1
	for f in $(slot_funcs "$a"); do
		FUNCS+=("$f")
		id=$(pci_id "$f")
		[[ " ${IDS[*]} " == *" $id "* ]] || IDS+=("$id")
	done
done

# ---------------------------------------------------------------- setup: options
if [[ $INTERACTIVE -eq 1 ]]; then
	echo
	if [[ $TYPE == full ]]; then
		[[ -n $BLACKLIST ]] || BLACKLIST=$DISCRETE
		echo "  Blacklisting ${BLACKLIST_DRIVERS[*]} stops the host from"
		echo "  loading them. Say no if the host itself needs an NVIDIA/AMD driver."
		ask_yn BLACKLIST "Blacklist these drivers on the host?" "$BLACKLIST"

		if [[ ${#GPUS[@]} -gt 0 ]]; then
			echo
			echo "  Proxmox normally takes the GPU from the host driver when the VM starts."
			echo "  Binding to vfio-pci at boot is only needed if that fails (e.g. the VM won't"
			echo "  start, or the host driver grabs the card back)."
			ask_yn BIND "Bind to vfio-pci at boot?" "$BIND"
		fi
	fi
fi
[[ -n $BLACKLIST ]] || BLACKLIST=0
[[ ${#GPUS[@]} -gt 0 || $BIND -eq 0 ]] || die "--bind needs --gpu"

# Kernel options: intel_iommu=on on every Intel host, plus what GVT-g needs
CMDLINE=()
[[ $VENDOR == intel ]] && CMDLINE+=(intel_iommu=on)
[[ $TYPE == gvt ]] && CMDLINE+=(i915.enable_gvt=1 iommu=pt)

MODULES=(vfio vfio_iommu_type1 vfio_pci)
[[ $TYPE == gvt ]] && MODULES+=(kvmgt)

# ---------------------------------------------------------------- setup: sanity checks
if [[ $TYPE == full ]]; then
	for a in "${GPUS[@]}"; do
		if [[ $(pci_bootvga "$a") == 1 ]]; then
			warn "${a#0000:} is the host's boot display. After passthrough the host console goes blank,"
			warn "make sure SSH or the web UI works before rebooting"
		fi
		g=$(pci_group "$a")
		if [[ $g != - ]]; then
			for d in /sys/kernel/iommu_groups/"$g"/devices/*; do
				d=$(basename "$d")
				[[ ${d%.*} == "${a%.*}" ]] && continue
				[[ $(pci_class "$d") == 0x0604* ]] && continue   # PCI bridges are fine
				warn "${a#0000:} shares IOMMU group $g with $d ($(pci_desc "$d")). Both go to the VM together"
			done
		fi
	done
	if [[ $BIND -eq 1 ]]; then
		for id in "${IDS[@]}"; do
			for d in "$PCI"/*; do
				d=$(basename "$d")
				[[ $(pci_id "$d") == "$id" ]] || continue
				[[ " ${FUNCS[*]} " == *" $d "* ]] && continue
				warn "$d has the same ID $id and will also be bound to vfio-pci"
			done
		done
	fi
fi
if [[ $BLACKLIST -eq 1 ]]; then
	for m in "${BLACKLIST_DRIVERS[@]}"; do
		for d in "$PCI"/*; do
			d=$(basename "$d")
			[[ $(pci_driver "$d") == "${m//-/_}" || $(pci_driver "$d") == "$m" ]] || continue
			[[ " ${FUNCS[*]} " == *" $d "* ]] && continue
			warn "$d ($(pci_desc "$d")) uses $m on the host and will lose its driver"
		done
	done
fi

# ---------------------------------------------------------------- setup: summary
echo
info "Summary"
echo "    Type         : $([[ $TYPE == gvt ]] && echo 'Intel GVT-g (split iGPU)' || echo 'full passthrough')"
echo "    Kernel / CPU : $(uname -r) / $VENDOR, $(boot_type)"
if [[ ${#CMDLINE[@]} -gt 0 ]]; then
	echo "    Kernel opts  : ${CMDLINE[*]} -> GRUB_CMDLINE_LINUX_DEFAULT$(uses_systemd_boot && echo " + $SDBOOT_FILE")"
fi
echo "    Modules      : ${MODULES[*]} -> $MODULES_FILE"
if [[ $BLACKLIST -eq 1 ]]; then
	echo "    Blacklist    : ${BLACKLIST_DRIVERS[*]} -> $BLACKLIST_FILE"
fi
for f in "${FUNCS[@]}"; do
	echo "    Device       : ${f#0000:} [$(pci_id "$f")] $(pci_desc "$f")"
done
if [[ $TYPE == full && ${#GPUS[@]} -gt 0 ]]; then
	if [[ $BIND -eq 1 ]]; then
		echo "    vfio-pci     : bind ${IDS[*]} at boot -> $MODPROBE_FILE"
	else
		echo "    vfio-pci     : automatic (no forced binding)"
	fi
fi
echo
if [[ $INTERACTIVE -eq 1 ]]; then
	confirm "Proceed?" || die "Cancelled"
fi

# ---------------------------------------------------------------- setup: kernel cmdline
REBOOT=0
if [[ ${#CMDLINE[@]} -gt 0 ]]; then
	mapfile -t new < <(cmdline_add "${CMDLINE[@]}")
	if [[ ${#new[@]} -gt 0 ]]; then
		prev=$(state_get CMDLINE_ADDED)
		state_set CMDLINE_ADDED "$(printf '%s\n' $prev "${new[@]}" | sort -u | tr '\n' ' ' | sed 's/ $//')"
		info "Refreshing bootloader"
		refresh_boot
		REBOOT=1
		ok "Added kernel options: ${new[*]}"
	else
		ok "Kernel options already set: ${CMDLINE[*]}"
	fi
fi

# ---------------------------------------------------------------- setup: modules
block_remove "$MODULES_FILE"
missing=()
for m in "${MODULES[@]}"; do
	grep -Eq "^[[:space:]]*$m([[:space:]]|\$)" "$MODULES_FILE" 2>/dev/null || missing+=("$m")
done
prev_mods=$(state_get MODULES_ADDED)
if [[ ${#missing[@]} -gt 0 ]]; then
	block_write "$MODULES_FILE" "${missing[@]}"
	[[ "${missing[*]}" == "$prev_mods" ]] || REBOOT=1
	state_set MODULES_ADDED "${missing[*]}"
	ok "Modules in $MODULES_FILE: ${missing[*]}"
else
	ok "Modules already in $MODULES_FILE"
fi

# ---------------------------------------------------------------- setup: driver blacklist
if [[ $BLACKLIST -eq 1 ]]; then
	if ! grep -qF "$MARK_BEGIN" "$BLACKLIST_FILE" 2>/dev/null; then
		REBOOT=1
	fi
	lines=()
	for m in "${BLACKLIST_DRIVERS[@]}"; do lines+=("blacklist $m"); done
	block_write "$BLACKLIST_FILE" "${lines[@]}"
	ok "Blacklisted ${BLACKLIST_DRIVERS[*]} in $BLACKLIST_FILE"
fi

# ---------------------------------------------------------------- setup: vfio-pci binding (full)
if [[ $TYPE == full && $BIND -eq 1 ]]; then
	# Load vfio-pci before the GPU driver (softdep), so it claims the card first
	drivers=()
	for f in "${FUNCS[@]}"; do
		d=$(pci_driver "$f")
		[[ $d == - || $d == vfio-pci ]] || drivers+=("$d")
		case "$(pci_vendor "$f")" in
			10de) drivers+=(nouveau nvidia nvidiafb) ;;
			1002) drivers+=(amdgpu radeon) ;;
			8086) drivers+=(i915 xe) ;;
		esac
		[[ $(pci_class "$f") == 0x0403* ]] && drivers+=(snd_hda_intel)
	done
	mapfile -t drivers < <(printf '%s\n' "${drivers[@]}" | sort -u)
	ids_csv=$(IFS=,; echo "${IDS[*]}")
	{
		echo "# Managed by gpu-passthrough/install.sh"
		echo "options vfio-pci ids=$ids_csv"
		for d in "${drivers[@]}"; do
			modinfo -n "$d" >/dev/null 2>&1 && echo "softdep $d pre: vfio-pci"
		done
	} >"$MODPROBE_FILE.new"
	cmp -s "$MODPROBE_FILE.new" "$MODPROBE_FILE" || REBOOT=1
	mv "$MODPROBE_FILE.new" "$MODPROBE_FILE"
	ok "vfio-pci will claim $ids_csv at boot ($MODPROBE_FILE)"
elif [[ -f $MODPROBE_FILE && ( $TYPE == gvt || ${#GPUS[@]} -gt 0 ) ]]; then
	rm -f "$MODPROBE_FILE"
	REBOOT=1
	ok "Removed old $MODPROBE_FILE (no forced binding)"
fi

if [[ $REBOOT -eq 1 ]]; then
	info "Rebuilding initramfs"
	update-initramfs -u -k all
fi

# Remember the type so the next run defaults to it
state_set TYPE "$TYPE"

# ---------------------------------------------------------------- done
echo
ok "GPU passthrough setup done"
if [[ $REBOOT -eq 1 ]]; then
	echo
	echo "  Reboot the host, then check with:"
	echo "    bash install.sh check"
	echo "    dmesg | grep -e DMAR -e IOMMU -e AMD-Vi"
	[[ $TYPE == full && ${#GPUS[@]} -gt 0 ]] && echo "    lspci -nnk -s ${GPUS[0]#0000:}"
fi
echo
echo "  Then add the GPU to a VM in the GUI: VM > Hardware > Add > PCI Device"
if [[ $TYPE == gvt ]]; then
	echo "    - select ${IGPU} and an MDev Type ('check' lists them after the reboot)"
	echo "    - Windows: q35 + PCI-Express, Linux: i440fx works too"
else
	echo "    - select the GPU, tick All Functions, use q35 + PCI-Express"
	echo "    - OVMF (UEFI) only if the GPU ROM supports it, otherwise SeaBIOS"
	echo "    - Primary GPU only if the guest should use it as its main display"
fi
echo
echo "  The passed-through GPU's output does not show in noVNC/SPICE. Connect a monitor"
echo "  or set up remote desktop in the guest before relying on it."
