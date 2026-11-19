#!/usr/bin/env bash
# Add Hiren's BootCD PE (a WinPE ISO) to the GRUB menu on Debian / Ubuntu / Proxmox VE
#
# Downloads the ISO and wimboot (https://github.com/ipxe/wimboot) to /boot, reads the
# boot files from the ISO and writes /etc/grub.d/43_hbcd. GRUB loop-mounts the ISO
# and boots WinPE through wimboot, on BIOS and UEFI. Nothing is written to a USB stick.
#
# Usage:
#   bash install.sh                              (interactive)
#   bash install.sh install [--iso-dir /boot] [--iso FILE] [--sha256 HASH] [-y]
#   bash install.sh status
#   bash install.sh uninstall [--delete-iso] [-y]
#
# Via curl:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/winpe-grub/install.sh)"
set -euo pipefail

# ---------------------------------------------------------------- defaults
MODE=""
ISO_DIR=${ISO_DIR:-/boot}
ISO_ARG=""
SHA256=${HBCD_SHA256:-}
DELETE_ISO=0
ASSUME_YES=0

WIMBOOT=/boot/wimboot
WIMBOOT_URL=https://github.com/ipxe/wimboot/releases/latest/download/wimboot
HBCD_URL=https://www.hirensbootcd.org/files/HBCD_PE_x64.iso
HBCD_FILE=HBCD_PE_x64.iso
HBCD_GRUB=/etc/grub.d/43_hbcd
HBCD_TITLE="Hirens BootCD PE"
GRUB_CFG=/boot/grub/grub.cfg

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
  --iso-dir DIR   Where to download the ISO (default: /boot)
  --iso FILE      Use this ISO instead of downloading one
  --sha256 HASH   Verify the ISO (hash from hirensbootcd.org/download)
  --delete-iso    uninstall: also delete the ISO
  -y, --yes       Non-interactive, never prompt

Examples:
  $0
  $0 install --sha256 <hash> -y
  $0 install --iso /data/iso/HBCD_PE_x64.iso
  $0 uninstall --delete-iso
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

download() {   # download URL FILE (resumes a partial file)
	if command -v wget >/dev/null; then
		wget -c -q --show-progress -O "$2" "$1"
	else
		curl -fL -C - --progress-bar -o "$2" "$1"
	fi
}

installed_iso() {   # ISO path of the current entry
	[[ -f $HBCD_GRUB ]] || return 0
	sed -n 's/^# iso: //p' "$HBCD_GRUB" | head -n1
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
		--iso-dir)    [[ $# -ge 2 ]] || die "Missing value for $1"; ISO_DIR=$2; shift 2 ;;
		--iso)        [[ $# -ge 2 ]] || die "Missing value for $1"; ISO_ARG=$2; shift 2 ;;
		--sha256)     [[ $# -ge 2 ]] || die "Missing value for $1"; SHA256=$2; shift 2 ;;
		--delete-iso) DELETE_ISO=1; shift ;;
		-y|--yes)     ASSUME_YES=1; shift ;;
		-h|--help)    usage 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done
[[ $ASSUME_YES -eq 1 ]] && INTERACTIVE=0
ISO_DIR=${ISO_DIR%/}; ISO_DIR=${ISO_DIR:-/}

[[ $EUID -eq 0 ]] || die "Run as root"
[[ -f /etc/debian_version ]] || die "Only Debian / Ubuntu / Proxmox VE is supported"
for c in grub-probe grub-mkrelpath grub-script-check update-grub mount find sha256sum; do
	command -v "$c" >/dev/null || die "$c not found, is GRUB the boot loader?"
done
command -v wget >/dev/null || command -v curl >/dev/null || die "wget or curl is required: apt install curl"
[[ -f $GRUB_CFG ]] || die "$GRUB_CFG not found, is GRUB the boot loader?"

if [[ -z $MODE ]]; then
	MODE=install
	if [[ -f $HBCD_GRUB && $INTERACTIVE -eq 1 ]]; then
		info "'$HBCD_TITLE' is in the GRUB menu, ISO: $(installed_iso)"
		choose MODE "What do you want to do?" status \
			"status|Show the status and the GRUB menu entries" \
			"install|Reinstall (download the ISO again or use another one)" \
			"uninstall|Remove the GRUB entry"
	fi
fi

# ---------------------------------------------------------------- status
if [[ $MODE == status ]]; then
	if [[ -f $HBCD_GRUB ]]; then
		iso=$(installed_iso)
		echo "  [x] $HBCD_TITLE -> $iso $([[ -f $iso ]] || echo '(ISO MISSING)')"
	else
		echo "  [ ] $HBCD_TITLE"
	fi
	echo "  wimboot: $([[ -s $WIMBOOT ]] && echo present || echo missing)"
	echo
	echo "  Menu entries in $GRUB_CFG:"
	awk -F"'" '/^[[:space:]]*menuentry /{print "    - " $2}' "$GRUB_CFG"
	exit 0
fi

# ---------------------------------------------------------------- uninstall
if [[ $MODE == uninstall ]]; then
	iso=$(installed_iso)
	if [[ -f $HBCD_GRUB ]]; then
		rm -f -- "$HBCD_GRUB"
		update-grub
		ok "Removed '$HBCD_TITLE' from the GRUB menu"
	else
		warn "'$HBCD_TITLE' is not in the GRUB menu"
	fi
	if [[ -n $iso && -f $iso ]]; then
		if [[ $DELETE_ISO -eq 1 ]] || { [[ $INTERACTIVE -eq 1 ]] && confirm "Delete the ISO $iso?" N; }; then
			rm -f -- "$iso"
			ok "Deleted $iso"
		else
			info "Kept $iso"
		fi
	fi
	info "$WIMBOOT is kept, delete it by hand if nothing else uses it"
	exit 0
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

# ---------------------------------------------------------------- ISO
if [[ -n $ISO_ARG ]]; then
	ISO=$ISO_ARG
	[[ -f $ISO ]] || die "$ISO not found"
else
	ISO=$ISO_DIR/$HBCD_FILE
	mkdir -p "$ISO_DIR"
	if [[ -s $ISO ]] && [[ $INTERACTIVE -eq 1 ]] && confirm "$ISO already exists. Download it again?" N; then
		rm -f -- "$ISO"
	fi
	if [[ ! -s $ISO ]]; then
		free=$(df -BG --output=avail "$ISO_DIR" | tail -n1 | tr -dc '0-9')
		if [[ ${free:-0} -lt 4 ]]; then
			warn "Only ${free:-0} GB free in $ISO_DIR, the ISO needs about 4 GB"
			[[ $INTERACTIVE -eq 1 ]] && confirm "Continue anyway?" N || die "Not enough space, use --iso-dir DIR"
		fi
		info "Downloading $HBCD_URL"
		download "$HBCD_URL" "$ISO" || die "Download failed. The partial file is kept, run again to resume"
	fi
fi
ISO=$(readlink -f "$ISO")
# The path goes into grub.cfg as is
[[ $ISO =~ ^/[A-Za-z0-9._/+@:-]+$ ]] || die "$ISO: only letters, digits and . _ / + @ : - are supported in the ISO path"

if [[ -n $SHA256 ]]; then
	info "Verifying sha256"
	if ! echo "${SHA256,,}  $ISO" | sha256sum -c -; then
		[[ -n $ISO_ARG ]] || rm -f -- "$ISO"
		die "Checksum mismatch$([[ -n $ISO_ARG ]] || echo ', ISO deleted')"
	fi
else
	warn "Checksum not verified (use --sha256 HASH from hirensbootcd.org/download). sha256 of the ISO:"
	sha256sum "$ISO"
fi

# ---------------------------------------------------------------- wimboot
if [[ ! -s $WIMBOOT ]]; then
	info "Downloading wimboot"
	download "$WIMBOOT_URL" "$WIMBOOT.tmp" || { rm -f "$WIMBOOT.tmp"; die "wimboot download failed"; }
	mv -f "$WIMBOOT.tmp" "$WIMBOOT"
fi
chmod 644 "$WIMBOOT"

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
cleanup
if [[ -z $bcd_bios || -z $sdi || -z $wim ]]; then
	die "Unexpected ISO layout, need boot/bcd, boot/boot.sdi and sources/boot.wim"
fi
info "BCD (BIOS) = $bcd_bios, BCD (UEFI) = $bcd_efi, SDI = $sdi, WIM = $wim"

# ---------------------------------------------------------------- GRUB entry
# Paths relative to their filesystem, found by UUID: works with a separate /boot,
# LVM, RAID, and an ISO on another disk than wimboot
iso_rel=$(grub-mkrelpath "$ISO")
wb_rel=$(grub-mkrelpath "$WIMBOOT")
wb_access=$(grub_access "$WIMBOOT" root) || die "grub-probe cannot read the disk of $WIMBOOT"
iso_access=$(grub_access "$ISO" isodev) || die "grub-probe cannot read the disk of $ISO"

cat >"$HBCD_GRUB" <<EOF
#!/bin/sh
exec tail -n +3 \$0
# Written by winpe-grub/install.sh
# iso: $ISO
menuentry '$HBCD_TITLE' {
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
chmod 755 "$HBCD_GRUB"
ok "Wrote $HBCD_GRUB"

update-grub || die "update-grub failed"
grub-script-check "$GRUB_CFG" || die "$GRUB_CFG has a syntax error, check $HBCD_GRUB"
grep -q "menuentry '$HBCD_TITLE'" "$GRUB_CFG" || die "'$HBCD_TITLE' is missing from $GRUB_CFG"
ok "'$HBCD_TITLE' added to the GRUB menu"

echo
if grep -qsE '^GRUB_TIMEOUT_STYLE=["'\'']?hidden' /etc/default/grub; then
	warn "The GRUB menu is hidden (GRUB_TIMEOUT_STYLE=hidden): hold Shift (BIOS) or press Esc (UEFI) at boot"
fi
if grub_default_saved; then
	echo "  Boot it once: grub-reboot '$HBCD_TITLE' && reboot"
else
	echo "  Pick '$HBCD_TITLE' in the GRUB menu at boot."
	echo "  To boot it once from here, set GRUB_DEFAULT=saved in /etc/default/grub, run update-grub,"
	echo "  then: grub-reboot '$HBCD_TITLE' && reboot"
fi
echo "  Remove: bash install.sh uninstall"
