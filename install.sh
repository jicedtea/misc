#!/usr/bin/env bash
# Installer for every tool in this repo. The menu runs one tool at a time with its
# own wizard (install / check / uninstall) and comes back to the menu afterwards.
# Only the tools for this machine are offered: Debian/Ubuntu tools everywhere
# except Synology, Debian-only tools on Debian / Proxmox VE / OpenMediaVault (not Ubuntu),
# Proxmox-only tools on Proxmox VE, OMV-only tools on OpenMediaVault,
# Synology tools on Synology DSM.
#
# Usage:
#   bash install.sh                       (menu)
#   bash install.sh nut backup            (install these, no menu)
#   bash install.sh all
#   bash install.sh --list
#
# Via curl:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/install.sh)"
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/install.sh)" install.sh nut cpupower
set -euo pipefail

RAW_URL="https://raw.githubusercontent.com/jicedtea/misc/main"

# name|description|arguments for its install.sh|platform
#   linux = Debian / Ubuntu / Proxmox VE / OpenMediaVault, debian = the same without Ubuntu,
#   pve = Proxmox VE only, omv = OpenMediaVault only, syno = Synology DSM
# (gpu-passthrough and pcie-passthrough last: they need a reboot)
ALL_TOOLS=(
	"backup|vzdump hook: upload host config + dumps to an rclone remote|install|pve"
	"disk-health|SMART monitor, self-tests and alerts / weekly reports via PVE notifications||pve"
	"nut|Network UPS Tools server/client for clean shutdown on power loss||linux"
	"ipset|UFW blacklist of known-bad IPs (stamparm/ipsum), updated daily|install|linux"
	"cpupower|CPU governor (performance / schedutil / powersave...) set at every boot|install|linux"
	"turbo-unlock|Clear the BIOS turbo lock (Dell Wyse 5070 stuck at 1.5 GHz) at every boot|install|linux"
	"docker-wait-disks|Docker waits at boot for every shared folder, stays down if one is missing|install|omv"
	"omv-shared-symlinks|/shared/<name> symlink for every OpenMediaVault shared folder|install|omv"
	"omv-telegram|Forward OpenMediaVault notifications to a Telegram chat through a bot||omv"
	"winpe-grub|Hiren's BootCD PE (WinPE) in the GRUB menu, booted from the ISO|install|linux"
	"gpu-drivers|Intel media driver (VA-API / QSV) and NVIDIA driver (DKMS) for the host|install|debian"
	"gpu-passthrough|GPU / iGPU / GVT-g passthrough host setup (needs a reboot)|setup|pve"
	"pcie-passthrough|Dell Wyse 5070 PCIe slot passthrough fix: IOMMU, ACS, vfio-pci (needs a reboot)|setup|pve"
	"synology-acme|acme.sh: Let's Encrypt certificate via DNS API, deployed to DSM|install|syno"
)

# Platforms whose tools this machine can run
if [[ -f /etc/synoinfo.conf ]] && grep -qs productversion /etc.defaults/VERSION; then
	PLATFORMS=(syno); PLATFORM_NAME="Synology DSM"
elif command -v pveversion >/dev/null 2>&1; then
	PLATFORMS=(linux debian pve); PLATFORM_NAME="Proxmox VE"
elif command -v omv-salt >/dev/null 2>&1; then
	PLATFORMS=(linux debian omv); PLATFORM_NAME="OpenMediaVault"
else
	PLATFORMS=(linux)
	[[ $(. /etc/os-release 2>/dev/null && echo "${ID:-}") == debian ]] && PLATFORMS+=(debian)
	PLATFORM_NAME=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Linux}" || echo Linux)
	[[ -f /etc/debian_version ]] || echo "Warning: only Debian / Ubuntu based systems are supported" >&2
fi
# Tools bound to one OS show it in front of their description, e.g. "[Proxmox] ..."
platform_tag() {
	case $1 in
		debian) echo "[Debian] " ;;
		pve)  echo "[Proxmox] " ;;
		omv)  echo "[OMV] " ;;
		syno) echo "[Synology] " ;;
	esac
}
TOOLS=()
for t in "${ALL_TOOLS[@]}"; do
	[[ " ${PLATFORMS[*]} " == *" ${t##*|} "* ]] || continue
	IFS='|' read -r t_name t_desc t_args t_plat <<<"$t"
	TOOLS+=("$t_name|$(platform_tag "$t_plat")$t_desc|$t_args|$t_plat")
done
unset t_name t_desc t_args t_plat

# ---------------------------------------------------------------- helpers
c_info=$'\e[1;34m'; c_ok=$'\e[1;32m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_off=$'\e[0m'
info() { echo "${c_info}==>${c_off} $*"; }
ok()   { echo "${c_ok}[OK]${c_off} $*"; }
warn() { echo "${c_warn}[WARN]${c_off} $*" >&2; }
die()  { echo "${c_err}[ERROR]${c_off} $*" >&2; exit 1; }

tool_field() {   # tool_field NAME INDEX(1=name 2=desc 3=args 4=platform)
	local t
	for t in "${TOOLS[@]}"; do
		[[ ${t%%|*} == "$1" ]] && { cut -d'|' -f"$2" <<<"$t"; return 0; }
	done
	return 1
}
tool_names() { local t; for t in "${TOOLS[@]}"; do echo "${t%%|*}"; done; }

usage() {
	cat <<EOF
Usage: $0 [all | TOOL...] [--list]

Without arguments a menu lets you run the tools one at a time, each with
its own wizard (install / check / uninstall), or install several at once.
Tools given on the command line are installed one after the other.

Tools for this machine ($PLATFORM_NAME):
EOF
	for t in "${TOOLS[@]}"; do
		printf '  %-20s %s\n' "${t%%|*}" "$(cut -d'|' -f2 <<<"$t")"
	done
	cat <<EOF

Examples:
  $0
  $0 all
  $0 nut cpupower
EOF
	exit "${1:-0}"
}

# Prompts read from /dev/tty so they still work when the script is piped into bash
INTERACTIVE=0
{ : </dev/tty; } 2>/dev/null && INTERACTIVE=1

# ---------------------------------------------------------------- args
SELECTED=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		-h|--help) usage 0 ;;
		--list) tool_names; exit 0 ;;
		all) mapfile -t SELECTED < <(tool_names); shift ;;
		-*) die "Unknown option: $1" ;;
		*)
			if ! tool_field "$1" 1 >/dev/null; then
				for t in "${ALL_TOOLS[@]}"; do
					[[ ${t%%|*} == "$1" ]] && die "$1 is not available on $PLATFORM_NAME"
				done
				die "Unknown tool: $1 (see --list)"
			fi
			SELECTED+=("$1"); shift ;;
	esac
done

[[ $EUID -eq 0 ]] || die "Run as root$([[ ${PLATFORMS[0]} == syno ]] && echo ' (on DSM: sudo -i)' || echo ' (sudo -i)')"


# ---------------------------------------------------------------- source of the installers
# From a local checkout use the files next to this script, otherwise download from GitHub
SCRIPT_DIR=""
if [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]]; then
	SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fi
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

get_installer() {   # prints the path of NAME/install.sh
	local name=$1
	if [[ -n $SCRIPT_DIR && -f $SCRIPT_DIR/$name/install.sh ]]; then
		echo "$SCRIPT_DIR/$name/install.sh"
		return 0
	fi
	command -v curl >/dev/null || die "curl is required. Install it with: apt install curl"
	mkdir -p "$TMP_DIR/$name"
	curl -fsSL "$RAW_URL/$name/install.sh" -o "$TMP_DIR/$name/install.sh" || return 1
	echo "$TMP_DIR/$name/install.sh"
}

show_source() {
	if [[ -n $SCRIPT_DIR && -f $SCRIPT_DIR/$(tool_names | head -n1)/install.sh ]]; then
		echo "    Source: local checkout ($SCRIPT_DIR)"
	else
		echo "    Source: $RAW_URL"
	fi
}

# ---------------------------------------------------------------- run
declare -A RESULT=()   # tool name -> OK / FAILED (last run)

run_tool() {   # run_tool NAME [ARGS...]: runs NAME/install.sh, records the result in RESULT
	local name=$1 file rc=0
	shift
	echo
	echo "${c_info}================================================================${c_off}"
	info "$name: $(tool_field "$name" 2)"
	echo "${c_info}================================================================${c_off}"
	if ! file=$(get_installer "$name"); then
		warn "Cannot download $RAW_URL/$name/install.sh"
		RESULT[$name]=FAILED
		return 1
	fi
	(cd "$(dirname "$file")" && bash "$file" "$@") || rc=$?
	if [[ $rc -eq 0 ]]; then
		RESULT[$name]=OK
	else
		warn "$name installer failed (exit $rc)"
		RESULT[$name]=FAILED
	fi
	return "$rc"
}

run_selected() {   # installs SELECTED with each tool's default arguments
	local n ordered=() args
	SELECTED=("${SELECTED[@]//[[:space:]]/}")
	mapfile -t SELECTED < <(printf '%s\n' "${SELECTED[@]}" | grep -v '^$' || true)
	[[ ${#SELECTED[@]} -gt 0 ]] || { warn "Nothing selected"; return 1; }

	# Keep the order of TOOLS (passthrough tools last), drop duplicates
	for n in $(tool_names); do
		[[ " ${SELECTED[*]} " == *" $n "* ]] && ordered+=("$n")
	done
	echo
	info "Will install: ${ordered[*]}"
	for n in "${ordered[@]}"; do
		read -r -a args <<<"$(tool_field "$n" 3)"
		run_tool "$n" "${args[@]}" || true
	done
}

summary() {
	local n
	[[ ${#RESULT[@]} -gt 0 ]] || return 0
	echo
	info "Summary"
	for n in $(tool_names); do
		case ${RESULT[$n]:-} in
			OK)     echo "    ${c_ok}OK${c_off}      $n" ;;
			FAILED) echo "    ${c_err}FAILED${c_off}  $n" ;;
		esac
	done
	for n in gpu-passthrough pcie-passthrough; do
		if [[ ${RESULT[$n]:-} == OK ]]; then
			echo
			warn "$n: reboot the host to apply the kernel/module changes"
		fi
	done
}

# ---------------------------------------------------------------- menu
# Main menu: sets CHOICE to a tool name, "several" or "quit"
# whiptail draws the list right against the box: every tag and description gets a
# space on each side, and the box is sized to the longest line (capped to the terminal).
# Tags come back with the leading space, callers strip it.
WT_ARGS=()
WT_W=0
wt_items() {   # wt_items EXTRA_WIDTH [STATE]: fills WT_ARGS / WT_W from TOOLS (STATE = OFF for a checklist)
	local extra=$1 state=${2:-} t name desc n=0 d=0 cols
	WT_ARGS=()
	for t in "${TOOLS[@]}"; do
		IFS='|' read -r name desc _ <<<"$t"
		WT_ARGS+=(" $name" "$desc ")
		[[ -n $state ]] && WT_ARGS+=("$state")
		((${#name} > n)) && n=${#name}
		((${#desc} > d)) && d=${#desc}
	done
	cols=$({ stty size </dev/tty; } 2>/dev/null | awk '{print $2}')
	[[ $cols =~ ^[0-9]+$ ]] || cols=100
	# 2 padding spaces + 1 gap between the columns + borders and inner margins
	WT_W=$((n + d + 2 + 1 + extra))
	((WT_W > cols - 2)) && WT_W=$((cols - 2))
	((WT_W < 60)) && WT_W=60
	return 0
}

menu_whiptail() {
	local def=()
	wt_items 8
	WT_ARGS+=(" several" "Install several tools at once " " quit" "Quit ")
	[[ -n $CHOICE ]] && def=(--default-item " $CHOICE")
	CHOICE=$(whiptail --title " $PLATFORM_NAME tools " "${def[@]}" \
		--menu "Pick a tool to run its wizard (install / check / uninstall)" \
		$((${#TOOLS[@]} + 9)) "$WT_W" $((${#TOOLS[@]} + 2)) "${WT_ARGS[@]}" \
		3>&1 1>/dev/tty 2>&3 </dev/tty) || CHOICE=quit
	CHOICE=${CHOICE# }
}

menu_text() {
	local i=1 t pick names
	mapfile -t names < <(tool_names)
	echo
	echo "  ${c_info}$PLATFORM_NAME tools${c_off}"
	echo
	for t in "${TOOLS[@]}"; do
		printf '    %2d) %-20s %s\n' "$i" "${t%%|*}" "$(cut -d'|' -f2 <<<"$t")"
		i=$((i + 1))
	done
	echo
	echo "     a) Install several tools at once"
	echo "     q) Quit"
	echo
	while :; do
		read -r -p "  Choose 1-${#names[@]}, a or q: " pick </dev/tty || pick=q
		case $pick in
			q|Q) CHOICE=quit; return ;;
			a|A) CHOICE=several; return ;;
		esac
		if [[ $pick =~ ^[0-9]+$ ]] && ((pick >= 1 && pick <= ${#names[@]})); then
			CHOICE=${names[pick - 1]}
			return
		fi
		warn "Enter a number from 1 to ${#names[@]}, a or q"
	done
}

# "Install several": sets SELECTED (empty = back to the menu)
pick_whiptail() {
	local out
	wt_items 12 OFF   # 4 more for the "[ ] " box
	SELECTED=()
	out=$(whiptail --title " $PLATFORM_NAME tools " --separate-output \
		--checklist "Space = select, Enter = install, Esc = back" $((${#TOOLS[@]} + 8)) "$WT_W" ${#TOOLS[@]} "${WT_ARGS[@]}" \
		3>&1 1>/dev/tty 2>&3 </dev/tty) || return 0
	mapfile -t SELECTED <<<"$out"
	SELECTED=("${SELECTED[@]# }")
}

pick_text() {
	local i=1 t picks n names
	echo
	for t in "${TOOLS[@]}"; do
		printf '    %2d) %-20s %s\n' "$i" "${t%%|*}" "$(cut -d'|' -f2 <<<"$t")"
		i=$((i + 1))
	done
	mapfile -t names < <(tool_names)
	while :; do
		read -r -p "  Tools to install, e.g. 1,3 or all (Enter = back): " picks </dev/tty || picks=""
		SELECTED=()
		[[ -z $picks ]] && return 0
		if [[ $picks == all ]]; then SELECTED=("${names[@]}"); break; fi
		if [[ $picks =~ ^[0-9]+(,[0-9]+)*$ ]]; then
			for n in ${picks//,/ }; do
				((n >= 1 && n <= ${#names[@]})) || { SELECTED=(); break; }
				SELECTED+=("${names[n - 1]}")
			done
			[[ ${#SELECTED[@]} -gt 0 ]] && break
		fi
		warn "Enter numbers from 1 to ${#names[@]} separated by commas, or all"
	done
}

main_menu() {
	local CHOICE="" use_whiptail=0
	command -v whiptail >/dev/null && use_whiptail=1
	while :; do
		if [[ $use_whiptail -eq 1 ]]; then menu_whiptail; else menu_text; fi
		case $CHOICE in
			quit) break ;;
			several)
				if [[ $use_whiptail -eq 1 ]]; then pick_whiptail; else pick_text; fi
				[[ ${#SELECTED[@]} -gt 0 ]] || continue
				run_selected || true
				CHOICE=""
				;;
			*) run_tool "$CHOICE" || true ;;
		esac
		echo
		read -r -p "  Press Enter to return to the menu..." _ </dev/tty || break
	done
}

# ---------------------------------------------------------------- main
echo
info "$PLATFORM_NAME tools installer"
show_source
if [[ ${#SELECTED[@]} -gt 0 ]]; then
	run_selected
else
	[[ $INTERACTIVE -eq 1 ]] || usage 1
	main_menu
fi
summary
[[ " ${RESULT[*]} " != *" FAILED "* ]]
