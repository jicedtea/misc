#!/usr/bin/env bash
# Installer for every tool in this repo. Pick the ones you want, each tool then
# runs its own installer (and its own wizard). Only the tools for this machine
# are offered: Proxmox tools on Proxmox/Debian, Synology tools on Synology DSM.
#
# Usage:
#   bash install.sh                       (menu: pick the tools)
#   bash install.sh nut backup            (install these, no menu)
#   bash install.sh all
#   bash install.sh --list
#
# Via curl:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/install.sh)"
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/install.sh)" install.sh disk-health nut
#
# Optional environment variables (passed on to the tool installers):
#   GITHUB_REPO  user/repo on GitHub          (default: jicedtea/misc)
#   GITHUB_REF   branch, tag or commit hash   (default: main)
set -euo pipefail

export GITHUB_REPO="${GITHUB_REPO:-jicedtea/misc}"
export GITHUB_REF="${GITHUB_REF:-main}"
RAW_URL="https://raw.githubusercontent.com/$GITHUB_REPO/$GITHUB_REF"

# name|description|arguments for its install.sh|platform (pve or syno)
# (gpu-passthrough last: it needs a reboot)
ALL_TOOLS=(
	"backup|vzdump hook: upload host config + dumps to an rclone remote|install|pve"
	"disk-health|SMART monitor, self-tests and reports via Proxmox notifications||pve"
	"nut|Network UPS Tools server/client for clean shutdown on power loss||pve"
	"gpu-passthrough|GPU / iGPU / GVT-g passthrough host setup (needs a reboot)|setup|pve"
	"synology-acme|acme.sh: Let's Encrypt certificate via DNS API, deployed to DSM|install|syno"
)

# Synology DSM -> only syno tools. Anything else (Proxmox / Debian) -> only pve tools
if [[ -f /etc/synoinfo.conf ]] && grep -qs productversion /etc.defaults/VERSION; then
	PLATFORM=syno; PLATFORM_NAME="Synology DSM"
else
	PLATFORM=pve; PLATFORM_NAME="Proxmox VE"
fi
TOOLS=()
for t in "${ALL_TOOLS[@]}"; do
	[[ ${t##*|} == "$PLATFORM" ]] && TOOLS+=("$t")
done

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

Without arguments a menu lets you pick the tools to install.
Each selected tool then runs its own installer and wizard.

Tools for this machine ($PLATFORM_NAME):
EOF
	for t in "${TOOLS[@]}"; do
		printf '  %-16s %s\n' "${t%%|*}" "$(cut -d'|' -f2 <<<"$t")"
	done
	cat <<EOF

Examples:
  $0
  $0 all
  $0 disk-health nut
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

[[ $EUID -eq 0 ]] || die "Run as root$([[ $PLATFORM == syno ]] && echo ' (on DSM: sudo -i)')"

# ---------------------------------------------------------------- menu
pick_whiptail() {
	local args=() t out
	for t in "${TOOLS[@]}"; do
		args+=("${t%%|*}" "$(cut -d'|' -f2 <<<"$t")" OFF)
	done
	out=$(whiptail --title "$PLATFORM_NAME tools" --separate-output \
		--checklist "Space = select, Enter = install" 16 100 ${#TOOLS[@]} "${args[@]}" \
		3>&1 1>/dev/tty 2>&3 </dev/tty) || die "Cancelled"
	mapfile -t SELECTED <<<"$out"
}

pick_text() {
	local i=1 t picks n names
	echo
	echo "  $PLATFORM_NAME tools installer"
	echo
	for t in "${TOOLS[@]}"; do
		printf '    %d) %-16s %s\n' "$i" "${t%%|*}" "$(cut -d'|' -f2 <<<"$t")"
		i=$((i + 1))
	done
	mapfile -t names < <(tool_names)
	while :; do
		read -r -p "  Tools to install, e.g. 1,3 or all: " picks </dev/tty || true
		SELECTED=()
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

if [[ ${#SELECTED[@]} -eq 0 ]]; then
	[[ $INTERACTIVE -eq 1 ]] || usage 1
	if command -v whiptail >/dev/null; then pick_whiptail; else pick_text; fi
fi
SELECTED=("${SELECTED[@]//[[:space:]]/}")
mapfile -t SELECTED < <(printf '%s\n' "${SELECTED[@]}" | grep -v '^$' || true)
[[ ${#SELECTED[@]} -gt 0 ]] || die "Nothing selected"

# Keep the order of TOOLS (gpu-passthrough last), drop duplicates
ORDERED=()
for n in $(tool_names); do
	[[ " ${SELECTED[*]} " == *" $n "* ]] && ORDERED+=("$n")
done

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

echo
info "Will install: ${ORDERED[*]}"
if [[ -n $SCRIPT_DIR && -f $SCRIPT_DIR/${ORDERED[0]}/install.sh ]]; then
	echo "    Source: local checkout ($SCRIPT_DIR)"
else
	echo "    Source: $RAW_URL"
fi

# ---------------------------------------------------------------- run
DONE=(); FAILED=()
for name in "${ORDERED[@]}"; do
	echo
	echo "${c_info}================================================================${c_off}"
	info "$name: $(tool_field "$name" 2)"
	echo "${c_info}================================================================${c_off}"
	read -r -a args <<<"$(tool_field "$name" 3)"
	if ! file=$(get_installer "$name"); then
		warn "Cannot download $RAW_URL/$name/install.sh"
		FAILED+=("$name")
		continue
	fi
	if (cd "$(dirname "$file")" && bash "$file" "${args[@]}"); then
		DONE+=("$name")
	else
		warn "$name installer failed (exit $?)"
		FAILED+=("$name")
	fi
done

# ---------------------------------------------------------------- summary
echo
info "Summary"
for n in "${DONE[@]}";   do echo "    ${c_ok}OK${c_off}      $n"; done
for n in "${FAILED[@]}"; do echo "    ${c_err}FAILED${c_off}  $n"; done
if [[ " ${DONE[*]} " == *" gpu-passthrough "* ]]; then
	echo
	warn "gpu-passthrough: reboot the host to apply the kernel/module changes"
fi
[[ ${#FAILED[@]} -eq 0 ]]
