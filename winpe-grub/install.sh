#!/usr/bin/env bash
# Add a WinPE ISO to the GRUB menu on Debian / Ubuntu / Proxmox VE
#
# Downloads wimboot (https://github.com/ipxe/wimboot) to /boot, reads the boot files
# from the ISO and writes /etc/grub.d/43_winpe. GRUB loop-mounts the ISO and boots
# WinPE through wimboot, on BIOS and UEFI. Nothing is written to a USB stick.
#
# GRUB loads boot.wim into memory below ~900 MB, so the WinPE must be small: a WinPE
# built with the Windows ADK, or the boot.wim of a Windows install ISO. Big ones like
# Hiren's BootCD PE (~3 GB boot.wim) are refused.
#
# Usage:
#   bash install.sh                                     (interactive)
#   bash install.sh install --iso /boot/WinPE.iso [--title "WinPE"] [-y]
#   bash install.sh status
#   bash install.sh uninstall [--delete-iso] [-y]
#
# Via curl:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/winpe-grub/install.sh)"
set -euo pipefail

# ---------------------------------------------------------------- defaults
MODE=""
ISO_ARG=""
TITLE_ARG=""
DELETE_ISO=0
ASSUME_YES=0

WIMBOOT=/boot/wimboot
WIMBOOT_URL=https://github.com/ipxe/wimboot/releases/latest/download/wimboot
GRUB_ENTRY=/etc/grub.d/43_winpe
OLD_GRUB_ENTRY=/etc/grub.d/43_hbcd   # earlier versions (Hiren's BootCD PE only)
DEFAULT_TITLE="WinPE"
GRUB_CFG=/boot/grub/grub.cfg
# GRUB places the initrd (BCD + boot.sdi + boot.wim) below 0x37FFFFFF (~896 MiB),
# minus what it already uses: keep a margin
MAX_INITRD_MB=800

# ---------------------------------------------------------------- helpers
c_info=$'\e[1;34m'; c_ok=$'\e[1;32m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_off=$'\e[0m'
info() { echo "${c_info}==>${c_off} $*"; }
ok()   { echo "${c_ok}[OK]${c_off} $*"; }
warn() { echo "${c_warn}[WARN]${c_off} $*" >&2; }
die()  { echo "${c_err}[ERROR]${c_off} $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $0 [install|status|uninstall] [options]

Options:
  --iso FILE      WinPE ISO to boot (boot.wim + BCD + boot.sdi under $MAX_INITRD_MB MB)
  --title NAME    Name in the GRUB menu (default: $DEFAULT_TITLE)
  --delete-iso    uninstall: also delete the ISO
  -y, --yes       Non-interactive, never prompt

Examples:
  $0
  $0 install --iso /boot/WinPE.iso -y
  $0 install --iso /srv/iso/Win11.iso --title "Windows 11 Setup / Repair"
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

download() {   # download URL FILE
	if command -v wget >/dev/null; then
		wget -q --show-progress -O "$2" "$1"
	else
		curl -fL --progress-bar -o "$2" "$1"
	fi
}

installed_file() {   # the GRUB entry of the current install (new or old name)
	if [[ -f $GRUB_ENTRY ]]; then echo "$GRUB_ENTRY"
	elif [[ -f $OLD_GRUB_ENTRY ]]; then echo "$OLD_GRUB_ENTRY"
	fi
}

installed_iso() {
	local f
	f=$(installed_file)
	[[ -n $f ]] || return 0
	sed -n 's/^# iso: //p' "$f" | head -n1
}

installed_title() {
	local f
	f=$(installed_file)
	[[ -n $f ]] || return 0
	sed -n "s/^menuentry '\(.*\)' {\$/\1/p" "$f" | head -n1
}

check_iso_path() {   # warns and returns 1 if FILE cannot be used
	local f=$1
	[[ -f $f ]] || { warn "$f not found"; return 1; }
	f=$(readlink -f "$f")
	# The path goes into grub.cfg as is
	[[ $f =~ ^/[A-Za-z0-9._/+@:-]+$ ]] || { warn "$f: only letters, digits and . _ / + @ : - are supported in the path"; return 1; }
}

check_title() {   # warns and returns 1 if NAME cannot be a GRUB menu title
	[[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9\ ._()/+:-]*$ ]] || { warn "Title: only letters, digits, spaces and . _ ( ) / + : - are supported"; return 1; }
}

grub_default_saved() {
	grep -qsE '^GRUB_DEFAULT=["'\'']?saved' /etc/default/grub
}

MNT=""
cleanup() {
	if [[ -n $MNT ]]; then
		umount "$MNT" 2>/dev/null || true
		rmdir "$MNT" 2>/dev/null || true
		MNT=""
	fi
}
trap cleanup EXIT

# find_ci PATH: case-insensitive lookup in the mounted ISO, prints the ISO-relative path
find_ci() {
	local p
	p=$(find "$MNT" -ipath "$MNT/$1" -type f 2>/dev/null | head -n1)
	[[ -n $p ]] || return 1
	printf '%s' "${p#"$MNT"}"
}

# grub_access FILE VAR: GRUB lines that load the modules for FILE's disk and set VAR to it
grub_access() {
	local f=$1 var=$2 m uuid
	for m in $(grub-probe --target=partmap "$f" 2>/dev/null || true); do echo "  insmod part_$m"; done
	for m in $(grub-probe --target=abstraction "$f" 2>/dev/null || true); do echo "  insmod $m"; done
	m=$(grub-probe --target=fs "$f") || return 1
	echo "  insmod $m"
	uuid=$(grub-probe --target=fs_uuid "$f") && [[ -n $uuid ]] || return 1
	echo "  search --no-floppy --fs-uuid --set=$var $uuid"
}

# ---------------------------------------------------------------- args
if [[ $# -gt 0 ]]; then
	case "$1" in
		install|status|uninstall) MODE=$1; shift ;;
		-h|--help) usage 0 ;;
		-*) ;;
		*) usage 1 ;;
	esac
fi

while [[ $# -gt 0 ]]; do
	case "$1" in
		--iso)        [[ $# -ge 2 ]] || die "Missing value for $1"; ISO_ARG=$2; shift 2 ;;
		--title)      [[ $# -ge 2 ]] || die "Missing value for $1"; TITLE_ARG=$2; shift 2 ;;
		--delete-iso) DELETE_ISO=1; shift ;;
		-y|--yes)     ASSUME_YES=1; shift ;;
		-h|--help)    usage 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done
[[ $ASSUME_YES -eq 1 ]] && INTERACTIVE=0

[[ $EUID -eq 0 ]] || die "Run as root"
[[ -f /etc/debian_version ]] || die "Only Debian / Ubuntu / Proxmox VE is supported"
for c in grub-probe grub-mkrelpath grub-script-check update-grub mount find; do
	command -v "$c" >/dev/null || die "$c not found, is GRUB the boot loader?"
done
[[ -f $GRUB_CFG ]] || die "$GRUB_CFG not found, is GRUB the boot loader?"

CUR_FILE=$(installed_file)
CUR_ISO=$(installed_iso)
CUR_TITLE=$(installed_title)

if [[ -z $MODE ]]; then
	MODE=install
	if [[ -n $CUR_FILE && $INTERACTIVE -eq 1 ]]; then
		info "'$CUR_TITLE' is in the GRUB menu, ISO: $CUR_ISO"
		choose MODE "What do you want to do?" status \
			"status|Show the status and the GRUB menu entries" \
			"install|Reinstall / use another ISO or name" \
			"uninstall|Remove the GRUB entry"
	fi
fi

# ---------------------------------------------------------------- status
if [[ $MODE == status ]]; then
	if [[ -n $CUR_FILE ]]; then
		echo "  [x] $CUR_TITLE -> $CUR_ISO $([[ -f $CUR_ISO ]] || echo '(ISO MISSING)')"
	else
		echo "  [ ] no WinPE entry"
	fi
	echo "  wimboot: $([[ -s $WIMBOOT ]] && echo present || echo missing)"
	echo
	echo "  Menu entries in $GRUB_CFG:"
	awk -F"'" '/^[[:space:]]*menuentry /{print "    - " $2}' "$GRUB_CFG"
	exit 0
fi

# ---------------------------------------------------------------- uninstall
if [[ $MODE == uninstall ]]; then
	if [[ -n $CUR_FILE ]]; then
		rm -f -- "$GRUB_ENTRY" "$OLD_GRUB_ENTRY"
		update-grub
		ok "Removed '$CUR_TITLE' from the GRUB menu"
	else
		warn "No WinPE entry in the GRUB menu"
	fi
	if [[ -n $CUR_ISO && -f $CUR_ISO ]]; then
		if [[ $DELETE_ISO -eq 1 ]] || { [[ $INTERACTIVE -eq 1 ]] && confirm "Delete the ISO $CUR_ISO?" N; }; then
			rm -f -- "$CUR_ISO"
			ok "Deleted $CUR_ISO"
		else
			info "Kept $CUR_ISO"
		fi
	fi
	info "$WIMBOOT is kept, delete it by hand if nothing else uses it"
	exit 0
fi

# ---------------------------------------------------------------- ISO and title
if [[ $INTERACTIVE -eq 1 ]]; then
	if [[ -z $ISO_ARG ]]; then
		echo "  WinPE ISO: build one with the Windows ADK (copype + MakeWinPEMedia /ISO), or use"
		echo "  a Windows install ISO. boot.wim must stay under about $MAX_INITRD_MB MB."
	fi
	while :; do
		ask ISO "Path to the WinPE ISO" "${ISO_ARG:-$CUR_ISO}"
		[[ -n $ISO ]] || { warn "Enter the path of the ISO"; continue; }
		check_iso_path "$ISO" && break
		ISO_ARG=""
	done
	while :; do
		ask TITLE "Name in the GRUB menu" "${TITLE_ARG:-${CUR_TITLE:-$DEFAULT_TITLE}}"
		check_title "$TITLE" && break
		TITLE_ARG=""
	done
else
	ISO=${ISO_ARG:-$CUR_ISO}
	[[ -n $ISO ]] || die "No ISO, use --iso FILE"
	check_iso_path "$ISO" || die "Cannot use $ISO"
	TITLE=${TITLE_ARG:-${CUR_TITLE:-$DEFAULT_TITLE}}
	check_title "$TITLE" || die "Invalid title: $TITLE"
fi
ISO=$(readlink -f "$ISO")

# ---------------------------------------------------------------- read the ISO
MNT=$(mktemp -d)
mount -o loop,ro "$ISO" "$MNT" || die "Cannot mount $ISO"
# BIOS and UEFI use different BCD stores; fall back to whichever exists
bcd_bios=$(find_ci 'boot/bcd' || true)
bcd_efi=$(find_ci 'efi/microsoft/boot/bcd' || true)
[[ -n $bcd_bios ]] || bcd_bios=$bcd_efi
[[ -n $bcd_efi ]] || bcd_efi=$bcd_bios
sdi=$(find_ci 'boot/boot.sdi' || true)
wim=$(find_ci 'sources/boot.wim' || true)
if [[ -z $bcd_bios || -z $sdi || -z $wim ]]; then
	die "Not a WinPE ISO: need boot/bcd (or efi/microsoft/boot/bcd), boot/boot.sdi and sources/boot.wim"
fi
# Everything wimboot gets as initrd must fit below GRUB's limit
size=$(stat -c %s "$MNT$wim" "$MNT$bcd_efi" "$MNT$sdi" | awk '{s += $1} END {print s}')
size_mb=$((size / 1024 / 1024))
cleanup
info "BCD (BIOS) = $bcd_bios, BCD (UEFI) = $bcd_efi, SDI = $sdi, WIM = $wim (${size_mb} MB in total)"
if ((size_mb > MAX_INITRD_MB)); then
	die "boot.wim + BCD + boot.sdi = ${size_mb} MB, GRUB can load at most about $MAX_INITRD_MB MB
        (it would fail at boot with 'the size of initrd is bigger than addr_max').
        Use a smaller WinPE: one built with the Windows ADK, or the boot.wim of a
        Windows install ISO. Big WinPEs like Hiren's BootCD PE cannot boot this way."
fi

# ---------------------------------------------------------------- warnings
if [[ -d /sys/firmware/efi ]] && command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -q 'enabled'; then
	warn "Secure Boot is on: GRUB may refuse to load wimboot. Turn Secure Boot off if the entry fails"
fi
if [[ -d /sys/firmware/efi ]] && command -v efibootmgr >/dev/null; then
	cur=$(efibootmgr 2>/dev/null | sed -n 's/^BootCurrent: //p')
	if [[ -n $cur ]] && efibootmgr 2>/dev/null | grep -q "^Boot$cur.* Linux Boot Manager"; then
		warn "This machine boots with systemd-boot, not GRUB: the GRUB entry will not show up"
	fi
fi

# ---------------------------------------------------------------- wimboot
if [[ ! -s $WIMBOOT ]]; then
	command -v wget >/dev/null || command -v curl >/dev/null || die "wget or curl is required: apt install curl"
	info "Downloading wimboot"
	download "$WIMBOOT_URL" "$WIMBOOT.tmp" || { rm -f "$WIMBOOT.tmp"; die "wimboot download failed"; }
	mv -f "$WIMBOOT.tmp" "$WIMBOOT"
fi
chmod 644 "$WIMBOOT"

# ---------------------------------------------------------------- GRUB entry
# Paths relative to their filesystem, found by UUID: works with a separate /boot,
# LVM, RAID, and an ISO on another disk than wimboot
iso_rel=$(grub-mkrelpath "$ISO")
wb_rel=$(grub-mkrelpath "$WIMBOOT")
wb_access=$(grub_access "$WIMBOOT" root) || die "grub-probe cannot read the disk of $WIMBOOT"
iso_access=$(grub_access "$ISO" isodev) || die "grub-probe cannot read the disk of $ISO"

rm -f -- "$OLD_GRUB_ENTRY"
cat >"$GRUB_ENTRY" <<EOF
#!/bin/sh
exec tail -n +3 \$0
# Written by winpe-grub/install.sh
# iso: $ISO
menuentry '$TITLE' {
$wb_access
$iso_access
  insmod iso9660
  insmod loopback
  loopback loop "(\$isodev)$iso_rel"
  if [ "\$grub_platform" = "efi" ]; then
    linux $wb_rel
    initrd newc:bcd:(loop)$bcd_efi \\
           newc:boot.sdi:(loop)$sdi \\
           newc:boot.wim:(loop)$wim
  else
    linux16 $wb_rel
    initrd16 newc:bcd:(loop)$bcd_bios \\
             newc:boot.sdi:(loop)$sdi \\
             newc:boot.wim:(loop)$wim
  fi
}
EOF
chmod 755 "$GRUB_ENTRY"
ok "Wrote $GRUB_ENTRY"

update-grub || die "update-grub failed"
grub-script-check "$GRUB_CFG" || die "$GRUB_CFG has a syntax error, check $GRUB_ENTRY"
grep -qF "menuentry '$TITLE'" "$GRUB_CFG" || die "'$TITLE' is missing from $GRUB_CFG"
ok "'$TITLE' added to the GRUB menu"

echo
if grep -qsE '^GRUB_TIMEOUT_STYLE=["'\'']?hidden' /etc/default/grub; then
	warn "The GRUB menu is hidden (GRUB_TIMEOUT_STYLE=hidden): hold Shift (BIOS) or press Esc (UEFI) at boot"
fi
if grub_default_saved; then
	echo "  Boot it once: grub-reboot '$TITLE' && reboot"
else
	echo "  Pick '$TITLE' in the GRUB menu at boot."
	echo "  To boot it once from here, set GRUB_DEFAULT=saved in /etc/default/grub, run update-grub,"
	echo "  then: grub-reboot '$TITLE' && reboot"
fi
echo "  Remove: bash install.sh uninstall"
