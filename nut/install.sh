#!/usr/bin/env bash
# NUT (Network UPS Tools) installer for Proxmox VE / Debian
#
#   server : the machine with the UPS USB cable. Runs driver + upsd + upsmon (primary)
#   client : other machines. Runs upsmon (secondary), watching the server over the network
#
# Usage:
#   bash install.sh                      (interactive wizard)
#   bash install.sh server [options]
#   bash install.sh client --server 10.0.0.1 --pass <monuser password> [options]
#   bash install.sh uninstall
#
# Via wget:
#   wget -qO- https://raw.githubusercontent.com/jicedtea/misc/main/nut/install.sh | bash
set -euo pipefail

# ---------------------------------------------------------------- defaults
MODE=""
UPS_NAME="ups"
DRIVER="usbhid-ups"
PORT="auto"
SERVER_IP=""
MON_USER="monuser"
MON_PASS=""
TIMER=0              # 0 = shut down only on LOWBATT; N>0 = shut down after N seconds on battery
EMAIL="root"
ASSUME_YES=0
NUT_DIR=/etc/nut
# Used only in the hint printed at the end
RAW_URL="https://raw.githubusercontent.com/jicedtea/misc/main/nut"

# ---------------------------------------------------------------- helpers
c_info=$'\e[1;34m'; c_ok=$'\e[1;32m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_off=$'\e[0m'
info() { echo "${c_info}==>${c_off} $*"; }
ok()   { echo "${c_ok}[OK]${c_off} $*"; }
warn() { echo "${c_warn}[WARN]${c_off} $*" >&2; }
die()  { echo "${c_err}[ERROR]${c_off} $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $0 [server|client|uninstall] [options]

Run without arguments for an interactive wizard. Options given on the
command line become the defaults in the wizard (or are used as-is with -y).

Common options:
  --ups NAME         UPS name                           (default: $UPS_NAME)
  --timer SECONDS    Shut down after SECONDS on battery (default: 0 = only on low battery)
  --email ADDR       Notification recipient             (default: $EMAIL)
  -y, --yes          Non-interactive, never prompt

Server options:
  --driver NAME      NUT driver                         (default: $DRIVER)
  --port PORT        Driver port                        (default: $PORT)
  --user NAME        Username clients log in with       (default: $MON_USER)
  --pass PASS        Password for that user             (default: random)

Client options:
  --server IP        NUT server IP address              (required with -y)
  --user NAME        Username on the server             (default: $MON_USER)
  --pass PASS        Password on the server             (required with -y)

Examples:
  $0
  $0 server -y
  $0 server --timer 120
  $0 client --server 10.0.0.1 --pass secret
  $0 client --server 10.0.0.1 --pass secret --timer 60
EOF
	exit "${1:-0}"
}

# Prompts read from /dev/tty so they still work under "wget -qO- ... | bash"
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

gen_pass() { head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# ---------------------------------------------------------------- args
if [[ $# -gt 0 ]]; then
	case "$1" in
		server|client|uninstall) MODE=$1; shift ;;
		-h|--help) usage 0 ;;
		-*) ;;
		*) usage 1 ;;
	esac
fi

while [[ $# -gt 0 ]]; do
	case "$1" in
		--ups)    UPS_NAME=$2; shift 2 ;;
		--driver) DRIVER=$2; shift 2 ;;
		--port)   PORT=$2; shift 2 ;;
		--server) SERVER_IP=$2; shift 2 ;;
		--user)   MON_USER=$2; shift 2 ;;
		--pass)   MON_PASS=$2; shift 2 ;;
		--timer)  TIMER=$2; shift 2 ;;
		--email)  EMAIL=$2; shift 2 ;;
		-y|--yes) ASSUME_YES=1; shift ;;
		-h|--help) usage 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done

[[ $EUID -eq 0 ]] || die "Run as root"
[[ -f /etc/debian_version ]] || die "Only Debian / Proxmox VE is supported"
[[ $ASSUME_YES -eq 1 ]] && INTERACTIVE=0
if [[ -z $MODE ]]; then
	[[ $INTERACTIVE -eq 1 ]] || usage 1
	echo
	echo "  NUT installer for Proxmox VE"
	echo
	choose MODE "Install mode" server 		"server|Server - this machine has the UPS USB cable" 		"client|Client - watch a UPS on another NUT server" 		"uninstall|Uninstall NUT"
fi

# ---------------------------------------------------------------- uninstall
if [[ $MODE == uninstall ]]; then
	if [[ $INTERACTIVE -eq 1 ]]; then
		confirm "Remove NUT and its packages?" || die "Cancelled"
	fi
	info "Removing NUT"
	systemctl disable --now nut-monitor.service nut-server.service nut-driver.target 2>/dev/null || true
	apt-get purge -y nut nut-server nut-client
	apt-get autoremove -y
	ok "NUT removed (backups in /etc/nut.bak.* are kept)"
	exit 0
fi

# ---------------------------------------------------------------- inputs
RE_NAME='^[A-Za-z0-9._-]+$'
RE_PASS='^[A-Za-z0-9._@%+=:,-]+$'
MSG_PASS="Use only letters, digits and . _ @ % + = : , -"

[[ $INTERACTIVE -eq 1 ]] && echo && info "Configure $MODE (press Enter to keep the [default])"

if [[ $MODE == client ]]; then
	ask_valid SERVER_IP "NUT server IP"            "$SERVER_IP" '^[A-Za-z0-9.:-]+$' "Enter the IP or hostname of the NUT server"
	ask_valid UPS_NAME  "UPS name on the server"   "$UPS_NAME"  "$RE_NAME" "Use only letters, digits and . _ -"
	ask_valid MON_USER  "Username"                 "$MON_USER"  "$RE_NAME" "Use only letters, digits and . _ -"
	ask_valid MON_PASS  "Password"                 "$MON_PASS"  "$RE_PASS" "Password is required and may contain only letters, digits and . _ @ % + = : , -"
else
	[[ -n $MON_PASS ]] || MON_PASS=$(gen_pass)
	ask_valid UPS_NAME  "UPS name"                 "$UPS_NAME"  "$RE_NAME" "Use only letters, digits and . _ -"
	ask_valid DRIVER    "Driver (nut-scanner -U to detect)" "$DRIVER" "$RE_NAME" "Invalid driver name"
	ask_valid PORT      "Port"                     "$PORT"      '^[^[:space:]]+$' "Port must not contain spaces"
	ask_valid MON_USER  "Username for clients"     "$MON_USER"  "$RE_NAME" "Use only letters, digits and . _ -"
	ask_valid MON_PASS  "Password for clients"     "$MON_PASS"  "$RE_PASS" "$MSG_PASS"
fi

if [[ $INTERACTIVE -eq 1 ]]; then
	if [[ $TIMER -gt 0 ]]; then policy_def=timer; else policy_def=lowbatt; fi
	choose policy "When to shut down this machine?" "$policy_def" 		"lowbatt|When the UPS reports low battery (or the server sends FSD)" 		"timer|After N seconds on battery"
	if [[ $policy == timer ]]; then
		[[ $TIMER -gt 0 ]] || TIMER=60
		ask_valid TIMER "Seconds on battery before shutdown" "$TIMER" '^[1-9][0-9]*$' "Enter a number greater than 0"
	else
		TIMER=0
	fi
	ask EMAIL "Notification email (needs 'mail' installed)" "$EMAIL"
fi
[[ $TIMER =~ ^[0-9]+$ ]] || die "--timer must be a number of seconds"

if [[ $TIMER -gt 0 ]]; then POLICY="shutdown after ${TIMER}s on battery"; else POLICY="shutdown on low battery"; fi

echo
info "Summary"
echo "    Mode     : $MODE"
if [[ $MODE == client ]]; then
	echo "    Monitor  : $UPS_NAME@$SERVER_IP"
else
	echo "    UPS      : $UPS_NAME (driver $DRIVER, port $PORT)"
fi
echo "    Login    : $MON_USER / $MON_PASS"
echo "    Policy   : $POLICY"
echo "    Email    : $EMAIL"
echo
if [[ $INTERACTIVE -eq 1 ]]; then
	confirm "Proceed with installation?" || die "Cancelled"
fi

# ---------------------------------------------------------------- install
if [[ -d $NUT_DIR ]] && ls "$NUT_DIR"/*.conf >/dev/null 2>&1; then
	BACKUP="$NUT_DIR.bak.$(date +%Y%m%d-%H%M%S)"
	cp -a "$NUT_DIR" "$BACKUP"
	info "Backed up existing config to $BACKUP"
fi

info "Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
if [[ $MODE == server ]]; then
	apt-get install -y -qq nut nut-client nut-server usbutils >/dev/null
else
	apt-get install -y -qq nut-client >/dev/null
fi
ok "Packages installed"

mkdir -p "$NUT_DIR"

# ---------------------------------------------------------------- config: server only
if [[ $MODE == server ]]; then
	ADMIN_PASS=$(gen_pass)
	PRIMARY_PASS=$(gen_pass)

	cat >"$NUT_DIR/nut.conf" <<EOF
MODE=netserver
EOF

	cat >"$NUT_DIR/ups.conf" <<EOF
[$UPS_NAME]
	driver = $DRIVER
	port = $PORT
	pollinterval = 5
	# Seconds the UPS waits before cutting its output after the shutdown command (killpower)
	offdelay = 60
	ondelay = 0
EOF

	cat >"$NUT_DIR/upsd.conf" <<EOF
MAXAGE 15
MAXCONN 1024
# Listen on all addresses so clients can connect. Restrict with the Proxmox firewall if needed.
LISTEN 0.0.0.0 3493
LISTEN :: 3493
EOF

	cat >"$NUT_DIR/upsd.users" <<EOF
[admin]
	password = $ADMIN_PASS
	actions = set
	actions = fsd
	instcmds = ALL

[monmaster]
	password = $PRIMARY_PASS
	upsmon primary

[$MON_USER]
	password = $MON_PASS
	upsmon secondary
EOF
	chown root:nut "$NUT_DIR/upsd.users" "$NUT_DIR/upsd.conf" "$NUT_DIR/ups.conf"
	chmod 640 "$NUT_DIR/upsd.users" "$NUT_DIR/upsd.conf" "$NUT_DIR/ups.conf"

	MONITOR_LINE="MONITOR $UPS_NAME@localhost 1 monmaster $PRIMARY_PASS primary"
	DEADTIME=25
else
	cat >"$NUT_DIR/nut.conf" <<EOF
MODE=netclient
EOF
	MONITOR_LINE="MONITOR $UPS_NAME@$SERVER_IP 1 $MON_USER $MON_PASS secondary"
	DEADTIME=25
fi

# ---------------------------------------------------------------- config: upsmon (both)
cat >"$NUT_DIR/upsmon.conf" <<EOF
# root is needed so upssched-cmd can run "upsmon -c fsd"
RUN_AS_USER root
$MONITOR_LINE
MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
NOTIFYCMD "/usr/sbin/upssched"
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME $DEADTIME
POWERDOWNFLAG /etc/killpower
NOTIFYFLAG ONLINE   SYSLOG+WALL+EXEC
NOTIFYFLAG ONBATT   SYSLOG+WALL+EXEC
NOTIFYFLAG LOWBATT  SYSLOG+WALL+EXEC
NOTIFYFLAG COMMOK   SYSLOG+WALL+EXEC
NOTIFYFLAG COMMBAD  SYSLOG+WALL+EXEC
NOTIFYFLAG SHUTDOWN SYSLOG+WALL+EXEC
NOTIFYFLAG REPLBATT SYSLOG+WALL+EXEC
NOTIFYFLAG NOCOMM   SYSLOG+WALL+EXEC
NOTIFYFLAG FSD      SYSLOG+WALL+EXEC
NOTIFYFLAG NOPARENT SYSLOG+WALL+EXEC
RBWARNTIME 43200
NOCOMMWARNTIME 300
FINALDELAY 5
EOF
[[ -x /usr/sbin/upssched ]] || sed -i 's#/usr/sbin/upssched#/sbin/upssched#' "$NUT_DIR/upsmon.conf"
chown root:nut "$NUT_DIR/upsmon.conf"
chmod 640 "$NUT_DIR/upsmon.conf"

# ---------------------------------------------------------------- config: upssched (both)
{
	cat <<EOF
CMDSCRIPT $NUT_DIR/upssched-cmd
PIPEFN /run/nut/upssched.pipe
LOCKFN /run/nut/upssched.lock
AT COMMOK   * EXECUTE notify
AT COMMBAD  * EXECUTE notify
AT REPLBATT * EXECUTE notify
AT NOCOMM   * EXECUTE notify
AT NOPARENT * EXECUTE notify
AT SHUTDOWN * EXECUTE notify
AT FSD      * EXECUTE forced-shutdown
AT LOWBATT  * EXECUTE notify
EOF
	if [[ $TIMER -gt 0 ]]; then
		cat <<EOF
AT ONBATT * START-TIMER shutdown $TIMER
AT ONBATT * EXECUTE shutdown-warning
AT ONLINE * CANCEL-TIMER shutdown
AT ONLINE * EXECUTE resume
EOF
	else
		cat <<EOF
AT ONBATT * EXECUTE notify
AT ONLINE * EXECUTE notify
EOF
	fi
} >"$NUT_DIR/upssched.conf"

# ---------------------------------------------------------------- upssched-cmd (both)
cat >"$NUT_DIR/upssched-cmd" <<'EOF'
#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SHUTDOWN_TIMER="__TIMER__"
EMAIL_RECIPIENTS="__EMAIL__"
EMAIL_SUBJECT="UPS notification from $(hostname)"

case "${NOTIFYTYPE}" in
	ONLINE)   notifyMessage="UPS ${UPSNAME} - Running on line power" ;;
	ONBATT)   notifyMessage="UPS ${UPSNAME} - Line power fail, system running on battery" ;;
	LOWBATT)  notifyMessage="UPS ${UPSNAME} - Low battery power" ;;
	FSD)      notifyMessage="UPS ${UPSNAME} - Forced shutdown in progress" ;;
	COMMOK)   notifyMessage="Communications with UPS ${UPSNAME} established" ;;
	COMMBAD)  notifyMessage="Communications with UPS ${UPSNAME} lost" ;;
	SHUTDOWN) notifyMessage="Automatic logout and shutdown proceeding" ;;
	REPLBATT) notifyMessage="UPS ${UPSNAME} - The battery needs to be replaced!" ;;
	NOCOMM)   notifyMessage="Communications with UPS ${UPSNAME} cannot be established" ;;
	NOPARENT) notifyMessage="upsmon parent process died - shutdown impossible" ;;
	*)        notifyMessage="UPS ${UPSNAME} - ${NOTIFYTYPE}" ;;
esac

action=""
case "${1}" in
	shutdown-warning) message="${notifyMessage}. Shutdown in ${SHUTDOWN_TIMER} seconds." ;;
	shutdown)         message="${notifyMessage}. System is being shut down!"; action=fsd ;;
	resume)           message="${notifyMessage}. Shutdown cancelled." ;;
	forced-shutdown)  message="${notifyMessage}"; action=fsd ;;
	notify)           message="${notifyMessage}" ;;
	*)                message="Unknown command: ${1}" ;;
esac

logger -t upssched-cmd "${message}"
if command -v mail >/dev/null 2>&1; then
	echo "${message}" | mail -s "${EMAIL_SUBJECT}" ${EMAIL_RECIPIENTS} || true
fi

# Primary: sets FSD on the UPS so every client shuts down, then itself.
# Secondary: shuts down this machine only.
[ "${action}" = fsd ] && upsmon -c fsd
exit 0
EOF
sed -i "s|__TIMER__|$TIMER|; s|__EMAIL__|$EMAIL|" "$NUT_DIR/upssched-cmd"
chmod 755 "$NUT_DIR/upssched-cmd"

ok "Config written to $NUT_DIR"

# ---------------------------------------------------------------- services
info "Restarting services"
if [[ $MODE == server ]]; then
	udevadm control --reload-rules 2>/dev/null || true
	udevadm trigger --subsystem-match=usb 2>/dev/null || true
	sleep 2
	systemctl restart nut-driver-enumerator.service 2>/dev/null || true
	systemctl enable nut-driver.target nut-server.service >/dev/null 2>&1 || true
	systemctl restart nut-driver.target 2>/dev/null \
		|| systemctl restart nut-driver.service 2>/dev/null \
		|| upsdrvctl start \
		|| warn "UPS driver failed to start. Check the USB cable, then run: nut-scanner -U"
	systemctl restart nut-server.service || warn "nut-server failed: journalctl -u nut-server"
fi
systemctl enable nut-monitor.service >/dev/null 2>&1 || true
systemctl restart nut-monitor.service || warn "nut-monitor failed: journalctl -u nut-monitor"

# ---------------------------------------------------------------- verify
sleep 3
TARGET="$UPS_NAME@${SERVER_IP:-localhost}"
if STATUS=$(upsc "$TARGET" ups.status 2>/dev/null); then
	ok "upsc $TARGET -> ups.status = $STATUS  (OL = on line, OB = on battery, LB = low battery)"
else
	warn "Cannot read $TARGET. Check: upsc $TARGET / journalctl -u nut-monitor"
	if [[ $MODE == client ]]; then
		warn "Make sure port 3493/tcp on $SERVER_IP is reachable (Proxmox firewall)"
	fi
fi

echo
ok "NUT $MODE installed ($POLICY)"
if [[ $MODE == server ]]; then
	IP=$(hostname -I 2>/dev/null | awk '{print $1}')
	cat <<EOF

  Install on each client with:
    wget -qO- $RAW_URL/install.sh | bash -s -- client --server ${IP:-<this-ip>} --user $MON_USER --pass $MON_PASS

  Admin user (upsrw/upscmd): admin / $ADMIN_PASS   (stored in $NUT_DIR/upsd.users)
EOF
fi
