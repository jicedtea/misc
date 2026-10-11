#!/bin/bash

## Add to /etc/vzdump.conf
# script:/root/vzbackup.sh

############ /START CONFIG
remotePath=GD:NData/Backup/nmt
dumpDir="/var/lib/vz/dump"
#backupPath="SP:Data/Backup/Proxmox/$(date +%Y-%m-%d)/$(date +%H-%M-%S)"
############ /END CONFIG

COMMAND=${1}

if [[ ${COMMAND} == 'job-end' ]]; then
    function clean_up {
        echo "Cleaning up"
        rm -rf $_tdir
    }

    trap clean_up EXIT

    echo "Backing up main PVE configs"
    _tdir=${TMP_DIR:-/var/tmp}
    _tdir=$(mktemp -d $_tdir/proxmox-XXXXXXXX)
    _now=$(date +%Y-%m-%d.%H.%M.%S)
    _HOSTNAME=$(hostname -f)
    _configBackupFile="$_tdir/"$_HOSTNAME"_backup_"$_now".tar.gz"

    echo "Creating config backup files"
    tar -cf "$_configBackupFile" /etc /var/lib/pve-cluster /root

    echo "Backing up config to remote storage"
    rclone --config /root/.config/rclone/rclone.conf -v --stats=60s --fast-list --checksum move "$_configBackupFile" "$remotePath/config"

    echo "Backing up dump to remote storage"
    rclone --config /root/.config/rclone/rclone.conf -v --stats=60s --fast-list --checksum sync "$dumpDir" "$remotePath/dump"

    clean_up
fi