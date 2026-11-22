#!/usr/bin/env bash
# Intel media driver + NVIDIA driver for Debian 12 / 13, Proxmox VE 8 / 9 and OpenMediaVault
#
#   install   : Intel iGPU / Arc: VA-API drivers (iHD + i965), QSV runtime (oneVPL / Media SDK),
#               OpenCL where Debian has it, vainfo, intel_gpu_top, GPU firmware, and HuC
#               firmware loading (i915 enable_guc=2) on iGPUs that do not load it by default
#               NVIDIA: driver from NVIDIA's CUDA apt repo (newest branches, kept on one branch)
#               or from Debian non-free, built with DKMS for the running kernel (Proxmox
#               kernels too), NVENC / NVDEC libraries, optional container toolkit for Docker
#               and /dev/nvidia* device nodes at boot for LXC containers
#   check     : read-only report: GPUs, drivers, vainfo, HuC, nvidia-smi, DKMS, Secure Boot
#   uninstall : remove what install added
#
# Usage:
#   bash install.sh                        (interactive wizard)
#   bash install.sh install [options]
#   bash install.sh check
#   bash install.sh uninstall [--intel | --nvidia]
#
# Via curl:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/gpu-drivers/install.sh)"
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/gpu-drivers/install.sh)" install.sh check
set -euo pipefail

# ---------------------------------------------------------------- defaults
MODE=""
DO_INTEL=""          # 1 / 0, empty = ask (default: yes when an Intel GPU is present)
DO_NVIDIA=""         # 1 / 0, empty = ask (default: yes when an NVIDIA GPU is present)
NV_SOURCE=""         # nvidia = NVIDIA's CUDA apt repo, debian = Debian non-free
NV_BRANCH=""         # NVIDIA repo driver branch, e.g. 580 or 620; latest = newest
NV_FLAVOR=""         # open | proprietary kernel modules
NV_PROFILE=""        # compute = headless (CUDA, NVENC / NVDEC, nvidia-smi), desktop = + X / Wayland driver
CTK=""               # 1 = nvidia-container-toolkit, Docker runtime configured if Docker is installed
LXC_NODES=""         # 1 = create /dev/nvidia* (incl. nvidia-uvm) at boot, for LXC containers
GUC=""               # auto | 2 | 3 | off   (i915 enable_guc)
ASSUME_YES=0

STATE_DIR=/var/lib/gpu-drivers
STATE_FILE=$STATE_DIR/state
BACKUP_DIR=$STATE_DIR/backup
GUC_FILE=/etc/modprobe.d/gpu-drivers-i915.conf
NV_MODPROBE_FILE=/etc/modprobe.d/gpu-drivers-nvidia.conf
NOUVEAU_FILE=/etc/modprobe.d/gpu-drivers-nouveau.conf
NODES_SERVICE=gpu-drivers-nvidia-nodes.service
NODES_FILE=/etc/systemd/system/$NODES_SERVICE
DKMS_MOK=/var/lib/dkms/mok.pub
DOCKER_JSON=/etc/docker/daemon.json
NV_REPO_BASE=https://developer.download.nvidia.com/compute/cuda/repos
NV_LEGACY_BRANCH=580   # last NVIDIA branch for Maxwell / Pascal / Volta
PCI=/sys/bus/pci/devices

# ---------------------------------------------------------------- helpers
c_info=$'\e[1;34m'; c_ok=$'\e[1;32m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_off=$'\e[0m'
info() { echo "${c_info}==>${c_off} $*"; }
ok()   { echo "${c_ok}[OK]${c_off} $*"; }
warn() { echo "${c_warn}[WARN]${c_off} $*" >&2; }
die()  { echo "${c_err}[ERROR]${c_off} $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $0 [install|check|uninstall] [options]

Run without arguments for an interactive wizard. Options given on the
command line become the defaults in the wizard (or are used as-is with -y).
Without --intel / --nvidia the GPUs found on the machine decide.

Install options:
  --intel, --no-intel     Install (or skip) the Intel media driver
  --nvidia, --no-nvidia   Install (or skip) the NVIDIA driver
  --nvidia-source SRC     nvidia = NVIDIA's CUDA apt repo, newest branches (default)
                          debian = Debian non-free (535 on Debian 12, 550 on Debian 13)
  --branch N|latest       NVIDIA repo branch to stay on, e.g. 580 or 620 (default: latest,
                          $NV_LEGACY_BRANCH for Maxwell / Pascal / Volta)
  --flavor open|proprietary
                          Kernel modules. open needs Turing (GTX 16 / RTX 20) or newer
                          (default: open on Turing+ from NVIDIA's repo, proprietary otherwise)
  --profile compute|desktop
                          compute = headless: CUDA, NVENC / NVDEC, nvidia-smi (default
                          unless the machine boots to a desktop); desktop = + X / Wayland driver
  --container-toolkit     Also install nvidia-container-toolkit and set up the Docker runtime
                          (NVIDIA repo only)
  --lxc-nodes, --no-lxc-nodes
                          Create /dev/nvidia* and /dev/nvidia-uvm at boot so LXC containers
                          can use the GPU (default on Proxmox VE)
  --guc auto|2|3|off      i915 enable_guc: auto = 2 (load HuC) only on iGPUs that need it
  -y, --yes               Non-interactive, never prompt

Uninstall options:
  --intel / --nvidia      Remove only that part (default: both)

Examples:
  $0
  $0 check
  $0 install -y
  $0 install -y --no-nvidia
  $0 install -y --nvidia --branch 580
  $0 install -y --nvidia --container-toolkit
  $0 uninstall --nvidia
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

needs_value() { [[ $1 -ge 2 ]] || die "$2 needs a value (see --help)"; }

state_get() { [[ -f $STATE_FILE ]] && sed -n "s/^$1=//p" "$STATE_FILE" || true; }
state_set() {
	mkdir -p "$STATE_DIR"
	touch "$STATE_FILE"
	sed -i "/^$1=/d" "$STATE_FILE"
	echo "$1=$2" >>"$STATE_FILE"
}
state_del() { [[ -f $STATE_FILE ]] && sed -i "/^$1=/d" "$STATE_FILE"; return 0; }
# state_add KEY WORD...: adds words to a space separated list
state_add() {
	local key=$1 cur
	shift
	cur=$(state_get "$key")
	# shellcheck disable=SC2086
	state_set "$key" "$(printf '%s\n' $cur "$@" | sort -u | tr '\n' ' ' | sed 's/ $//')"
}

# ---------------------------------------------------------------- apt helpers
# No "cmd | grep -q" with pipefail: grep exiting early can make the pipeline fail with SIGPIPE
pkg_candidate() { apt-cache policy "$1" 2>/dev/null | awk '/^ *Candidate:/ && !f { print $2; f = 1 }'; }
pkg_available() { local c; c=$(pkg_candidate "$1"); [[ -n $c && $c != "(none)" ]]; }
pkg_installed() { local s; s=$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null) || return 1; [[ $s == ii* ]]; }
pkg_version()   { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true; }

# pkg_origin PKG -> nvidia | debian | local: the repo the installed version comes from
pkg_origin() {
	apt-cache policy "$1" 2>/dev/null | awk '
		/^ +\*\*\* / { inst = 1; next }
		inst {
			if ($2 !~ /\//) { inst = 0; next }
			if ($2 ~ /developer\.download\.nvidia\.com/) n = 1
			else if ($2 !~ /dpkg\/status/) d = 1
		}
		END { print (n ? "nvidia" : d ? "debian" : "local") }'
}

apt_update() {
	info "apt-get update"
	apt-get update -qq || warn "apt-get update reported errors, continuing"
}

apt_install() {   # apt_install [apt-get options] PKG...
	DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
		-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# only_available PKG...: prints the packages apt can install, in order
only_available() {
	local p
	for p in "$@"; do pkg_available "$p" && echo "$p"; done
	return 0
}

# purge_related REGEX PKG...: purges PKG..., then the packages they pulled in that are
# no longer needed and whose name matches REGEX (not a blanket autoremove)
purge_related() {
	local re=$1 p pkgs=() extra
	shift
	for p in "$@"; do pkg_installed "$p" && pkgs+=("$p"); done
	if [[ ${#pkgs[@]} -gt 0 ]]; then
		info "Purging ${pkgs[*]}"
		DEBIAN_FRONTEND=noninteractive apt-get purge -y -q "${pkgs[@]}"
	fi
	mapfile -t extra < <(apt-get -s autoremove 2>/dev/null | awk '/^Remv /{ print $2 }' | grep -E "$re" || true)
	if [[ ${#extra[@]} -gt 0 ]]; then
		info "Purging no longer needed: ${extra[*]}"
		DEBIAN_FRONTEND=noninteractive apt-get purge -y -q "${extra[@]}"
	fi
	return 0
}

# ---------------------------------------------------------------- apt sources: contrib / non-free
# URIs (no trailing slash) of the apt sources whose Release file says Origin: Debian
# (incl. security and backports), so Proxmox / OMV / Docker / other repos are never touched
debian_uris() {
	apt-cache policy 2>/dev/null | awk '
		$1 ~ /^[0-9]+$/ && $2 ~ /^[a-z+]+:/ { uri = $2; next }
		/^ +release / && uri != "" { if ($0 ~ /[ ,]o=Debian( Backports)?(,|$)/) print uri; uri = "" }
	' | sed 's|/*$||' | sort -u
}

# One-line format (sources.list, *.list): add the missing components to "deb URI SUITE main ..."
edit_oneline() {   # edit_oneline "URIS" "COMPS" < in > out
	awk -v uris="$1" -v want="$2" '
		function norm(u) { sub(/\/+$/, "", u); return u }
		BEGIN { n = split(uris, a, "\n"); for (i = 1; i <= n; i++) U[a[i]] = 1; nw = split(want, W, " ") }
		/^[[:space:]]*deb(-src)?[[:space:]]/ && $0 !~ /#/ {
			j = 2
			if ($j ~ /^\[/) { while (j <= NF && $j !~ /\]$/) j++; j++ }
			split("", C); has_main = 0
			for (k = j + 2; k <= NF; k++) { C[$k] = 1; if ($k == "main") has_main = 1 }
			if ((norm($j) in U) && has_main) {
				add = ""
				for (w = 1; w <= nw; w++) if (!(W[w] in C)) add = add " " W[w]
				line = $0; sub(/[[:space:]]+$/, "", line)
				print line add
				next
			}
		}
		{ print }'
}

# deb822 format (*.sources): add the missing components to the stanzas with a Debian URI
edit_deb822() {   # edit_deb822 "URIS" "COMPS" < in > out
	awk -v uris="$1" -v want="$2" '
		function norm(u) { sub(/\/+$/, "", u); return u }
		function flush(   i, k, n, t, hit, ci, add) {
			hit = 0; ci = 0
			for (i = 1; i <= ns; i++) {
				if (tolower(S[i]) ~ /^uris:/) {
					n = split(substr(S[i], 6), t, /[[:space:]]+/)
					for (k = 1; k <= n; k++) if (t[k] != "" && (norm(t[k]) in U)) hit = 1
				}
				if (tolower(S[i]) ~ /^components:/) ci = i
			}
			if (hit && ci) {
				n = split(substr(S[ci], 12), t, /[[:space:]]+/); split("", C)
				for (k = 1; k <= n; k++) if (t[k] != "") C[t[k]] = 1
				if ("main" in C) {
					add = ""
					for (k = 1; k <= nw; k++) if (!(W[k] in C)) add = add " " W[k]
					sub(/[[:space:]]+$/, "", S[ci]); S[ci] = S[ci] add
				}
			}
			for (i = 1; i <= ns; i++) print S[i]
			ns = 0
		}
		BEGIN { n = split(uris, a, "\n"); for (i = 1; i <= n; i++) U[a[i]] = 1; nw = split(want, W, " "); ns = 0 }
		/^[[:space:]]*$/ { flush(); print; next }
		{ S[++ns] = $0 }
		END { flush() }'
}

# ensure_components "PROBE_PKG..." COMP...: adds COMPs to the Debian sources unless every
# probe package is already installable. Empty probe list = always add the missing ones.
ensure_components() {
	local probes=$1 p missing=0 uris f tmp changed=()
	shift
	if [[ -n $probes ]]; then
		for p in $probes; do pkg_available "$p" || missing=1; done
		[[ $missing -eq 1 ]] || return 0
	fi
	uris=$(debian_uris)
	[[ -n $uris ]] || die "No Debian apt source found (apt-cache policy shows no Origin: Debian). Add $* to your Debian sources by hand"
	for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
		[[ -f $f ]] || continue
		tmp=$(mktemp)
		if [[ $f == *.sources ]]; then
			edit_deb822 "$uris" "$*" <"$f" >"$tmp"
		else
			edit_oneline "$uris" "$*" <"$f" >"$tmp"
		fi
		if cmp -s "$f" "$tmp"; then rm -f "$tmp"; continue; fi
		# backups outside sources.list.d, apt would complain about the extension
		mkdir -p "$BACKUP_DIR"
		cp -a "$f" "$BACKUP_DIR/$(basename "$f").$(date +%Y%m%d-%H%M%S)"
		cat "$tmp" >"$f"
		rm -f "$tmp"
		changed+=("$f")
	done
	if [[ ${#changed[@]} -gt 0 ]]; then
		ok "Added $* to the Debian sources in ${changed[*]} (backup in $BACKUP_DIR)"
		apt_update
	fi
	for p in $probes; do
		pkg_available "$p" || die "$p is not available even with $* enabled. Check /etc/apt/sources.list*"
	done
	return 0
}

# ---------------------------------------------------------------- GPU helpers
pci_vendor() { sed 's/^0x//' "$PCI/$1/vendor"; }
pci_dev()    { sed 's/^0x//' "$PCI/$1/device"; }
pci_desc() {
	local d=""
	command -v lspci >/dev/null && d=$(lspci -s "$1" 2>/dev/null | cut -d' ' -f2-)
	echo "${d:-[$(pci_vendor "$1"):$(pci_dev "$1")]}"
}
pci_driver() { [[ -e $PCI/$1/driver ]] && basename "$(readlink "$PCI/$1/driver")" || echo "-"; }

list_gpus() {   # list_gpus VENDOR -> PCI addresses of that vendor's display devices (class 03xx)
	local d
	for d in "$PCI"/*; do
		[[ -e $d/class ]] || continue
		[[ $(cat "$d/class") == 0x03* && $(cat "$d/vendor") == "0x$1" ]] && basename "$d"
	done
	return 0
}

render_nodes() {   # render_nodes VENDOR -> /dev/dri/renderD* of that vendor
	local n
	for n in /sys/class/drm/renderD*; do
		[[ -e $n/device/vendor && $(cat "$n/device/vendor") == "0x$1" ]] && echo "/dev/dri/${n##*/}"
	done
	return 0
}

# NVIDIA generation from the PCI device ID (approximate, good enough to pick a driver)
nv_arch() {
	local id=$((16#$(pci_dev "$1")))
	if ((id >= 0x2b00)); then echo blackwell
	elif ((id >= 0x1e00)); then echo turing
	elif ((id >= 0x1340)); then echo maxwell
	else echo kepler; fi
}
nv_arch_rank() { case $1 in kepler) echo 0 ;; maxwell) echo 1 ;; turing) echo 2 ;; *) echo 3 ;; esac; }
nv_arch_label() {
	case $1 in
		blackwell) echo "Blackwell or newer (RTX 50, B-series)" ;;
		turing)    echo "Turing to Ada / Hopper (GTX 16, RTX 20-40)" ;;
		maxwell)   echo "Maxwell / Pascal / Volta (GTX 750-10xx, Quadro P, Tesla P/V)" ;;
		kepler)    echo "Kepler or older" ;;
	esac
}

# HuC firmware state of the i915 iGPU: running | disabled | unsupported | error | unknown
huc_status() {
	local f s run=0 dis=0 uns=0 other=0 msgs
	for f in /sys/kernel/debug/dri/*/gt*/uc/huc_info; do
		[[ -r $f ]] || continue
		s=$(cat "$f" 2>/dev/null) || continue
		s=${s,,}
		case $s in
			*running*) run=1 ;;
			*"not supported"*|*"n/a"*) uns=1 ;;
			*disabled*) dis=1 ;;
			*) other=1 ;;
		esac
	done
	if ((run)); then echo running; return; fi
	if ((dis)); then echo disabled; return; fi
	if ((other)); then echo error; return; fi
	if ((uns)); then echo unsupported; return; fi
	# no debugfs: look at the boot log
	msgs=$(dmesg 2>/dev/null | grep -i 'huc' | grep -i 'authenticated' || true)
	if [[ -n $msgs && ! ${msgs,,} =~ authenticated:\ *no ]]; then echo running; return; fi
	echo unknown
}

# Files (or the kernel cmdline) that set i915 enable_guc, other than ours
guc_set_elsewhere() {
	local f
	for f in /etc/modprobe.d/*.conf; do
		[[ -f $f && $f != "$GUC_FILE" ]] || continue
		grep -qE '^[[:space:]]*options[[:space:]]+i915[[:space:]].*enable_guc=' "$f" && echo "$f"
	done
	grep -q 'i915.enable_guc=' /proc/cmdline && echo /proc/cmdline
	return 0
}

sb_enabled() {
	local f
	for f in /sys/firmware/efi/efivars/SecureBoot-*; do
		[[ -r $f ]] || continue
		[[ $(od -An -tu1 "$f" | awk '{ print $NF }') == 1 ]] && return 0
	done
	return 1
}
mok_enrolled() {
	local out
	[[ -f $DKMS_MOK ]] && command -v mokutil >/dev/null || return 1
	out=$(mokutil --test-key "$DKMS_MOK" 2>&1 || true)
	[[ $out == *"already enrolled"* ]]
}

# gpu-passthrough (this repo) or vfio-pci holding the GPUs
gpu_passthrough_blacklist() {
	local f=/etc/modprobe.d/blacklist.conf
	[[ -f $f ]] && grep -qF '# >>> gpu-passthrough' "$f" && grep -qE '^blacklist (nvidia|nouveau)' "$f"
}

# Repo the installed NVIDIA driver comes from (nvidia | debian | local), empty if none
installed_nv_source() {
	local p
	for p in nvidia-kernel-support nvidia-kernel-open-dkms nvidia-kernel-dkms nvidia-open-kernel-dkms nvidia-driver-cuda libcuda1 nvidia-driver; do
		if pkg_installed "$p"; then pkg_origin "$p"; return 0; fi
	done
	return 0
}

# Kernel headers for DKMS: the running kernel's plus the metapackage that follows kernel upgrades
kernel_headers_pkgs() {
	local kr series meta
	kr=$(uname -r)
	if [[ $kr == *-pve ]]; then
		# Proxmox kernel (Proxmox VE, or OMV with the Proxmox kernel)
		pkg_available "proxmox-headers-$kr" && echo "proxmox-headers-$kr"
		pkg_available "pve-headers-$kr" && echo "pve-headers-$kr"
		series=$(cut -d. -f1,2 <<<"${kr%%-*}")
		# opt-in kernel series (e.g. proxmox-kernel-6.17) need their own headers metapackage
		pkg_installed "proxmox-kernel-$series" && pkg_available "proxmox-headers-$series" && echo "proxmox-headers-$series"
		pkg_available proxmox-default-headers && echo proxmox-default-headers
	else
		pkg_available "linux-headers-$kr" && echo "linux-headers-$kr"
		# installed kernel metapackages, e.g. linux-image-amd64 -> linux-headers-amd64
		while read -r meta; do
			pkg_available "${meta/linux-image-/linux-headers-}" && echo "${meta/linux-image-/linux-headers-}"
		done < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-image-*' 2>/dev/null \
			| awk '$1 == "ii" && $2 !~ /[0-9]/ { print $2 }')
	fi
	return 0
}

# ---------------------------------------------------------------- args
if [[ $# -gt 0 ]]; then
	case "$1" in
		install|check|uninstall) MODE=$1; shift ;;
		-h|--help) usage 0 ;;
		-*) ;;
		*) usage 1 ;;
	esac
fi

while [[ $# -gt 0 ]]; do
	case "$1" in
		--intel)             DO_INTEL=1; shift ;;
		--no-intel)          DO_INTEL=0; shift ;;
		--nvidia)            DO_NVIDIA=1; shift ;;
		--no-nvidia)         DO_NVIDIA=0; shift ;;
		--nvidia-source)     needs_value $# "$1"; NV_SOURCE=$2; shift 2 ;;
		--branch)            needs_value $# "$1"; NV_BRANCH=$2; shift 2 ;;
		--flavor)            needs_value $# "$1"; NV_FLAVOR=$2; shift 2 ;;
		--profile)           needs_value $# "$1"; NV_PROFILE=$2; shift 2 ;;
		--container-toolkit) CTK=1; shift ;;
		--lxc-nodes)         LXC_NODES=1; shift ;;
		--no-lxc-nodes)      LXC_NODES=0; shift ;;
		--guc)               needs_value $# "$1"; GUC=$2; shift 2 ;;
		-y|--yes)            ASSUME_YES=1; shift ;;
		-h|--help)           usage 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done
[[ -z $NV_SOURCE || $NV_SOURCE == nvidia || $NV_SOURCE == debian ]] || die "--nvidia-source must be nvidia or debian"
[[ -z $NV_BRANCH || $NV_BRANCH == latest || $NV_BRANCH =~ ^[0-9]{3}$ ]] || die "--branch must be a number like 580, or latest"
[[ -z $NV_FLAVOR || $NV_FLAVOR == open || $NV_FLAVOR == proprietary ]] || die "--flavor must be open or proprietary"
[[ -z $NV_PROFILE || $NV_PROFILE == compute || $NV_PROFILE == desktop ]] || die "--profile must be compute or desktop"
[[ -z $GUC || $GUC =~ ^(auto|2|3|off)$ ]] || die "--guc must be auto, 2, 3 or off"

[[ $EUID -eq 0 ]] || die "Run as root"
[[ -r /etc/os-release ]] || die "/etc/os-release not found"
OS_ID=$(. /etc/os-release && echo "${ID:-}")
OS_VER=$(. /etc/os-release && echo "${VERSION_ID:-}")
OS_VER=${OS_VER%%.*}
OS_NAME=$(. /etc/os-release && echo "${PRETTY_NAME:-Debian}")
[[ $OS_ID == debian ]] || die "Only Debian 12 / 13 (and Proxmox VE / OpenMediaVault on it) are supported. On Ubuntu use 'ubuntu-drivers install' and intel-media-va-driver-non-free from multiverse"
[[ -z $OS_VER || $OS_VER -ge 12 ]] || die "Debian $OS_VER is too old, Debian 12 or newer is needed"
IS_PVE=0; command -v pveversion >/dev/null 2>&1 && IS_PVE=1
IS_OMV=0; command -v omv-salt >/dev/null 2>&1 && IS_OMV=1
PLATFORM_NAME=$OS_NAME
[[ $IS_PVE -eq 1 ]] && PLATFORM_NAME="Proxmox VE $(pveversion | sed -n 's|^pve-manager/\([0-9.]*\).*|\1|p') ($OS_NAME)"
[[ $IS_OMV -eq 1 ]] && PLATFORM_NAME="OpenMediaVault ($OS_NAME)"
ARCH=$(dpkg --print-architecture)
# NVIDIA's CUDA repo exists for debian12 / debian13 (amd64)
NV_DIST=""
[[ $ARCH == amd64 && ( $OS_VER == 12 || $OS_VER == 13 ) ]] && NV_DIST="debian$OS_VER"

[[ $ASSUME_YES -eq 1 ]] && INTERACTIVE=0
if [[ -z $MODE ]]; then
	[[ $INTERACTIVE -eq 1 ]] || usage 1
	echo
	echo "  Intel media driver + NVIDIA driver for $PLATFORM_NAME"
	echo
	choose MODE "What do you want to do?" install \
		"install|Install or update the drivers" \
		"check|Check the current state (read-only)" \
		"uninstall|Remove what this script installed"
fi

mapfile -t INTEL_GPUS < <(list_gpus 8086)
mapfile -t NV_GPUS < <(list_gpus 10de)

# Oldest / newest NVIDIA generation on the machine
NV_ARCH="" NV_ARCH_NEW=""
for a in "${NV_GPUS[@]}"; do
	g=$(nv_arch "$a")
	if [[ -z $NV_ARCH ]] || (($(nv_arch_rank "$g") < $(nv_arch_rank "$NV_ARCH"))); then NV_ARCH=$g; fi
	if [[ -z $NV_ARCH_NEW ]] || (($(nv_arch_rank "$g") > $(nv_arch_rank "$NV_ARCH_NEW"))); then NV_ARCH_NEW=$g; fi
done

show_gpus() {
	local a
	if [[ ${#INTEL_GPUS[@]} -eq 0 && ${#NV_GPUS[@]} -eq 0 ]]; then
		echo "    (no Intel or NVIDIA GPU found)"
		return 0
	fi
	for a in "${INTEL_GPUS[@]}"; do
		echo "    ${a#0000:}  $(pci_desc "$a")  driver=$(pci_driver "$a")"
	done
	for a in "${NV_GPUS[@]}"; do
		echo "    ${a#0000:}  $(pci_desc "$a")  driver=$(pci_driver "$a")"
		echo "                  $(nv_arch_label "$(nv_arch "$a")")"
	done
}

# ---------------------------------------------------------------- check
if [[ $MODE == check ]]; then
	info "Host"
	echo "    System      : $PLATFORM_NAME"
	echo "    Kernel      : $(uname -r)"
	echo "    Secure Boot : $(sb_enabled && echo enabled || echo disabled)"
	echo
	info "GPUs"
	show_gpus
	echo

	if [[ ${#INTEL_GPUS[@]} -gt 0 ]]; then
		info "Intel"
		for p in intel-media-va-driver-non-free intel-media-va-driver i965-va-driver-shaders i965-va-driver libvpl2 libmfx-gen1.2 libmfx1 intel-opencl-icd vainfo intel-gpu-tools; do
			pkg_installed "$p" && echo "    $p $(pkg_version "$p")"
		done
		for node in $(render_nodes 8086); do
			echo "    $node  $(stat -c '%U:%G %a' "$node")"
			if command -v vainfo >/dev/null; then
				out=$(vainfo --display drm --device "$node" 2>&1 || true)
				drv=$(sed -n 's/.*Driver version: //p' <<<"$out")
				if [[ -n $drv ]]; then
					ok "VA-API: $drv"
					echo "        decode entrypoints: $(grep -c 'VAEntrypointVLD' <<<"$out" || true), encode: $(grep -c 'VAEntrypointEnc' <<<"$out" || true)"
				else
					warn "vainfo fails on $node:"
					grep -iE 'error|fail' <<<"$out" | head -3 | sed 's/^/        /' || true
				fi
			else
				warn "vainfo not installed"
			fi
		done
		if [[ " $(for a in "${INTEL_GPUS[@]}"; do pci_driver "$a"; done | tr '\n' ' ') " == *" i915 "* ]]; then
			st=$(huc_status)
			case $st in
				running)     ok "HuC firmware running (low-power encode available)" ;;
				disabled)    warn "HuC firmware not loaded: low-power encode (VDENC) is off. Fix: bash install.sh install --guc 2" ;;
				unsupported) echo "    HuC: not supported by this iGPU" ;;
				error)       warn "HuC firmware failed to load, see: dmesg | grep -iE 'huc|guc'" ;;
				*)           echo "    HuC: state unknown (no debugfs, nothing in dmesg)" ;;
			esac
			[[ -f $GUC_FILE ]] && echo "    $GUC_FILE: $(grep -v '^#' "$GUC_FILE")"
			for f in $(guc_set_elsewhere); do echo "    enable_guc also set in $f"; done
		else
			echo "    Kernel driver xe or none: HuC / GuC are handled by the driver"
		fi
		echo "    Users need the render group for ${c_info}/dev/dri/renderD*${c_off}: usermod -aG render USER"
		echo
	fi

	if [[ ${#NV_GPUS[@]} -gt 0 ]]; then
		info "NVIDIA"
		src=$(installed_nv_source)
		if [[ -n $src ]]; then
			echo "    Packages from : $src$( [[ -n $(state_get NV_BRANCH) ]] && echo ", branch $(state_get NV_BRANCH)")"
			for p in nvidia-kernel-open-dkms nvidia-kernel-dkms nvidia-open-kernel-dkms nvidia-driver-cuda nvidia-driver nvidia-container-toolkit; do
				pkg_installed "$p" && echo "    $p $(pkg_version "$p")"
			done
			for p in $(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'nvidia-driver-pinning-*' 2>/dev/null | awk '$1 == "ii" { print $2 }'); do
				echo "    pinned with $p"
			done
		else
			warn "No NVIDIA driver package installed"
			[[ -x /usr/bin/nvidia-uninstall ]] && warn "The NVIDIA .run installer was used on this machine (/usr/bin/nvidia-uninstall)"
		fi
		[[ -d /sys/module/nouveau ]] && warn "nouveau is loaded (the NVIDIA driver cannot load until it is blacklisted + reboot)"
		if [[ -r /sys/module/nvidia/version ]]; then
			ok "Kernel module nvidia $(cat /sys/module/nvidia/version) loaded"
			mod=$(modinfo -F version nvidia 2>/dev/null || true)
			[[ -n $mod && $mod != "$(cat /sys/module/nvidia/version)" ]] && warn "Installed module is $mod: reboot to load it"
		else
			warn "Kernel module nvidia not loaded"
		fi
		if command -v dkms >/dev/null; then
			dkms status 2>/dev/null | grep -i nvidia | sed 's/^/    dkms: /' || true
		fi
		if command -v nvidia-smi >/dev/null; then
			if out=$(nvidia-smi --query-gpu=index,name,driver_version,memory.total --format=csv,noheader 2>&1); then
				sed 's/^/    nvidia-smi: /' <<<"$out"
			else
				warn "nvidia-smi: $out"
			fi
		fi
		libs=$(ldconfig -p 2>/dev/null | grep -oE 'lib(nvidia-encode|nvcuvid|cuda)\.so\.1' | sort -u | tr '\n' ' ' || true)
		echo "    NVENC / NVDEC / CUDA libraries: ${libs:-none}"
		nodes=$(ls /dev/nvidia* 2>/dev/null | tr '\n' ' ' || true)
		echo "    Device nodes: ${nodes:-none}"
		[[ -f $NODES_FILE ]] && echo "    $NODES_SERVICE: $(systemctl is-enabled "$NODES_SERVICE" 2>/dev/null || true)"
		if sb_enabled; then
			if mok_enrolled; then ok "DKMS signing key enrolled (Secure Boot)"
			else warn "Secure Boot is on and the DKMS key ($DKMS_MOK) is not enrolled: mokutil --import $DKMS_MOK, then reboot"; fi
		fi
		gpu_passthrough_blacklist && warn "gpu-passthrough blacklists nvidia / nouveau in /etc/modprobe.d/blacklist.conf"
		for a in "${NV_GPUS[@]}"; do
			[[ $(pci_driver "$a") == vfio-pci ]] && warn "${a#0000:} is bound to vfio-pci (passthrough), the host driver cannot use it"
		done
		if command -v nvidia-ctk >/dev/null && [[ -f $DOCKER_JSON ]]; then
			grep -q '"nvidia"' "$DOCKER_JSON" && ok "Docker runtime nvidia configured ($DOCKER_JSON)"
		fi
		echo
	fi
	exit 0
fi

# ---------------------------------------------------------------- uninstall
if [[ $MODE == uninstall ]]; then
	[[ -n $DO_INTEL || -n $DO_NVIDIA ]] || { DO_INTEL=1; DO_NVIDIA=1; }
	[[ -n $DO_INTEL ]] || DO_INTEL=0
	[[ -n $DO_NVIDIA ]] || DO_NVIDIA=0
	[[ -f $STATE_FILE ]] || warn "No install state in $STATE_FILE, only the files of this script are removed"
	if [[ $INTERACTIVE -eq 1 ]]; then
		echo
		[[ $DO_INTEL -eq 1 ]] && echo "  Intel : $(state_get INTEL_PKGS) ${GUC_FILE}"
		[[ $DO_NVIDIA -eq 1 ]] && echo "  NVIDIA: $(state_get NV_PKGS) $(state_get NV_PIN) $(state_get CTK_PKGS)"
		echo
		confirm "Remove these packages and the files added by this script?" || die "Cancelled"
	fi
	REBOOT=0 INITRAMFS=0
	if [[ $DO_INTEL -eq 1 ]]; then
		[[ -n $(state_get INTEL_PKGS) ]] || warn "No Intel packages recorded as installed by this script, they are left alone"
		# shellcheck disable=SC2046
		purge_related '^(intel-|i965-|libva|libvpl|libmfx|libigdgmm|libigfx|libigc|libopencl-clang|libze|ocl-icd|vainfo)' $(state_get INTEL_PKGS)
		if [[ -f $GUC_FILE ]]; then
			rm -f "$GUC_FILE"; INITRAMFS=1; REBOOT=1
			ok "Removed $GUC_FILE"
		fi
		state_del INTEL_PKGS; state_del GUC
		ok "Intel media driver removed (firmware packages are kept)"
	fi
	if [[ $DO_NVIDIA -eq 1 ]]; then
		if [[ $(state_get CTK_DOCKER) == 1 && -f $DOCKER_JSON ]] && command -v python3 >/dev/null; then
			python3 - "$DOCKER_JSON" <<'EOF' && { systemctl restart docker 2>/dev/null || true; ok "Removed the nvidia runtime from /etc/docker/daemon.json"; }
import json, sys
p = sys.argv[1]
with open(p) as f:
    d = json.load(f)
r = d.get("runtimes", {})
if "nvidia" in r:
    del r["nvidia"]
    if not r:
        d.pop("runtimes", None)
    if d.get("default-runtime") == "nvidia":
        d.pop("default-runtime")
    with open(p, "w") as f:
        json.dump(d, f, indent=4)
EOF
		fi
		if [[ -f $NODES_FILE ]]; then
			systemctl disable "$NODES_SERVICE" 2>/dev/null || true
			rm -f "$NODES_FILE"
			systemctl daemon-reload
			ok "Removed $NODES_SERVICE"
		fi
		[[ -n $(state_get NV_PKGS) ]] || warn "No NVIDIA packages recorded as installed by this script, the driver packages are left alone"
		# shellcheck disable=SC2046
		purge_related '^(nvidia|libnvidia|libcuda|libnvcuvid|libnvoptix|libcudadebugger|firmware-nvidia|libxnvctrl|glx-|libegl-nvidia|libgl1-nvidia|libgles-nvidia|libglx-nvidia|xserver-xorg-video-nvidia|update-glx|dkms$)' \
			$(state_get CTK_PKGS) $(state_get NV_PKGS) $(state_get NV_PIN)
		if [[ $(state_get NV_REPO_ADDED) == 1 ]] && pkg_installed cuda-keyring; then
			DEBIAN_FRONTEND=noninteractive apt-get purge -y -q cuda-keyring
			ok "Removed NVIDIA's CUDA apt repo (cuda-keyring)"
			apt_update
		fi
		rm -f "$NV_MODPROBE_FILE" "$NOUVEAU_FILE"
		for k in NV_PKGS NV_PIN NV_SOURCE NV_BRANCH NV_FLAVOR NV_PROFILE NV_REPO_ADDED CTK_PKGS CTK_DOCKER; do state_del "$k"; done
		REBOOT=1
		ok "NVIDIA driver removed (kernel headers, dkms and mokutil may stay if other packages use them)"
	fi
	if [[ -f $STATE_FILE ]] && ! grep -q '[^[:space:]]' "$STATE_FILE"; then rm -rf "$STATE_DIR"; fi
	if [[ $INITRAMFS -eq 1 || $DO_NVIDIA -eq 1 ]]; then
		info "Rebuilding initramfs"
		update-initramfs -u
	fi
	echo
	echo "  The contrib / non-free components added to the Debian sources are kept."
	[[ $REBOOT -eq 1 ]] && echo "  Reboot to unload the old driver."
	exit 0
fi

# ---------------------------------------------------------------- install: what to install
echo
info "GPUs on this machine ($PLATFORM_NAME)"
show_gpus
echo

if [[ $INTERACTIVE -eq 1 ]]; then
	if [[ -z $DO_INTEL ]]; then
		DO_INTEL=0
		[[ ${#INTEL_GPUS[@]} -gt 0 ]] && ask_yn DO_INTEL "Install the Intel media driver (VA-API / QSV)?" 1
	fi
	if [[ -z $DO_NVIDIA ]]; then
		DO_NVIDIA=0
		[[ ${#NV_GPUS[@]} -gt 0 ]] && ask_yn DO_NVIDIA "Install the NVIDIA driver?" 1
	fi
else
	[[ -n $DO_INTEL ]] || { [[ ${#INTEL_GPUS[@]} -gt 0 ]] && DO_INTEL=1 || DO_INTEL=0; }
	[[ -n $DO_NVIDIA ]] || { [[ ${#NV_GPUS[@]} -gt 0 ]] && DO_NVIDIA=1 || DO_NVIDIA=0; }
fi
[[ $DO_INTEL -eq 1 || $DO_NVIDIA -eq 1 ]] || die "Nothing to install (no Intel / NVIDIA GPU found; force with --intel or --nvidia)"
[[ $DO_INTEL -eq 1 && ${#INTEL_GPUS[@]} -eq 0 ]] && warn "No Intel GPU found, installing the Intel media driver anyway"
[[ $DO_NVIDIA -eq 1 && ${#NV_GPUS[@]} -eq 0 ]] && warn "No NVIDIA GPU found, installing the NVIDIA driver anyway"

# ---------------------------------------------------------------- install: NVIDIA options
if [[ $DO_NVIDIA -eq 1 ]]; then
	[[ -x /usr/bin/nvidia-uninstall ]] && die "The NVIDIA .run installer was used on this machine. Remove it first with: nvidia-uninstall"
	[[ $NV_ARCH == kepler ]] && die "Kepler and older GPUs need the 470 legacy driver, which this script does not install"
	ARCH_FOR=${NV_ARCH:-turing}   # no GPU present: assume a current card

	# Driver already installed from one source: stay on it (switching needs an uninstall first)
	PREV_SRC=$(installed_nv_source)
	[[ $PREV_SRC == local ]] && PREV_SRC=$(state_get NV_SOURCE)
	if [[ -z $NV_SOURCE ]]; then
		if [[ -n $PREV_SRC ]]; then NV_SOURCE=$PREV_SRC
		elif [[ -z $NV_DIST ]]; then NV_SOURCE=debian
		elif [[ $ARCH_FOR == maxwell && $NV_DIST == debian13 ]]; then NV_SOURCE=debian   # no $NV_LEGACY_BRANCH in NVIDIA's debian13 repo
		else NV_SOURCE=nvidia; fi
		if [[ $INTERACTIVE -eq 1 && -z $PREV_SRC && -n $NV_DIST ]]; then
			echo
			choose NV_SOURCE "Where should the NVIDIA driver come from?" "$NV_SOURCE" \
				"nvidia|NVIDIA's CUDA apt repo: newest driver branches, kept on one branch (recommended)" \
				"debian|Debian non-free: Debian's own build (535 on Debian 12, 550 on Debian 13)"
		fi
	fi
	if [[ -n $PREV_SRC && $PREV_SRC != "$NV_SOURCE" ]]; then
		die "The installed NVIDIA driver comes from the $PREV_SRC repo. Run 'bash install.sh uninstall --nvidia' first to switch to $NV_SOURCE"
	fi
	if [[ $NV_SOURCE == nvidia ]]; then
		[[ -n $NV_DIST ]] || die "NVIDIA's CUDA repo is only used for Debian 12 / 13 on amd64 here, use --nvidia-source debian"
	else
		[[ $NV_ARCH_NEW == blackwell ]] && die "Debian's driver does not support Blackwell GPUs, use --nvidia-source nvidia"
	fi

	# Branch (NVIDIA repo)
	if [[ $NV_SOURCE == nvidia ]]; then
		[[ -n $NV_BRANCH ]] || NV_BRANCH=$(state_get NV_BRANCH)
		[[ -n $NV_BRANCH ]] || { [[ $ARCH_FOR == maxwell ]] && NV_BRANCH=$NV_LEGACY_BRANCH || NV_BRANCH=latest; }
		if [[ $INTERACTIVE -eq 1 ]]; then
			echo
			[[ $ARCH_FOR == maxwell ]] && echo "  Maxwell / Pascal / Volta GPUs are supported up to branch $NV_LEGACY_BRANCH."
			opts=("latest|Newest branch (recommended for Turing and newer)")
			[[ $NV_BRANCH != latest ]] && opts=("$NV_BRANCH|Branch $NV_BRANCH" "${opts[@]}")
			[[ $NV_BRANCH != "$NV_LEGACY_BRANCH" ]] && opts+=("$NV_LEGACY_BRANCH|Branch $NV_LEGACY_BRANCH (last one for Maxwell / Pascal / Volta, Debian 12 only)")
			opts+=("other|Another branch (type its number)")
			choose NV_BRANCH "Driver branch to stay on (minor updates come through apt)" "$NV_BRANCH" "${opts[@]}"
			if [[ $NV_BRANCH == other ]]; then
				while :; do
					ask NV_BRANCH "Branch number, e.g. 595" ""
					[[ $NV_BRANCH =~ ^[0-9]{3}$ ]] && break
					warn "Enter a 3-digit branch number"
				done
			fi
		fi
		if [[ $ARCH_FOR == maxwell && ( $NV_BRANCH == latest || $NV_BRANCH -gt $NV_LEGACY_BRANCH ) ]]; then
			die "Maxwell / Pascal / Volta GPUs need branch $NV_LEGACY_BRANCH or older (--branch $NV_LEGACY_BRANCH)"
		fi
	fi

	# Kernel module flavor
	if [[ -z $NV_FLAVOR ]]; then
		NV_FLAVOR=$(state_get NV_FLAVOR)
		if [[ -z $NV_FLAVOR ]]; then
			# Debian's open modules no longer build on current trixie kernels (Debian bug 1143204)
			if [[ $ARCH_FOR == maxwell || $NV_SOURCE == debian ]]; then NV_FLAVOR=proprietary; else NV_FLAVOR=open; fi
		fi
		if [[ $INTERACTIVE -eq 1 && $ARCH_FOR != maxwell ]]; then
			echo
			if [[ $NV_SOURCE == nvidia ]]; then
				choose NV_FLAVOR "Kernel modules" "$NV_FLAVOR" \
					"open|Open kernel modules (recommended by NVIDIA for Turing and newer)" \
					"proprietary|Proprietary kernel modules (branch 595 and older only)"
			else
				choose NV_FLAVOR "Kernel modules" "$NV_FLAVOR" \
					"proprietary|Proprietary kernel modules (recommended with Debian's driver)" \
					"open|Open kernel modules (Turing and newer)"
			fi
		fi
	fi
	[[ $NV_FLAVOR == open && $ARCH_FOR == maxwell ]] && die "Open kernel modules need a Turing (GTX 16 / RTX 20) or newer GPU, use --flavor proprietary"

	# Profile
	if [[ -z $NV_PROFILE ]]; then
		NV_PROFILE=$(state_get NV_PROFILE)
		[[ -n $NV_PROFILE ]] || { [[ $(systemctl get-default 2>/dev/null) == graphical.target ]] && NV_PROFILE=desktop || NV_PROFILE=compute; }
		if [[ $INTERACTIVE -eq 1 ]]; then
			echo
			choose NV_PROFILE "What is the GPU used for?" "$NV_PROFILE" \
				"compute|Headless: transcoding (NVENC / NVDEC), CUDA, containers, nvidia-smi" \
				"desktop|Desktop too: + X / Wayland / OpenGL / Vulkan driver and nvidia-settings"
		fi
	fi

	# Container toolkit (NVIDIA repo)
	if [[ $NV_SOURCE == nvidia ]]; then
		if [[ -z $CTK ]]; then
			CTK=0
			pkg_installed nvidia-container-toolkit && CTK=1
			if [[ $INTERACTIVE -eq 1 ]]; then
				command -v docker >/dev/null && [[ $CTK -eq 0 ]] && CTK=1
				echo
				ask_yn CTK "Install nvidia-container-toolkit (GPU in Docker containers)?" "$CTK"
			fi
		fi
	else
		[[ $CTK == 1 ]] && die "--container-toolkit needs --nvidia-source nvidia"
		CTK=0
	fi

	# Device nodes at boot for LXC
	if [[ -z $LXC_NODES ]]; then
		LXC_NODES=$IS_PVE
		[[ -f $NODES_FILE ]] && LXC_NODES=1
		if [[ $INTERACTIVE -eq 1 ]]; then
			echo
			echo "  LXC containers only see /dev/nvidia* if the host created them, and /dev/nvidia-uvm"
			echo "  (needed for CUDA / NVENC) only appears once something on the host used CUDA."
			ask_yn LXC_NODES "Create the NVIDIA device nodes at every boot (for LXC containers)?" "$LXC_NODES"
		fi
	fi

	if gpu_passthrough_blacklist; then
		warn "gpu-passthrough blacklists nvidia / nouveau in /etc/modprobe.d/blacklist.conf: the driver will not load"
		warn "until that is removed (bash gpu-passthrough/install.sh uninstall, or edit the file)"
	fi
	for a in "${NV_GPUS[@]}"; do
		[[ $(pci_driver "$a") == vfio-pci ]] && warn "${a#0000:} is bound to vfio-pci (passthrough to a VM): the host driver will not get it"
	done
fi

# ---------------------------------------------------------------- install: Intel options (GuC / HuC)
GUC_ACTION=""   # "" = leave as is, 2 / 3 = write $GUC_FILE, off = remove it
GUC_NOTE=""
if [[ $DO_INTEL -eq 1 ]]; then
	i915=0
	for a in "${INTEL_GPUS[@]}"; do [[ $(pci_driver "$a") == i915 ]] && i915=1; done
	elsewhere=$(guc_set_elsewhere | tr '\n' ' ')
	case ${GUC:-auto} in
		2|3) GUC_ACTION=$GUC ;;
		off) [[ -f $GUC_FILE ]] && GUC_ACTION=off ;;
		auto)
			if [[ -f $GUC_FILE ]]; then
				GUC_NOTE="kept ($(sed -n 's/.*enable_guc=\([0-9]\).*/enable_guc=\1/p' "$GUC_FILE") in $GUC_FILE)"
			elif [[ $i915 -eq 0 ]]; then
				GUC_NOTE="not needed (no iGPU on i915; the xe driver loads HuC / GuC itself)"
			elif [[ -n $elsewhere ]]; then
				GUC_NOTE="left alone (enable_guc already set in $elsewhere)"
			elif grep -q 'i915.enable_gvt=1' /proc/cmdline; then
				GUC_NOTE="left alone (GVT-g is on, it does not work with GuC / HuC)"
			else
				case $(huc_status) in
					running)     GUC_NOTE="not needed (HuC already running)" ;;
					unsupported) GUC_NOTE="not needed (this iGPU has no HuC)" ;;
					disabled)
						GUC_ACTION=2
						if [[ $INTERACTIVE -eq 1 ]]; then
							echo
							echo "  The HuC firmware is not loaded on this iGPU (default before 12th gen / Alder Lake)."
							echo "  It is needed for low-power encoding (VDENC: HEVC / AV1 encode, e.g. Jellyfin / Plex)."
							ask_yn load_huc "Load it at boot with 'options i915 enable_guc=2'?" 1
							[[ $load_huc -eq 1 ]] || GUC_ACTION=""
						fi
						[[ -z $GUC_ACTION ]] && GUC_NOTE="not loaded (HuC stays off)" ;;
					*) GUC_NOTE="unknown HuC state, run 'check' after the install (or use --guc 2)" ;;
				esac
			fi ;;
	esac
	if [[ $GUC_ACTION == 2 || $GUC_ACTION == 3 ]] && grep -q 'i915.enable_gvt=1' /proc/cmdline; then
		warn "GVT-g (i915.enable_gvt=1) is on: it does not work together with enable_guc"
	fi
fi

# ---------------------------------------------------------------- install: summary
echo
info "Summary"
if [[ $DO_INTEL -eq 1 ]]; then
	echo "    Intel        : iHD + i965 VA-API drivers (non-free), QSV runtime, vainfo, intel_gpu_top"
	if pkg_installed pve-firmware; then echo "    Firmware     : from pve-firmware (Proxmox)"
	else echo "    Firmware     : firmware-intel-graphics / firmware-misc-nonfree"; fi
	case $GUC_ACTION in
		2|3) echo "    i915 HuC/GuC : options i915 enable_guc=$GUC_ACTION -> $GUC_FILE (reboot)" ;;
		off) echo "    i915 HuC/GuC : remove $GUC_FILE (reboot)" ;;
		*)   [[ -n $GUC_NOTE ]] && echo "    i915 HuC/GuC : $GUC_NOTE" ;;
	esac
fi
if [[ $DO_NVIDIA -eq 1 ]]; then
	if [[ $NV_SOURCE == nvidia ]]; then
		echo "    NVIDIA       : NVIDIA CUDA repo ($NV_DIST), branch $NV_BRANCH, $NV_FLAVOR modules, $NV_PROFILE"
	else
		echo "    NVIDIA       : Debian non-free, $NV_FLAVOR modules, $NV_PROFILE"
	fi
	echo "    Kernel       : DKMS module for $(uname -r) and later kernels ($([[ $(uname -r) == *-pve ]] && echo proxmox-headers || echo linux-headers))"
	[[ $CTK -eq 1 ]] && echo "    Containers   : nvidia-container-toolkit$(command -v docker >/dev/null && echo ' + Docker runtime')"
	[[ $LXC_NODES -eq 1 ]] && echo "    LXC          : /dev/nvidia* + /dev/nvidia-uvm at boot ($NODES_SERVICE)"
	sb_enabled && echo "    Secure Boot  : on, the DKMS key must be enrolled with mokutil (asked at the end)"
fi
echo "    Apt sources  : contrib / non-free / non-free-firmware added to the Debian sources if missing"
echo
if [[ $INTERACTIVE -eq 1 ]]; then
	confirm "Proceed?" || die "Cancelled"
fi

REBOOT=0
INITRAMFS=0
REBOOT_WHY=()
apt_update

# ---------------------------------------------------------------- install: Intel
if [[ $DO_INTEL -eq 1 ]]; then
	echo
	info "Intel media driver"
	ensure_components "intel-media-va-driver-non-free" non-free non-free-firmware
	# iHD: Broadwell (gen 8) and newer, VA-API + QSV. i965: older iGPUs, libva falls back to it.
	# libvpl2 + libmfx-gen1.2: QSV on Tiger Lake and newer, libmfx1: QSV up to Ice Lake.
	mapfile -t pkgs < <(only_available intel-media-va-driver-non-free i965-va-driver-shaders vainfo intel-gpu-tools \
		libvpl2 libmfx-gen1.2 libmfx1 intel-opencl-icd)
	firmware=()
	# pve-firmware (Proxmox kernel) already has it and conflicts with the Debian firmware packages
	if ! pkg_installed pve-firmware; then
		# trixie split the i915 / xe firmware out of firmware-misc-nonfree
		if pkg_available firmware-intel-graphics; then firmware=(firmware-intel-graphics)
		elif pkg_available firmware-misc-nonfree; then firmware=(firmware-misc-nonfree); fi
	fi
	new=()
	for p in "${pkgs[@]}"; do pkg_installed "$p" || new+=("$p"); done
	apt_install "${pkgs[@]}" "${firmware[@]}" || die "Installing the Intel packages failed"
	[[ ${#new[@]} -gt 0 ]] && state_add INTEL_PKGS "${new[@]}"
	pkg_installed intel-opencl-icd || echo "    (OpenCL: intel-opencl-icd is not in this Debian release, see the README)"
	ok "Installed ${pkgs[*]} ${firmware[*]}"

	case $GUC_ACTION in
		2|3)
			want="options i915 enable_guc=$GUC_ACTION"
			if [[ ! -f $GUC_FILE ]] || ! grep -qx "$want" "$GUC_FILE"; then
				printf '# Managed by gpu-drivers/install.sh: load the GuC / HuC firmware\n%s\n' "$want" >"$GUC_FILE"
				INITRAMFS=1; REBOOT=1; REBOOT_WHY+=("i915 enable_guc=$GUC_ACTION")
				state_set GUC "$GUC_ACTION"
				ok "$want -> $GUC_FILE"
			fi ;;
		off)
			rm -f "$GUC_FILE"; state_del GUC
			INITRAMFS=1; REBOOT=1; REBOOT_WHY+=("i915 enable_guc removed")
			ok "Removed $GUC_FILE" ;;
	esac
	if [[ ${#INTEL_GPUS[@]} -gt 0 ]] && ! grep -q 'enable_guc' <<<"${REBOOT_WHY[*]:-}"; then
		mapfile -t nodes < <(render_nodes 8086)
		if [[ ${#nodes[@]} -gt 0 ]]; then
			node=${nodes[0]}
			out=$(vainfo --display drm --device "$node" 2>&1 || true)
			drv=$(sed -n 's/.*Driver version: //p' <<<"$out")
			if [[ -n $drv ]]; then ok "VA-API on $node: $drv"
			else warn "vainfo does not work yet on $node (a reboot may be needed for the firmware)"; fi
		fi
	fi
fi

# ---------------------------------------------------------------- install: NVIDIA
if [[ $DO_NVIDIA -eq 1 ]]; then
	echo
	info "NVIDIA driver"
	sb_enabled && apt_install mokutil >/dev/null

	# Kernel headers for DKMS
	mapfile -t hdrs < <(kernel_headers_pkgs)
	[[ ${#hdrs[@]} -gt 0 ]] || die "No kernel headers package found for $(uname -r)"
	if [[ $(uname -r) == *-pve ]]; then
		[[ " ${hdrs[*]} " == *" proxmox-headers-$(uname -r) "* || " ${hdrs[*]} " == *" pve-headers-$(uname -r) "* ]] \
			|| warn "No headers for the running kernel $(uname -r) (is a newer kernel installed? Reboot into it first)"
	else
		[[ " ${hdrs[*]} " == *" linux-headers-$(uname -r) "* ]] \
			|| warn "No headers for the running kernel $(uname -r) (is a newer kernel installed? Reboot into it first)"
	fi
	apt_install "${hdrs[@]}" || die "Installing the kernel headers failed"
	ok "Kernel headers: ${hdrs[*]}"

	pkgs=()
	if [[ $NV_SOURCE == nvidia ]]; then
		ensure_components "" contrib
		if ! pkg_installed cuda-keyring; then
			command -v curl >/dev/null || apt_install curl ca-certificates >/dev/null
			url=$NV_REPO_BASE/$NV_DIST/x86_64/cuda-keyring_1.1-1_all.deb
			info "Adding NVIDIA's CUDA apt repo: $url"
			tmpd=$(mktemp -d)
			curl -fsSL "$url" -o "$tmpd/cuda-keyring.deb" || { rm -rf "$tmpd"; die "Cannot download $url"; }
			dpkg -i "$tmpd/cuda-keyring.deb"
			rm -rf "$tmpd"
			state_set NV_REPO_ADDED 1
			apt_update
		fi
		mapfile -t branches < <(apt-cache pkgnames nvidia-driver-pinning- 2>/dev/null | sed -n 's/^nvidia-driver-pinning-\([0-9][0-9][0-9]\)$/\1/p' | sort -n)
		[[ ${#branches[@]} -gt 0 ]] || die "No nvidia-driver-pinning-* package in NVIDIA's repo, is it reachable? (apt-get update)"
		[[ $NV_BRANCH == latest ]] && NV_BRANCH=${branches[-1]}
		if [[ " ${branches[*]} " != *" $NV_BRANCH "* ]]; then
			die "Branch $NV_BRANCH is not in NVIDIA's $NV_DIST repo. Available: ${branches[*]}$( [[ $NV_BRANCH == "$NV_LEGACY_BRANCH" && $NV_DIST == debian13 ]] && echo ". For Maxwell / Pascal / Volta on Debian 13 use --nvidia-source debian")"
		fi
		# The pinning package keeps apt on this branch (installed before the driver, as NVIDIA says)
		pin=nvidia-driver-pinning-$NV_BRANCH
		apt_install "$pin" >/dev/null || die "Installing $pin failed"
		state_set NV_PIN "$pin"
		ok "Staying on branch $NV_BRANCH ($pin)"
		if [[ $NV_FLAVOR == proprietary ]]; then
			deps=$(apt-cache depends nvidia-kernel-dkms 2>/dev/null || true)
			[[ $deps == *"Depends: nvidia-kernel-open-dkms"* ]] \
				&& die "Branch $NV_BRANCH has only open kernel modules. Use --flavor open (Turing or newer) or --branch 595 or older"
			kmod=nvidia-kernel-dkms
		else
			kmod=nvidia-kernel-open-dkms
		fi
		pkgs=("$kmod" nvidia-kernel-support nvidia-driver-cuda)
		[[ $NV_PROFILE == desktop ]] && pkgs+=(nvidia-driver nvidia-settings)
	else
		ensure_components "nvidia-kernel-dkms nvidia-smi" contrib non-free non-free-firmware
		if [[ $NV_FLAVOR == open ]]; then kmod=nvidia-open-kernel-dkms; else kmod=nvidia-kernel-dkms; fi
		mapfile -t pkgs < <(only_available "$kmod" nvidia-smi libcuda1 libnvcuvid1 libnvidia-encode1 nvidia-persistenced nvidia-modprobe)
		[[ " ${pkgs[*]} " == *" $kmod "* ]] || die "$kmod is not available"
		[[ $NV_PROFILE == desktop ]] && pkgs+=(nvidia-driver nvidia-settings)
	fi

	new=()
	for p in "${pkgs[@]}"; do pkg_installed "$p" || new+=("$p"); done
	opts=(--allow-downgrades)
	[[ $NV_PROFILE == compute ]] && opts+=(--no-install-recommends)
	info "Installing ${pkgs[*]} (the DKMS build takes a few minutes)"
	if ! apt_install "${opts[@]}" "${pkgs[@]}"; then
		echo
		dkms status 2>/dev/null | sed 's/^/    dkms: /' || true
		die "Installing the NVIDIA driver failed. Build log: ls /var/lib/dkms/nvidia*/*/build/make.log"
	fi
	[[ ${#new[@]} -gt 0 ]] && state_add NV_PKGS "${new[@]}"
	state_set NV_SOURCE "$NV_SOURCE"; state_set NV_FLAVOR "$NV_FLAVOR"; state_set NV_PROFILE "$NV_PROFILE"
	[[ $NV_SOURCE == nvidia ]] && state_set NV_BRANCH "$NV_BRANCH"
	ok "NVIDIA driver $(pkg_version "$kmod") installed"

	# Debian's open modules: enable the GeForce / workstation cards
	if [[ $NV_SOURCE == debian && $NV_FLAVOR == open ]]; then
		printf '# Managed by gpu-drivers/install.sh\noptions nvidia NVreg_OpenRmEnableUnsupportedGpus=1\n' >"$NV_MODPROBE_FILE"
		INITRAMFS=1
	elif [[ -f $NV_MODPROBE_FILE ]]; then
		rm -f "$NV_MODPROBE_FILE"; INITRAMFS=1
	fi

	# nouveau must stay away (the packages normally ship this blacklist)
	if ! grep -rqsE '^[[:space:]]*blacklist[[:space:]]+nouveau' /etc/modprobe.d /lib/modprobe.d /usr/lib/modprobe.d; then
		printf '# Managed by gpu-drivers/install.sh\nblacklist nouveau\noptions nouveau modeset=0\n' >"$NOUVEAU_FILE"
		ok "Blacklisted nouveau ($NOUVEAU_FILE)"
	fi
	INITRAMFS=1

	# Container toolkit
	if [[ $CTK -eq 1 ]]; then
		pkg_installed nvidia-container-toolkit || state_add CTK_PKGS nvidia-container-toolkit
		apt_install nvidia-container-toolkit || die "Installing nvidia-container-toolkit failed"
		ok "nvidia-container-toolkit $(pkg_version nvidia-container-toolkit) installed"
		if command -v docker >/dev/null; then
			if [[ $INTERACTIVE -eq 0 ]] || confirm "Add the nvidia runtime to Docker and restart Docker?"; then
				mkdir -p "$BACKUP_DIR"
				[[ -f $DOCKER_JSON ]] && cp -a "$DOCKER_JSON" "$BACKUP_DIR/daemon.json.$(date +%Y%m%d-%H%M%S)"
				nvidia-ctk runtime configure --runtime=docker
				systemctl restart docker
				state_set CTK_DOCKER 1
				ok "Docker runtime nvidia configured: docker run --rm --gpus all ... nvidia-smi"
			fi
		fi
	fi

	# Device nodes at boot for LXC containers
	if [[ $LXC_NODES -eq 1 ]]; then
		modprobe_bin=$(command -v nvidia-modprobe || true)
		if [[ -z $modprobe_bin ]]; then
			warn "nvidia-modprobe not found, cannot create the device nodes at boot"
		else
			smi=$(command -v nvidia-smi || echo /usr/bin/nvidia-smi)
			cat >"$NODES_FILE" <<EOF
# Managed by gpu-drivers/install.sh
[Unit]
Description=Create the NVIDIA device nodes (/dev/nvidia*, /dev/nvidia-uvm) for containers
After=systemd-modules-load.service
Before=pve-guests.service docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$modprobe_bin -c0 -u
ExecStart=-$smi -L

[Install]
WantedBy=multi-user.target
EOF
			systemctl daemon-reload
			systemctl enable "$NODES_SERVICE" >/dev/null 2>&1
			ok "$NODES_SERVICE enabled"
		fi
	elif [[ -f $NODES_FILE ]]; then
		systemctl disable "$NODES_SERVICE" >/dev/null 2>&1 || true
		rm -f "$NODES_FILE"; systemctl daemon-reload
		ok "Removed $NODES_SERVICE"
	fi
fi

if [[ $INITRAMFS -eq 1 ]]; then
	info "Rebuilding initramfs"
	update-initramfs -u
fi

# ---------------------------------------------------------------- install: Secure Boot + load the module
if [[ $DO_NVIDIA -eq 1 ]]; then
	SB_PENDING=0
	if sb_enabled; then
		if [[ ! -f $DKMS_MOK ]]; then
			warn "Secure Boot is on but there is no DKMS signing key ($DKMS_MOK): the module may not load"
		elif ! mok_enrolled; then
			SB_PENDING=1
			echo
			echo "  Secure Boot is on: the firmware must trust the key DKMS signed the module with."
			echo "  mokutil asks for a one-time password, then at the next boot the blue MOK Manager"
			echo "  screen appears: Enroll MOK > Continue > Yes > that password > Reboot."
			if [[ $INTERACTIVE -eq 1 ]] && confirm "Run 'mokutil --import $DKMS_MOK' now?"; then
				mokutil --import "$DKMS_MOK" </dev/tty || warn "mokutil failed, run it again by hand"
			else
				echo "  Run later: mokutil --import $DKMS_MOK, then reboot"
			fi
			REBOOT=1; REBOOT_WHY+=("enroll the DKMS key (Secure Boot)")
		fi
	fi
	if [[ -d /sys/module/nouveau ]]; then
		REBOOT=1; REBOOT_WHY+=("nouveau is loaded")
	elif [[ -r /sys/module/nvidia/version ]]; then
		mod=$(modinfo -F version nvidia 2>/dev/null || true)
		if [[ -n $mod && $mod != "$(cat /sys/module/nvidia/version)" ]]; then
			REBOOT=1; REBOOT_WHY+=("the running module is $(cat /sys/module/nvidia/version), the new one $mod")
		fi
	elif [[ $SB_PENDING -eq 0 && ${#NV_GPUS[@]} -gt 0 ]]; then
		if modprobe nvidia 2>/dev/null; then
			modprobe nvidia_uvm 2>/dev/null || true
			ok "Kernel module nvidia $(cat /sys/module/nvidia/version 2>/dev/null) loaded"
		else
			REBOOT=1; REBOOT_WHY+=("the nvidia module did not load now")
		fi
	fi
	if [[ -r /sys/module/nvidia/version && $REBOOT -eq 0 ]] && command -v nvidia-smi >/dev/null; then
		nvidia-smi --query-gpu=index,name,driver_version,memory.total --format=csv,noheader 2>&1 | sed 's/^/    nvidia-smi: /' || true
		[[ -f $NODES_FILE ]] && systemctl start "$NODES_SERVICE" 2>/dev/null || true
	fi
fi

# ---------------------------------------------------------------- done
echo
ok "Done"
if [[ $REBOOT -eq 1 ]]; then
	echo
	warn "Reboot to finish: ${REBOOT_WHY[*]:-kernel module options changed}"
	echo "  Then check with: bash install.sh check"
fi
if [[ $DO_INTEL -eq 1 ]]; then
	echo
	echo "  Intel:"
	echo "    vainfo --display drm --device /dev/dri/renderD128    (iHD driver = VA-API + QSV)"
	echo "    intel_gpu_top                                        (live GPU load)"
	echo "    Users / services need the render group: usermod -aG render USER"
fi
if [[ $DO_NVIDIA -eq 1 ]]; then
	echo
	echo "  NVIDIA:"
	echo "    nvidia-smi                       (GPU, driver version, NVENC sessions)"
	if [[ $IS_PVE -eq 1 || $LXC_NODES -eq 1 ]]; then
		echo "    LXC: pass /dev/nvidia0, /dev/nvidiactl, /dev/nvidia-uvm, /dev/nvidia-uvm-tools"
		echo "         (Proxmox: CT > Resources > Add > Device Passthrough), then install the"
		echo "         same driver version in the container without the kernel module"
		echo "         (NVIDIA .run file with --no-kernel-module). Host version: nvidia-smi"
	fi
	if [[ $NV_SOURCE == nvidia ]]; then
		echo "    Updates stay on branch $NV_BRANCH (apt upgrade). Other branch: bash install.sh install --branch N"
	fi
fi
