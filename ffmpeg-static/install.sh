#!/usr/bin/env bash
# Static FFmpeg build in /usr/local/bin for Debian / Ubuntu / Proxmox VE / OpenMediaVault
#
#   install   : download a static build of ffmpeg + ffprobe, check its checksum, test that it
#               runs here and put it in /usr/local/bin (ahead of /usr/bin in PATH, so it wins
#               over the apt ffmpeg, which is left alone). Running it again updates the build.
#   check     : read-only: installed build, which ffmpeg PATH finds, hwaccels, update available
#   uninstall : remove the files this script installed
#
# Sources:
#   btbn           FFmpeg-Builds (github.com/FFmpeg-Builds, formerly BtbN): x86_64 / aarch64, glibc 2.28+,
#                  GPL build with VA-API, QSV (libvpl), NVENC / NVDEC / CUDA, Vulkan, AMF
#   johnvansickle  johnvansickle.com/ffmpeg: x86_64, i686, aarch64, armhf, armel,
#                  fully static (any glibc), no hardware acceleration, rarely updated
#                  (release 7.0.2 and a git build from 2024 at the time of writing)
#   auto           btbn where it runs, otherwise johnvansickle (default)
#
# Usage:
#   bash install.sh                                     (interactive wizard)
#   bash install.sh install -y                          (latest release, auto source)
#   bash install.sh install -y --channel git
#   bash install.sh install -y --source btbn --channel 8.1
#   bash install.sh check
#   bash install.sh uninstall
#
# Via curl:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/ffmpeg-static/install.sh)"
set -euo pipefail

# ---------------------------------------------------------------- defaults
MODE=""
SOURCE=""            # auto | btbn | johnvansickle (empty = previous choice, else auto)
CHANNEL=""           # release | git | X.Y (btbn only) (empty = previous choice, else release)
BIN_DIR=""           # empty = previous choice, else /usr/local/bin
ASSUME_YES=0
FORCE=0

BINARIES=(ffmpeg ffprobe)
STATE_DIR=/var/lib/ffmpeg-static
STATE_FILE=$STATE_DIR/state
BTBN_URL=https://github.com/FFmpeg-Builds/FFmpeg-Builds/releases/download/latest
JVS_URL=https://johnvansickle.com/ffmpeg
BTBN_GLIBC=2.28      # oldest glibc the FFmpeg-Builds Linux builds run on

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
Running install again updates to the newest build of the same source and channel.

Install options:
  --source SRC      auto (default): btbn where it runs, otherwise johnvansickle
                    btbn          = FFmpeg-Builds: x86_64 / aarch64, glibc $BTBN_GLIBC+,
                                    VA-API, QSV, NVENC / NVDEC, Vulkan
                    johnvansickle = x86_64, i686, aarch64, armhf, armel, no hardware acceleration
  --channel CH      release (default) = latest FFmpeg release
                    git               = daily build of the master branch
                    X.Y               = latest build of release branch X.Y (btbn only, e.g. 8.1)
  --bin-dir DIR     Where to put ffmpeg and ffprobe (default: /usr/local/bin)
  --force           Download and install even if the build is unchanged, and replace
                    an ffmpeg in the bin directory that this script did not install
  -y, --yes         Non-interactive, never prompt

Examples:
  $0
  $0 install -y
  $0 install -y --channel git
  $0 install -y --source johnvansickle
  $0 check
  $0 uninstall
EOF
	exit "${1:-0}"
}

needs_value() { [[ $1 -ge 2 ]] || die "$2 needs a value"; }

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

state_get() {   # state_get KEY: value from the state file of the last install
	[[ -f $STATE_FILE ]] || return 0
	sed -n "s/^$1=//p" "$STATE_FILE" | tail -n1
}

version_ge() { [[ $(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1) == "$2" ]]; }

glibc_version() {
	local v
	v=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}') || true
	[[ -n $v ]] || v=$(ldd --version 2>/dev/null | awk 'NR == 1 {print $NF}') || true
	echo "$v"
}

first_line() { "$1" -hide_banner -version 2>/dev/null | head -n1 || true; }

hwaccels() {   # hwaccels FFMPEG: the hwaccel names on one line
	"$1" -hide_banner -hwaccels 2>/dev/null | awk 'NR > 1 && NF { printf "%s%s", (n++ ? " " : ""), $1 }' || true
}

fetch() {   # fetch URL FILE
	curl -fsSL --retry 3 --connect-timeout 20 -o "$2" "$1"
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
		--source)  needs_value $# "$1"; SOURCE=$2; shift 2 ;;
		--channel) needs_value $# "$1"; CHANNEL=$2; shift 2 ;;
		--bin-dir) needs_value $# "$1"; BIN_DIR=${2%/}; shift 2 ;;
		--force)   FORCE=1; shift ;;
		-y|--yes)  ASSUME_YES=1; shift ;;
		-h|--help) usage 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done
[[ -z $SOURCE || $SOURCE =~ ^(auto|btbn|johnvansickle)$ ]] || die "--source must be auto, btbn or johnvansickle"
[[ -z $CHANNEL || $CHANNEL =~ ^(release|git|[0-9]+\.[0-9]+)$ ]] || die "--channel must be release, git or a version like 8.1"
[[ -z $BIN_DIR || $BIN_DIR == /* ]] || die "--bin-dir must be an absolute path"

[[ $EUID -eq 0 ]] || die "Run as root"
[[ $(uname -s) == Linux ]] || die "Only Linux is supported"
[[ $ASSUME_YES -eq 1 ]] && INTERACTIVE=0

INSTALLED=0; [[ -f $STATE_FILE ]] && INSTALLED=1
if [[ -z $MODE ]]; then
	if [[ $INSTALLED -eq 1 && $INTERACTIVE -eq 1 ]]; then
		echo
		echo "  Static FFmpeg $(state_get VERSION) in $(state_get BIN_DIR)"
		echo
		choose MODE "What do you want to do?" install \
			"install|Update, or switch to another source / channel" \
			"check|Check the installed build (read-only)" \
			"uninstall|Remove the static ffmpeg and ffprobe"
	else
		MODE=install
	fi
fi

# ---------------------------------------------------------------- machine
MACHINE=$(uname -m)
ARCH_BTBN="" ARCH_JVS=""
case $MACHINE in
	x86_64|amd64)  ARCH_BTBN=linux64;    ARCH_JVS=amd64 ;;
	aarch64|arm64) ARCH_BTBN=linuxarm64; ARCH_JVS=arm64 ;;
	armv7*|armv8l) ARCH_JVS=armhf ;;
	armv5*|armv6*) ARCH_JVS=armel ;;
	i?86)          ARCH_JVS=i686 ;;
esac
GLIBC=$(glibc_version)
BTBN_OK=0
[[ -n $ARCH_BTBN && -n $GLIBC ]] && version_ge "$GLIBC" "$BTBN_GLIBC" && BTBN_OK=1
btbn_why_not() {
	if [[ -z $ARCH_BTBN ]]; then echo "no FFmpeg-Builds build for $MACHINE (only x86_64 / aarch64)"
	elif [[ -z $GLIBC ]]; then echo "no glibc found (musl?), FFmpeg-Builds needs glibc $BTBN_GLIBC+"
	else echo "glibc $GLIBC is older than $BTBN_GLIBC"; fi
}

# ---------------------------------------------------------------- check
if [[ $MODE == check ]]; then
	info "Machine"
	echo "    Architecture : $MACHINE"
	echo "    glibc        : ${GLIBC:-none}"
	echo "    FFmpeg-Builds: $([[ $BTBN_OK -eq 1 ]] && echo "runs here" || btbn_why_not)"
	echo
	if [[ $INSTALLED -eq 0 ]]; then
		info "Static FFmpeg is not installed by this script"
	else
		dir=$(state_get BIN_DIR)
		info "Installed build"
		echo "    Source   : $(state_get SOURCE) ($(state_get CHANNEL))"
		echo "    File     : $(state_get ASSET)"
		echo "    Installed: $(state_get DATE)"
		for b in $(state_get FILES); do
			if [[ -x $dir/$b ]]; then
				echo "    $(printf '%-9s' "$b"): $dir/$b  $(first_line "$dir/$b" | awk '{print $3}')"
			else
				warn "$dir/$b is missing"
			fi
		done
		[[ -x $dir/ffmpeg ]] && echo "    hwaccels : $(hwaccels "$dir/ffmpeg")"
	fi
	echo
	info "PATH"
	found=$(command -v ffmpeg || true)
	if [[ -n $found ]]; then
		echo "    ffmpeg   : $found  ($(first_line "$found" | awk '{print $3}'))"
		[[ $INSTALLED -eq 1 && $found != "$(state_get BIN_DIR)/ffmpeg" ]] && warn "PATH finds $found first, not the static build"
	else
		echo "    ffmpeg   : not in PATH"
	fi
	for other in /usr/bin/ffmpeg /usr/lib/jellyfin-ffmpeg/ffmpeg; do
		[[ -x $other && $other != "$found" ]] && echo "    also     : $other  ($(first_line "$other" | awk '{print $3}'))"
	done

	# Is a newer build out? (same source and channel; best effort)
	if [[ $INSTALLED -eq 1 ]]; then
		tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
		src=$(state_get SOURCE) asset=$(state_get ASSET) remote=""
		if [[ $src == btbn ]] && fetch "$BTBN_URL/checksums.sha256" "$tmp/sums" 2>/dev/null; then
			# releases: the newest X.Y of the channel, so a new branch (9.1) shows up too
			if [[ $(state_get CHANNEL) == release ]]; then
				asset=$(grep -oE "ffmpeg-n[0-9]+\.[0-9]+-latest-$ARCH_BTBN-gpl-[0-9]+\.[0-9]+\.tar\.xz" "$tmp/sums" | sort -V | tail -n1 || true)
			fi
			remote=$(awk -v a="$asset" '$2 == a {print $1}' "$tmp/sums")
		elif [[ $src == johnvansickle ]] && fetch "$(state_get URL).md5" "$tmp/sum" 2>/dev/null; then
			remote=$(awk '{print $1; exit}' "$tmp/sum")
		fi
		echo
		if [[ -z $remote ]]; then
			warn "Cannot check for a newer build (offline?)"
		elif [[ $remote == "$(state_get SUM)" ]]; then
			ok "Up to date"
		else
			info "A newer build is available ($asset): run this script again to update"
		fi
	fi
	exit 0
fi

# ---------------------------------------------------------------- uninstall
if [[ $MODE == uninstall ]]; then
	if [[ $INSTALLED -eq 0 ]]; then
		warn "Static FFmpeg is not installed by this script (no $STATE_FILE)"
		exit 0
	fi
	dir=$(state_get BIN_DIR)
	if [[ $INTERACTIVE -eq 1 ]]; then
		confirm "Remove $(for b in $(state_get FILES); do printf '%s ' "$dir/$b"; done | sed 's/ $//')?" || die "Cancelled"
	fi
	for b in $(state_get FILES); do
		if [[ -e $dir/$b ]]; then
			rm -f "$dir/$b"
			ok "Removed $dir/$b"
		fi
	done
	rm -rf "$STATE_DIR"
	hash -r 2>/dev/null || true
	found=$(command -v ffmpeg || true)
	[[ -n $found ]] && echo "  ffmpeg in PATH is now $found ($(first_line "$found" | awk '{print $3}'))"
	exit 0
fi

# ---------------------------------------------------------------- install: choices
# Defaults: options, then the previous install, then auto / release / /usr/local/bin
SOURCE=${SOURCE:-$(state_get SOURCE)}
CHANNEL=${CHANNEL:-$(state_get CHANNEL)}
BIN_DIR=${BIN_DIR:-$(state_get BIN_DIR)}
BIN_DIR=${BIN_DIR:-/usr/local/bin}
OLD_BIN_DIR=$(state_get BIN_DIR)

command -v curl >/dev/null || die "curl is required: apt install curl"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# FFmpeg-Builds publishes one checksum file for every build; it also lists the release branches
BTBN_SUMS=$TMP/checksums.sha256
btbn_sums() {
	[[ -s $BTBN_SUMS ]] && return 0
	fetch "$BTBN_URL/checksums.sha256" "$BTBN_SUMS" || die "Cannot download $BTBN_URL/checksums.sha256"
}
btbn_branches() {   # release branches on offer, newest first, e.g. 9.0 8.1
	btbn_sums
	grep -oE "ffmpeg-n[0-9]+\.[0-9]+-latest-$ARCH_BTBN-gpl-[0-9]+\.[0-9]+\.tar\.xz" "$BTBN_SUMS" \
		| sed -E 's/^ffmpeg-n([0-9]+\.[0-9]+)-.*/\1/' | sort -Vru || true
}

if [[ $INTERACTIVE -eq 1 ]]; then
	echo
	echo "  Static FFmpeg for $MACHINE (glibc ${GLIBC:-none})"
	echo
	if [[ $BTBN_OK -eq 1 ]]; then
		[[ -z $SOURCE || $SOURCE == auto ]] && SOURCE=btbn
		choose SOURCE "Which build?" "$SOURCE" \
			"btbn|FFmpeg-Builds (BtbN): VA-API, QSV, NVENC / NVDEC, Vulkan (recommended)" \
			"johnvansickle|johnvansickle.com: fully static, no hardware acceleration, rarely updated"
	else
		warn "FFmpeg-Builds does not run here: $(btbn_why_not)"
		SOURCE=johnvansickle
	fi
	echo
	opts=()
	if [[ $SOURCE == btbn ]]; then
		mapfile -t branches < <(btbn_branches)
		[[ ${#branches[@]} -gt 0 ]] || die "No release builds for $ARCH_BTBN in $BTBN_URL/checksums.sha256"
		opts+=("release|Latest release (now ${branches[0]}), follows new releases")
		opts+=("git|Git master, daily build: newest features and fixes, less tested")
		for b in "${branches[@]:1}"; do
			opts+=("$b|Release branch $b only")
		done
	else
		[[ $CHANNEL =~ ^[0-9] ]] && CHANNEL=release
		opts+=("release|Latest release" "git|Git master, daily build: newest features and fixes, less tested")
	fi
	choose CHANNEL "Which version?" "${CHANNEL:-release}" "${opts[@]}"
	echo
	ask BIN_DIR "Install to" "$BIN_DIR"
	BIN_DIR=${BIN_DIR%/}
	[[ $BIN_DIR == /* ]] || die "The install directory must be an absolute path"
fi
CHANNEL=${CHANNEL:-release}

case ${SOURCE:-auto} in
	auto)
		if [[ $BTBN_OK -eq 1 ]]; then
			SOURCE=btbn
		elif [[ -n $ARCH_JVS ]]; then
			SOURCE=johnvansickle
			info "Using johnvansickle.com: $(btbn_why_not)"
		else
			die "No static FFmpeg build for $MACHINE"
		fi ;;
	btbn) [[ $BTBN_OK -eq 1 ]] || die "FFmpeg-Builds does not run here: $(btbn_why_not). Use --source johnvansickle" ;;
	johnvansickle) [[ -n $ARCH_JVS ]] || die "johnvansickle.com has no build for $MACHINE" ;;
esac
[[ $SOURCE == johnvansickle && $CHANNEL =~ ^[0-9] ]] && die "johnvansickle.com only has release and git builds, not $CHANNEL"

# ---------------------------------------------------------------- install: which file
# Sets ASSET, URL, SUM (expected checksum) and SUM_CMD
if [[ $SOURCE == btbn ]]; then
	btbn_sums
	case $CHANNEL in
		git)     ASSET=ffmpeg-master-latest-$ARCH_BTBN-gpl.tar.xz ;;
		release)
			latest=$(btbn_branches | sed -n 1p)
			[[ -n $latest ]] || die "No release builds for $ARCH_BTBN in $BTBN_URL/checksums.sha256"
			ASSET=ffmpeg-n$latest-latest-$ARCH_BTBN-gpl-$latest.tar.xz ;;
		*)       ASSET=ffmpeg-n$CHANNEL-latest-$ARCH_BTBN-gpl-$CHANNEL.tar.xz ;;
	esac
	SUM=$(awk -v a="$ASSET" '$2 == a {print $1}' "$BTBN_SUMS")
	[[ -n $SUM ]] || die "No build $ASSET. Release branches on offer: $(btbn_branches | tr '\n' ' ')"
	URL=$BTBN_URL/$ASSET
	SUM_CMD=sha256sum
else
	case $CHANNEL in
		git) URL=$JVS_URL/builds/ffmpeg-git-$ARCH_JVS-static.tar.xz ;;
		*)   URL=$JVS_URL/releases/ffmpeg-release-$ARCH_JVS-static.tar.xz ;;
	esac
	ASSET=${URL##*/}
	fetch "$URL.md5" "$TMP/sum" || die "Cannot download $URL.md5"
	SUM=$(awk '{print $1; exit}' "$TMP/sum")
	[[ $SUM =~ ^[0-9a-f]{32}$ ]] || die "Unexpected checksum file $URL.md5"
	SUM_CMD=md5sum
fi
command -v "$SUM_CMD" >/dev/null || die "$SUM_CMD is missing (coreutils)"

# Same build already installed?
if [[ $FORCE -eq 0 && $SUM == "$(state_get SUM)" && $BIN_DIR == "$OLD_BIN_DIR" ]]; then
	all=1
	for b in "${BINARIES[@]}"; do [[ -x $BIN_DIR/$b ]] || all=0; done
	if [[ $all -eq 1 ]]; then
		ok "Already up to date: ffmpeg $(state_get VERSION)"
		echo "  ($ASSET, use --force to install it again)"
		exit 0
	fi
fi

# Files in the bin directory that this script did not put there
foreign=()
for b in "${BINARIES[@]}"; do
	if [[ -e $BIN_DIR/$b && $BIN_DIR != "$OLD_BIN_DIR" ]]; then
		foreign+=("$BIN_DIR/$b")
	fi
done

echo
info "Summary"
echo "    Source  : $SOURCE ($CHANNEL)"
echo "    File    : $ASSET"
echo "    Install : $(for b in "${BINARIES[@]}"; do printf '%s ' "$BIN_DIR/$b"; done)"
[[ $INSTALLED -eq 1 ]] && echo "    Replaces: ffmpeg $(state_get VERSION) ($(state_get SOURCE), $(state_get CHANNEL))"
if [[ ${#foreign[@]} -gt 0 ]]; then
	warn "Not installed by this script, will be overwritten: ${foreign[*]}"
	[[ $INTERACTIVE -eq 1 || $FORCE -eq 1 ]] || die "Use --force to overwrite them"
fi
echo
if [[ $INTERACTIVE -eq 1 ]]; then
	confirm "Proceed?" || die "Cancelled"
fi

# ---------------------------------------------------------------- install: download
if ! command -v xz >/dev/null; then
	if command -v apt-get >/dev/null; then
		info "Installing xz-utils"
		DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xz-utils >/dev/null \
			|| { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xz-utils >/dev/null; } \
			|| die "Installing xz-utils failed"
	else
		die "xz is required to unpack the build"
	fi
fi

info "Downloading $URL"
progress=(-sS); [[ $INTERACTIVE -eq 1 ]] && progress=(-#)
curl -fL --retry 3 --connect-timeout 20 "${progress[@]}" -o "$TMP/$ASSET" "$URL" || die "Download failed"
(cd "$TMP" && echo "$SUM  $ASSET" | "$SUM_CMD" -c --status) || die "Checksum mismatch for $ASSET, the download is broken. Try again"
ok "Checksum OK ($SUM_CMD)"

mkdir "$TMP/x"
tar -xJf "$TMP/$ASSET" -C "$TMP/x" || die "Cannot unpack $ASSET"
declare -A FOUND=()
for b in "${BINARIES[@]}"; do
	f=$(find "$TMP/x" -type f -name "$b" | head -n1)
	[[ -n $f ]] || die "$b is not in $ASSET"
	chmod 0755 "$f"
	"$f" -hide_banner -version >/dev/null 2>&1 || die "$b from $ASSET does not run on this machine ($MACHINE, glibc ${GLIBC:-none})"
	FOUND[$b]=$f
done
VERSION=$(first_line "${FOUND[ffmpeg]}" | awk '{print $3}')

# ---------------------------------------------------------------- install: files
mkdir -p "$BIN_DIR"
for b in "${BINARIES[@]}"; do
	# copy next to the target, then rename: a running ffmpeg keeps its old file
	install -m 0755 "${FOUND[$b]}" "$BIN_DIR/.$b.new"
	mv -f "$BIN_DIR/.$b.new" "$BIN_DIR/$b"
done
ok "Installed $(for b in "${BINARIES[@]}"; do printf '%s ' "$BIN_DIR/$b"; done)"

# Moved to another directory: remove the old copies
if [[ -n $OLD_BIN_DIR && $OLD_BIN_DIR != "$BIN_DIR" ]]; then
	for b in $(state_get FILES); do
		[[ -e $OLD_BIN_DIR/$b ]] && rm -f "$OLD_BIN_DIR/$b" && ok "Removed the old $OLD_BIN_DIR/$b"
	done
fi

mkdir -p "$STATE_DIR"
cat >"$STATE_FILE" <<EOF
# Written by ffmpeg-static/install.sh, used for updates, check and uninstall
SOURCE=$SOURCE
CHANNEL=$CHANNEL
ASSET=$ASSET
URL=$URL
SUM=$SUM
VERSION=$VERSION
BIN_DIR=$BIN_DIR
FILES=${BINARIES[*]}
DATE=$(date '+%Y-%m-%d %H:%M')
EOF

# ---------------------------------------------------------------- result
hash -r 2>/dev/null || true
echo
ok "ffmpeg $VERSION"
echo "    hwaccels: $(hwaccels "$BIN_DIR/ffmpeg")"
found=$(command -v ffmpeg || true)
if [[ $found != "$BIN_DIR/ffmpeg" ]]; then
	if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
		warn "$BIN_DIR is not in PATH: call it as $BIN_DIR/ffmpeg or add it to PATH"
	else
		warn "PATH finds ${found:-no ffmpeg} before $BIN_DIR/ffmpeg"
	fi
fi
[[ -x /usr/bin/ffmpeg && $BIN_DIR == /usr/local/bin ]] \
	&& echo "    /usr/bin/ffmpeg ($(first_line /usr/bin/ffmpeg | awk '{print $3}')) stays installed, /usr/local/bin comes first in PATH"

cat <<EOF

  Update: run this script again (same source and channel)
  Check : bash install.sh check
  Shells that ran ffmpeg before may still use the old path: run 'hash -r' there
EOF
