#!/bin/bash

## Add to /etc/vzdump.conf
# script:/root/vzbackup.sh
#
# At the end of every vzdump job: upload a tarball of the host config and sync
# the dump directory to an rclone remote, then send a notification.
#
# Notifications are mailed to root with sendmail. Proxmox feeds that mail into
# its notification stack as type "system-mail" and routes it to the targets
# configured under Datacenter > Notifications.

############ /START CONFIG
remotePath=GD:NData/Backup/nmt
dumpDir="/var/lib/vz/dump"
notify="always"                # always | failure | never
#backupPath="SP:Data/Backup/Proxmox/$(date +%Y-%m-%d)/$(date +%H-%M-%S)"
############ /END CONFIG

COMMAND=${1}
RCLONE=(rclone --config /root/.config/rclone/rclone.conf -v --stats=60s --fast-list --checksum)
MAIL_TO="root"
LOG_TAG="vzbackup"

send_mail() {
    local subject="$1" body="$2" host
    host=$(hostname -s)
    command -v sendmail >/dev/null 2>&1 || { echo "sendmail not found, notification not sent"; return 0; }
    printf 'To: %s\nFrom: %s@%s\nSubject: [Proxmox][%s] %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
        "$MAIL_TO" "$LOG_TAG" "$host" "$host" "$subject" "$body" | sendmail -t
}

# run_step NAME CMD...   runs CMD, shows its output in the task log, records the result
STEP_NAMES=(); STEP_RESULTS=(); STEP_TIMES=(); FAILED=0
run_step() {
    local name=$1 start rc out
    shift
    start=$(date +%s)
    out="$_tdir/step${#STEP_NAMES[@]}.log"
    echo "$name"
    "$@" 2>&1 | tee "$out"
    rc=${PIPESTATUS[0]}
    STEP_NAMES+=("$name")
    STEP_TIMES+=("$(( $(date +%s) - start ))s")
    if [[ $rc -eq 0 ]]; then
        STEP_RESULTS+=("OK")
    else
        STEP_RESULTS+=("FAILED (exit $rc)")
        FAILED=1
    fi
    return 0
}

# Last rclone stats block of a step: "Transferred: ...", "Checks: ...", "Deleted: ..."
step_stats() {
    grep -E '^(Transferred|Checks|Deleted|Errors|Elapsed time):' "$_tdir/step$1.log" 2>/dev/null \
        | tail -n 6 | sed 's/^/      /'
}

if [[ ${COMMAND} == 'job-end' ]]; then
    function clean_up {
        echo "Cleaning up"
        rm -rf "$_tdir"
    }

    trap clean_up EXIT

    _start=$(date +%s)
    echo "Backing up main PVE configs"
    _tdir=${TMP_DIR:-/var/tmp}
    _tdir=$(mktemp -d "$_tdir"/proxmox-XXXXXXXX)
    _now=$(date +%Y-%m-%d.%H.%M.%S)
    _HOSTNAME=$(hostname -f)
    _configBackupFile="$_tdir/${_HOSTNAME}_backup_${_now}.tar.gz"

    # tar exits 1 when a file changed while it was read (logs, pmxcfs): still a usable archive
    tar_config() {
        tar -czf "$_configBackupFile" /etc /var/lib/pve-cluster /root
        local rc=$?
        [[ $rc -eq 1 ]] && { echo "tar: some files changed while being read, archive kept"; return 0; }
        return $rc
    }
    run_step "Creating config backup file" tar_config
    _configSize=$(du -h "$_configBackupFile" 2>/dev/null | cut -f1)

    run_step "Backing up config to remote storage" \
        "${RCLONE[@]}" move "$_configBackupFile" "$remotePath/config"

    run_step "Backing up dump to remote storage" \
        "${RCLONE[@]}" sync "$dumpDir" "$remotePath/dump"

    # ---------------------------------------------------------------- notification
    _elapsed=$(( $(date +%s) - _start ))
    if [[ $FAILED -eq 1 ]]; then
        logger -t "$LOG_TAG" -- "offsite backup to $remotePath FAILED"
    else
        logger -t "$LOG_TAG" -- "offsite backup to $remotePath OK"
    fi

    if [[ $notify == always || ( $notify == failure && $FAILED -eq 1 ) ]]; then
        body="Offsite backup after vzdump job on $_HOSTNAME
Remote   : $remotePath
Dump dir : $dumpDir
Config   : $(basename "$_configBackupFile") (${_configSize:-?})
Duration : $((_elapsed / 60))m $((_elapsed % 60))s
"
        for i in "${!STEP_NAMES[@]}"; do
            body+="
[${STEP_RESULTS[i]}] ${STEP_NAMES[i]} (${STEP_TIMES[i]})"
            _stats=$(step_stats "$i")
            [[ -n $_stats ]] && body+="
$_stats"
            if [[ ${STEP_RESULTS[i]} != OK ]]; then
                body+="
    Last output:
$(tail -n 20 "$_tdir/step$i.log" | sed 's/^/      /')"
            fi
        done
        _about=$("${RCLONE[@]}" about "${remotePath%%:*}:" 2>/dev/null) || _about=""
        body+="

Remote disk usage:
$(if [[ -n $_about ]]; then sed 's/^/  /' <<<"$_about"; else echo "  (not available for this remote)"; fi)"

        if [[ $FAILED -eq 1 ]]; then
            send_mail "Offsite backup FAILED" "$body"
        else
            send_mail "Offsite backup OK" "$body"
        fi
        echo "Notification sent ($notify)"
    fi

    clean_up
    trap - EXIT
    [[ $FAILED -eq 0 ]]
fi
