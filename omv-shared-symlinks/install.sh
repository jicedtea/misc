#!/usr/bin/env bash
# Symlink every OpenMediaVault shared folder into one directory
#     /shared/<shared folder name>  ->  /srv/dev-disk-by-uuid-.../<folder>
#
# Installs NiltonVolpato's Salt state from openmediavault/openmediavault#2010
# (with a configurable directory) into /srv/salt/omv/deploy/systemd/99symlinks.sls,
# then runs `omv-salt deploy run systemd`. OMV keeps the links up to date every time
# it deploys the systemd configuration. The directory is locked with chattr +i.
#
# WARNING: the state uses `clean: True`: everything in the directory that is not a
# link to a shared folder is deleted. The installer refuses a directory that holds
# anything other than symlinks.
#
# Usage:
#   bash install.sh                                   (interactive)
#   bash install.sh install [--dir /shared] [--no-lock] [-y]
#   bash install.sh print   [--dir /shared] [--no-lock]   (only print the Salt state)
#   bash install.sh uninstall [-y]
#
# Via curl:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/omv-shared-symlinks/install.sh)"
set -euo pipefail

# ---------------------------------------------------------------- defaults
MODE=""
DIR_ARG=""
LOCK=1
ASSUME_YES=0
SLS_FILE=/srv/salt/omv/deploy/systemd/99symlinks.sls
OLD_SLS_FILE=/srv/salt/omv/deploy/systemd/99sharedsymlinks.sls   # earlier versions of this script
DEFAULT_DIR=/shared

# ---------------------------------------------------------------- helpers
c_info=$'\e[1;34m'; c_ok=$'\e[1;32m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_off=$'\e[0m'
info() { echo "${c_info}==>${c_off} $*"; }
ok()   { echo "${c_ok}[OK]${c_off} $*"; }
warn() { echo "${c_warn}[WARN]${c_off} $*" >&2; }
die()  { echo "${c_err}[ERROR]${c_off} $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $0 [install|uninstall|print] [options]

Options:
  -d, --dir DIR  Directory that holds the symlinks (default: $DEFAULT_DIR)
  --no-lock      Do not lock the directory with chattr +i
  -y, --yes      Non-interactive, never prompt

Examples:
  $0
  $0 install --dir /shared -y
  $0 print --dir /data/share
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

# check_dir DIR: warns and returns 1 if DIR cannot hold the symlinks
check_dir() {
	local d=$1 extra
	[[ $d == /* ]] || { warn "$d: not an absolute path"; return 1; }
	# Also keeps sed and the Salt/Jinja quoting safe
	[[ $d =~ ^/[A-Za-z0-9._/-]+$ ]] || { warn "$d: only letters, digits and . _ - / are supported"; return 1; }
	[[ /$d/ != */../* && /$d/ != */./* && $d != *//* ]] || { warn "$d: do not use . or .. or //"; return 1; }
	case $d in
		/|/bin|/boot|/dev|/etc|/export|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
			warn "$d: refusing to use a system directory"; return 1 ;;
	esac
	if [[ -L $d ]]; then
		warn "$d is a symlink, use a real directory"; return 1
	fi
	if [[ -e $d && ! -d $d ]]; then
		warn "$d exists but is not a directory"; return 1
	fi
	# clean: True would delete anything that is not a managed symlink
	if [[ -d $d ]]; then
		extra=$(find "$d" -mindepth 1 -maxdepth 1 ! -type l -printf '      %p\n' 2>/dev/null | head -n 10)
		if [[ -n $extra ]]; then
			warn "$d holds files or folders that would be DELETED:"
			echo "$extra" >&2
			warn "Move them away or pick an empty directory"
			return 1
		fi
	fi
}

# Directory of the current install (from the .sls header)
installed_dir() {
	[[ -f $SLS_FILE ]] || return 0
	sed -n 's/^# target_dir: //p' "$SLS_FILE" | head -n1
}

installed_lock() {
	[[ -f $SLS_FILE ]] || return 0
	sed -n 's/^{% set use_lock = \(True\|False\) %}$/\1/p' "$SLS_FILE" | head -n1
}

# remove_links_in DIR: unlocks DIR, deletes its symlinks, removes it when empty
remove_links_in() {
	local d=$1
	[[ -d $d ]] || return 0
	chattr -i "$d" 2>/dev/null || true
	info "Removing the symlinks in $d"
	find "$d" -mindepth 1 -maxdepth 1 -type l -print -delete
	if rmdir "$d" 2>/dev/null; then
		ok "Removed the empty directory $d"
	else
		warn "Kept $d, it still holds files or folders"
	fi
}

# ---------------------------------------------------------------- Salt state
render_sls() {   # render_sls DIR True|False
	# Quoted heredoc so bash leaves the Jinja {{ }} / {% %} alone; sed fills the placeholders
	sed -e "s|__TARGET_DIR__|$1|g" -e "s|__LOCK__|$2|g" <<'SLS'
# Generated by omv-shared-symlinks/install.sh
# target_dir: __TARGET_DIR__
#
# Salt state by NiltonVolpato (openmediavault/openmediavault#2010),
# with a configurable target directory. Re-apply: omv-salt deploy run systemd
#
# WARNING: prune_stale_share_symlinks uses `clean: True` and deletes EVERYTHING
# in __TARGET_DIR__ that is not a symlink managed by this state (real files too).

{% set share_root = '__TARGET_DIR__' %}
{% set use_lock = __LOCK__ %}
{% set sharedfolder_config = salt['omv_conf.get']('conf.system.sharedfolder') %}

create_share_root_dir:
  file.directory:
    - name: "{{ share_root }}"
    - user: root
    - group: root
    - mode: "0755"
{% if use_lock %}
    - attrs: i
{% endif %}

{% if use_lock and sharedfolder_config %}
unlock_share_directory_for_symlink:
  cmd.run:
    - name: chattr -i "{{ share_root }}"
    - prereq:
{% for sf in sharedfolder_config %}
      - file: create_symlink_{{ sf.uuid }}
{% endfor %}
{% endif %}

{% for sf in sharedfolder_config %}
  {% set sf_path = salt['omv_conf.get_sharedfolder_path'](sf.uuid) %}
  {% set link_path = share_root ~ '/' ~ sf.name %}
create_symlink_{{ sf.uuid }}:
  file.symlink:
    - name: "{{ link_path }}"
    - target: "{{ sf_path }}"
    - force: True
    - require:
      - file: create_share_root_dir
    - require_in:
      - file: prune_stale_share_symlinks
{% endfor %}

{% if use_lock and sharedfolder_config %}
lock_share_directory_for_symlink:
  cmd.run:
    - name: chattr +i "{{ share_root }}"
    - onchanges:
{% for sf in sharedfolder_config %}
      - file: create_symlink_{{ sf.uuid }}
{% endfor %}
{% endif %}

# ---

{% if use_lock %}
unlock_share_directory_for_prune:
  cmd.run:
    - name: chattr -i "{{ share_root }}"
    - prereq:
      - file: prune_stale_share_symlinks
{% endif %}

prune_stale_share_symlinks:
  file.directory:
    - name: "{{ share_root }}"
    - clean: True

{% if use_lock %}
lock_share_directory_for_prune:
  cmd.run:
    - name: chattr +i "{{ share_root }}"
    - onchanges:
      - file: prune_stale_share_symlinks
{% endif %}
SLS
}

lock_value() { [[ $LOCK -eq 1 ]] && echo True || echo False; }

# ---------------------------------------------------------------- args
if [[ $# -gt 0 ]]; then
	case "$1" in
		install|uninstall|print) MODE=$1; shift ;;
		-h|--help) usage 0 ;;
		-*) ;;
		*) usage 1 ;;
	esac
fi

while [[ $# -gt 0 ]]; do
	case "$1" in
		-d|--dir)  [[ $# -ge 2 ]] || die "Missing value for $1"; DIR_ARG=$2; shift 2 ;;
		--dir=*)   DIR_ARG=${1#*=}; shift ;;
		--no-lock) LOCK=0; shift ;;
		-y|--yes)  ASSUME_YES=1; shift ;;
		-h|--help) usage 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done
[[ $ASSUME_YES -eq 1 ]] && INTERACTIVE=0
[[ -z $DIR_ARG || $DIR_ARG == / ]] || DIR_ARG=${DIR_ARG%/}

# print only renders the state, no root or OMV needed
if [[ $MODE == print ]]; then
	TARGET_DIR=${DIR_ARG:-$DEFAULT_DIR}
	[[ $TARGET_DIR =~ ^/[A-Za-z0-9._/-]+$ ]] || die "$TARGET_DIR: only letters, digits and . _ - / are supported"
	render_sls "$TARGET_DIR" "$(lock_value)"
	exit 0
fi

[[ $EUID -eq 0 ]] || die "Run as root"
command -v omv-salt >/dev/null || die "omv-salt not found, this is not an OpenMediaVault system"
[[ -d ${SLS_FILE%/*} ]] || die "${SLS_FILE%/*} not found, unsupported OpenMediaVault version"

CURRENT=$(installed_dir)
if [[ -z $MODE ]]; then
	MODE=install
	if [[ -n $CURRENT && $INTERACTIVE -eq 1 ]]; then
		info "Installed: shared folders are linked in $CURRENT (lock: $(installed_lock))"
		choose MODE "What do you want to do?" install \
			"install|Reinstall / change the directory" \
			"uninstall|Uninstall"
	fi
fi

# ---------------------------------------------------------------- uninstall
if [[ $MODE == uninstall ]]; then
	if [[ -f $SLS_FILE || -f $OLD_SLS_FILE ]]; then
		rm -f -- "$SLS_FILE" "$OLD_SLS_FILE"
		ok "Removed the Salt state $SLS_FILE"
	else
		warn "$SLS_FILE not found, not installed"
	fi
	if [[ -n ${CURRENT:-$DIR_ARG} ]]; then
		remove_links_in "${CURRENT:-$DIR_ARG}"
	fi
	ok "Uninstalled"
	exit 0
fi

# ---------------------------------------------------------------- install
command -v chattr >/dev/null || die "chattr not found (package e2fsprogs)"

if [[ $INTERACTIVE -eq 1 ]]; then
	while :; do
		ask TARGET_DIR "Directory for the symlinks" "${DIR_ARG:-${CURRENT:-$DEFAULT_DIR}}"
		[[ $TARGET_DIR == / ]] || TARGET_DIR=${TARGET_DIR%/}
		# The installed directory may be locked and hold only our links: always fine
		[[ $TARGET_DIR == "$CURRENT" ]] && break
		check_dir "$TARGET_DIR" && break
	done
	if [[ -z $DIR_ARG && $LOCK -eq 1 && $(installed_lock) == False ]]; then LOCK=0; fi
	if [[ $LOCK -eq 1 ]]; then
		confirm "Lock the directory with chattr +i (nothing else can write into it)?" Y || LOCK=0
	else
		confirm "Lock the directory with chattr +i (nothing else can write into it)?" N && LOCK=1
	fi
else
	TARGET_DIR=${DIR_ARG:-${CURRENT:-$DEFAULT_DIR}}
	[[ $TARGET_DIR == "$CURRENT" ]] || check_dir "$TARGET_DIR" || die "Cannot use $TARGET_DIR"
fi

echo
info "Summary"
echo "    Salt state : $SLS_FILE"
echo "    Directory  : $TARGET_DIR/<shared folder name> -> shared folder path"
echo "    Lock       : $([[ $LOCK -eq 1 ]] && echo 'chattr +i' || echo no)"
[[ -n $CURRENT && $CURRENT != "$TARGET_DIR" ]] && echo "    Old links in $CURRENT are removed"
warn "Anything in $TARGET_DIR that is not a link to a shared folder will be deleted"
echo
if [[ $INTERACTIVE -eq 1 ]]; then
	confirm "Proceed?" || die "Cancelled"
fi

if [[ -n $CURRENT && $CURRENT != "$TARGET_DIR" ]]; then
	remove_links_in "$CURRENT"
fi

# Two states managing the same directory would conflict
rm -f -- "$OLD_SLS_FILE"

render_sls "$TARGET_DIR" "$(lock_value)" >"$SLS_FILE"
chmod 0644 "$SLS_FILE"
ok "Wrote $SLS_FILE"

info "Running: omv-salt deploy run systemd"
omv-salt deploy run systemd || die "omv-salt deploy failed, check the output above"

echo
info "Symlinks in $TARGET_DIR:"
ls -l "$TARGET_DIR" || true
[[ $LOCK -eq 1 ]] && lsattr -d "$TARGET_DIR" 2>/dev/null || true

cat <<EOF

  New or renamed shared folders are linked the next time OMV deploys the systemd
  configuration. To apply now: omv-salt deploy run systemd
  Remove: bash install.sh uninstall
EOF
