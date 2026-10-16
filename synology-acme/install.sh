#!/usr/bin/env bash
# acme.sh installer for Synology DSM
#
# Installs acme.sh, issues a certificate through a DNS API (DNS-01, works for
# wildcards and without opening ports) and deploys it to DSM with the
# synology_dsm deploy hook. Renewal runs from a DSM Task Scheduler task.
#
# Based on: https://github.com/acmesh-official/acme.sh/wiki/Synology-NAS-Guide
#
# Usage (as root: sudo -i):
#   bash install.sh                      (interactive wizard)
#   bash install.sh install [options]
#   bash install.sh uninstall
#
# Via curl:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jicedtea/misc/main/synology-acme/install.sh)"
set -euo pipefail

# ---------------------------------------------------------------- defaults
MODE=""
EMAIL=""
DOMAINS=""           # comma separated, the first one is the main domain: example.com,*.example.com
DNS_API="dns_cf"
CA="letsencrypt"
KEYLENGTH="ec-384"
AUTH="temp"          # temp = SYNO_USE_TEMP_ADMIN, user = existing admin (SYNO_USERNAME / SYNO_PASSWORD)
CERT_DESC=""         # DSM certificate description. Empty = replace the default certificate
ASSUME_YES=0
ACME_HOME=/usr/local/share/.acme.sh
ACME_URL="https://github.com/acmesh-official/acme.sh/archive/master.tar.gz"
DNS_VARS=()          # NAME=value pairs exported for the DNS API

# ---------------------------------------------------------------- helpers
c_info=$'\e[1;34m'; c_ok=$'\e[1;32m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_off=$'\e[0m'
info() { echo "${c_info}==>${c_off} $*"; }
ok()   { echo "${c_ok}[OK]${c_off} $*"; }
warn() { echo "${c_warn}[WARN]${c_off} $*" >&2; }
die()  { echo "${c_err}[ERROR]${c_off} $*" >&2; exit 1; }

usage() {
	cat <<EOF
Usage: $0 [install|uninstall] [options]

Run without arguments for an interactive wizard. Options given on the
command line become the defaults in the wizard (or are used as-is with -y).

Options:
  --email ADDR        Account email for the CA
  --domain LIST       Comma separated, first = main name, e.g. nas.example.com
                      or example.com,*.example.com
  --dns NAME          acme.sh DNS API                    (default: $DNS_API)
                      list: https://github.com/acmesh-official/acme.sh/wiki/dnsapi
  --dns-var NAME=VAL  Credential for the DNS API, repeat as needed
                      (e.g. --dns-var CF_Token=xxx). Exported env vars work too.
  --ca NAME           letsencrypt | zerossl              (default: $CA)
  --keylength LEN     ec-256 | ec-384 | 2048 | 4096      (default: $KEYLENGTH)
  --auth temp|user    temp = temporary admin created by the deploy hook (default)
                      user = existing admin from SYNO_USERNAME / SYNO_PASSWORD
  --cert-desc TEXT    DSM certificate description. Empty (default) replaces
                      the default certificate, otherwise a new one is created
  -y, --yes           Non-interactive, never prompt

Examples:
  $0
  $0 install -y --email me@example.com --domain nas.example.com --dns-var CF_Token=xxx
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

# ask_secret VAR "Prompt"   (input hidden, keeps the current value on Enter)
ask_secret() {
	local __var=$1 __prompt=$2 __ans=""
	if [[ $INTERACTIVE -eq 1 ]]; then
		read -r -s -p "  $__prompt${!__var:+ [keep current]}: " __ans </dev/tty || true
		echo
	fi
	[[ -n $__ans ]] && printf -v "$__var" '%s' "$__ans"
	return 0
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

is_synology() { [[ -f /etc/synoinfo.conf ]] && grep -qs productversion /etc.defaults/VERSION; }
dsm_version() { sed -n 's/^productversion="\(.*\)"/\1/p' /etc.defaults/VERSION; }
acme() { "$ACME_HOME/acme.sh" --home "$ACME_HOME" "$@"; }
mask() { local v=$1; [[ ${#v} -le 6 ]] && echo "***" || echo "${v:0:3}***${v: -2}"; }

# ---------------------------------------------------------------- args
if [[ $# -gt 0 ]]; then
	case "$1" in
		install|uninstall) MODE=$1; shift ;;
		-h|--help) usage 0 ;;
		-*) ;;
		*) usage 1 ;;
	esac
fi

while [[ $# -gt 0 ]]; do
	case "$1" in
		--email)     EMAIL=$2; shift 2 ;;
		--domain)    DOMAINS=$2; shift 2 ;;
		--dns)       DNS_API=$2; shift 2 ;;
		--dns-var)   DNS_VARS+=("$2"); shift 2 ;;
		--ca)        CA=$2; shift 2 ;;
		--keylength) KEYLENGTH=$2; shift 2 ;;
		--auth)      AUTH=$2; shift 2 ;;
		--cert-desc) CERT_DESC=$2; shift 2 ;;
		-y|--yes)    ASSUME_YES=1; shift ;;
		-h|--help)   usage 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done

[[ $EUID -eq 0 ]] || die "Run as root (on DSM: sudo -i)"
is_synology || die "This is not a Synology DSM system"
command -v curl >/dev/null || die "curl is required"
[[ $ASSUME_YES -eq 1 ]] && INTERACTIVE=0
if [[ -z $MODE ]]; then
	if [[ $INTERACTIVE -eq 1 ]]; then
		echo
		echo "  acme.sh for Synology DSM $(dsm_version)"
		echo
		choose MODE "What do you want to do?" install \
			"install|Install acme.sh, issue a certificate and deploy it to DSM" \
			"uninstall|Uninstall acme.sh (certificates already in DSM are kept)"
	else
		MODE=install
	fi
fi

# ---------------------------------------------------------------- uninstall
if [[ $MODE == uninstall ]]; then
	[[ -x $ACME_HOME/acme.sh ]] || die "acme.sh is not installed in $ACME_HOME"
	if [[ $INTERACTIVE -eq 1 ]]; then
		confirm "Uninstall acme.sh and delete $ACME_HOME (account, saved credentials, issued certs)?" || die "Cancelled"
	fi
	acme --uninstall || true
	rm -rf "$ACME_HOME"
	ok "acme.sh removed. Certificates already imported into DSM are kept"
	warn "Delete the renewal task in Control Panel > Task Scheduler"
	exit 0
fi

# ---------------------------------------------------------------- inputs
# DNS credentials already in the environment (e.g. CF_Token=... bash install.sh)
add_dns_var() {
	local kv=$1 k=${1%%=*} i
	[[ $kv == *=* && $k =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Invalid --dns-var: $kv (use NAME=value)"
	for i in "${!DNS_VARS[@]}"; do
		[[ ${DNS_VARS[i]%%=*} == "$k" ]] && { DNS_VARS[i]=$kv; return 0; }
	done
	DNS_VARS+=("$kv")
}
for kv in "${DNS_VARS[@]}"; do add_dns_var "$kv"; done
dns_var_get() { local kv; for kv in "${DNS_VARS[@]}"; do [[ ${kv%%=*} == "$1" ]] && { echo "${kv#*=}"; return 0; }; done; printenv "$1" || true; }

if [[ $INTERACTIVE -eq 1 ]]; then
	echo
	info "Configure (press Enter to keep the [default])"
	ask_valid EMAIL   "Account email" "$EMAIL" '^[^@[:space:]]+@[^@[:space:]]+$' "Enter a valid email"
	ask_valid DOMAINS "Domain(s), comma separated, e.g. nas.example.com or example.com,*.example.com" \
		"$DOMAINS" '^[A-Za-z0-9*.-]+(,[A-Za-z0-9*.-]+)*$' "Use domain names separated by commas"

	echo
	prev_dns=$DNS_API
	choose provider "DNS provider (acme.sh DNS API)" "$([[ $DNS_API == dns_cf ]] && echo cf || echo other)" \
		"cf|Cloudflare (dns_cf)" \
		"other|Other (enter the acme.sh dnsapi name)"
	if [[ $provider == cf ]]; then
		DNS_API=dns_cf
	else
		[[ $prev_dns == dns_cf ]] && prev_dns=""
		ask_valid DNS_API "DNS API name, e.g. dns_gd, dns_aws, dns_dgon" "$prev_dns" '^dns_[A-Za-z0-9_]+$' "Name starts with dns_"
	fi

	if [[ $DNS_API == dns_cf ]]; then
		echo "  Cloudflare API token with Zone:Read + DNS:Edit for the zone"
		tok=$(dns_var_get CF_Token)
		ask_secret tok "CF_Token"
		[[ -n $tok ]] || die "CF_Token is required"
		add_dns_var "CF_Token=$tok"
		acc=$(dns_var_get CF_Account_ID)
		ask acc "CF_Account_ID (optional, Enter to skip)" "$acc"
		[[ -n $acc ]] && add_dns_var "CF_Account_ID=$acc"
	else
		echo "  Enter the credentials $DNS_API needs as NAME=value, one per line,"
		echo "  empty line to finish. See https://github.com/acmesh-official/acme.sh/wiki/dnsapi"
		while :; do
			ask kv "NAME=value" ""
			[[ -z $kv ]] && break
			add_dns_var "$kv"
		done
	fi

	echo
	choose CA "Certificate authority" "$CA" \
		"letsencrypt|Let's Encrypt" \
		"zerossl|ZeroSSL (acme.sh default, registers the email)"
	choose KEYLENGTH "Key type" "$KEYLENGTH" \
		"ec-384|ECDSA P-384 (guide default)" \
		"ec-256|ECDSA P-256" \
		"2048|RSA 2048 (for old clients)" \
		"4096|RSA 4096"

	echo
	choose AUTH "How should the deploy hook log in to DSM?" "$AUTH" \
		"temp|Temporary admin user (recommended, no password stored)" \
		"user|Existing admin user (password saved by acme.sh, 2FA asks for a code)"
	if [[ $AUTH == user ]]; then
		SYNO_USERNAME=${SYNO_USERNAME:-}
		SYNO_PASSWORD=${SYNO_PASSWORD:-}
		ask_valid SYNO_USERNAME "DSM admin username" "$SYNO_USERNAME" '^[^[:space:]]+$' "Username is required"
		ask_secret SYNO_PASSWORD "DSM admin password"
		[[ -n $SYNO_PASSWORD ]] || die "Password is required"
	fi
	ask CERT_DESC "DSM certificate description (Enter = replace the default certificate)" "$CERT_DESC"
fi

[[ -n $EMAIL ]]   || die "--email is required"
[[ -n $DOMAINS ]] || die "--domain is required"
[[ $CA == letsencrypt || $CA == zerossl ]] || die "--ca must be letsencrypt or zerossl"
[[ $KEYLENGTH =~ ^(ec-256|ec-384|2048|3072|4096)$ ]] || die "Invalid --keylength: $KEYLENGTH"
[[ $AUTH == temp || $AUTH == user ]] || die "--auth must be temp or user"
if [[ $AUTH == user ]]; then
	[[ -n ${SYNO_USERNAME:-} && -n ${SYNO_PASSWORD:-} ]] || die "--auth user needs SYNO_USERNAME and SYNO_PASSWORD in the environment"
fi
[[ $DNS_API =~ ^dns_ ]] || die "Invalid --dns: $DNS_API"
if [[ $DNS_API == dns_cf && -z $(dns_var_get CF_Token) && -z $(dns_var_get CF_Key) ]]; then
	die "dns_cf needs CF_Token (or CF_Key + CF_Email): --dns-var CF_Token=..."
fi

IFS=, read -r -a DOMAIN_LIST <<<"$DOMAINS"
MAIN=${DOMAIN_LIST[0]}
ECC=(); [[ $KEYLENGTH == ec-* ]] && ECC=(--ecc)

# ---------------------------------------------------------------- summary
echo
info "Summary"
echo "    DSM        : $(dsm_version)"
echo "    acme.sh    : $ACME_HOME"
echo "    Email      : $EMAIL"
echo "    Domains    : ${DOMAIN_LIST[*]}"
echo "    DNS API    : $DNS_API"
for kv in "${DNS_VARS[@]}"; do
	echo "                 ${kv%%=*}=$(mask "${kv#*=}")"
done
echo "    CA / key   : $CA / $KEYLENGTH"
if [[ $AUTH == temp ]]; then
	echo "    DSM login  : temporary admin"
else
	echo "    DSM login  : $SYNO_USERNAME"
fi
echo "    DSM cert   : ${CERT_DESC:-default certificate}"
echo
if [[ $INTERACTIVE -eq 1 ]]; then
	confirm "Proceed?" || die "Cancelled"
fi

# ---------------------------------------------------------------- install acme.sh
if [[ -x $ACME_HOME/acme.sh ]]; then
	info "acme.sh already installed, upgrading"
	acme --upgrade --nocron || warn "Upgrade failed, using the installed version"
else
	info "Installing acme.sh to $ACME_HOME"
	TMP_DIR=$(mktemp -d)
	trap 'rm -rf "$TMP_DIR"' EXIT
	curl -fsSL "$ACME_URL" -o "$TMP_DIR/acme.tar.gz"
	tar xzf "$TMP_DIR/acme.tar.gz" -C "$TMP_DIR"
	(cd "$TMP_DIR/acme.sh-master" && ./acme.sh --install --nocron --home "$ACME_HOME" --accountemail "$EMAIL")
fi
[[ -x $ACME_HOME/acme.sh ]] || die "acme.sh install failed"
ok "acme.sh $(acme --version | tail -1)"

# ---------------------------------------------------------------- issue
for kv in "${DNS_VARS[@]}"; do export "${kv?}"; done
args=()
for d in "${DOMAIN_LIST[@]}"; do args+=(-d "$d"); done

info "Issuing the certificate for ${DOMAIN_LIST[*]} (DNS-01 via $DNS_API)"
set +e
acme --issue --server "$CA" "${args[@]}" --dns "$DNS_API" --keylength "$KEYLENGTH" </dev/null
rc=$?
set -e
case $rc in
	0) ok "Certificate issued" ;;
	2) ok "Certificate is still valid, not renewed (use acme.sh --renew --force to force it)" ;;
	*) die "Issuing failed (exit $rc). Check the DNS credentials and the log above" ;;
esac

# ---------------------------------------------------------------- deploy
info "Deploying to DSM (synology_dsm)"
if [[ $AUTH == temp ]]; then
	export SYNO_USE_TEMP_ADMIN=1
else
	export CLEAR_SYNO_USE_TEMP_ADMIN=1
	export SYNO_USERNAME SYNO_PASSWORD
fi
export SYNO_CERTIFICATE="$CERT_DESC"
[[ -n $CERT_DESC ]] && export SYNO_CREATE=1
# stdin from the terminal so the hook can ask for a 2FA code if needed
if [[ $INTERACTIVE -eq 1 ]]; then
	acme --deploy -d "$MAIN" "${ECC[@]}" --deploy-hook synology_dsm </dev/tty
else
	acme --deploy -d "$MAIN" "${ECC[@]}" --deploy-hook synology_dsm
fi
ok "Certificate deployed to DSM"

# ---------------------------------------------------------------- done
cat <<EOF

${c_ok}[OK]${c_off} acme.sh is set up. DNS and DSM settings are saved for renewals.

  Set up automatic renewal (DSM flags custom cron jobs in Security Advisor):
    Control Panel > Task Scheduler > Create > Scheduled Task > User-defined script
      General  : name "Renew certificate", user root
      Schedule : weekly, e.g. Saturday 11:00
      Script   : $ACME_HOME/acme.sh --cron --home $ACME_HOME

  If acme.sh breaks after a DSM update:
    $ACME_HOME/acme.sh --force --upgrade --nocron --home $ACME_HOME
EOF
