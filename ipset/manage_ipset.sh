#!/bin/bash
# Save / restore the blacklist ipset so it survives reboots.
# UFW refuses to load rules that reference a missing set, so "restore" runs
# before ufw.service at boot (ipset-restore.service).
#
#   manage_ipset.sh save      write the set to $SAVE_FILE
#   manage_ipset.sh restore   load $SAVE_FILE, or create an empty set
#   manage_ipset.sh status    number of entries, last update, next update

IPSET_NAME="blacklist"
SAVE_FILE="/etc/ipset/blacklist.restore"
[ -f /etc/default/ipset-blacklist ] && . /etc/default/ipset-blacklist

create_set() {
    ipset create -exist "$IPSET_NAME" hash:ip hashsize 65536 maxelem 1048576
}

count() { ipset list -t "$IPSET_NAME" 2>/dev/null | sed -n 's/^Number of entries: //p'; }

case "$1" in
    save)
        if ! ipset list -n "$IPSET_NAME" >/dev/null 2>&1; then
            echo "ipset '$IPSET_NAME' does not exist, nothing to save"
            exit 0
        fi
        mkdir -p "$(dirname "$SAVE_FILE")"
        ipset save "$IPSET_NAME" > "$SAVE_FILE.tmp" && mv "$SAVE_FILE.tmp" "$SAVE_FILE"
        echo "Saved ipset '$IPSET_NAME' ($(count) entries) to $SAVE_FILE"
        ;;
    restore)
        if [ -s "$SAVE_FILE" ]; then
            # -exist: the set may already exist (service restarted), entries are merged
            if ipset restore -exist < "$SAVE_FILE"; then
                echo "Restored ipset '$IPSET_NAME' ($(count) entries) from $SAVE_FILE"
                exit 0
            fi
            echo "Restoring $SAVE_FILE failed, creating an empty set"
        else
            echo "No saved state in $SAVE_FILE, creating an empty set"
        fi
        create_set
        ;;
    status)
        if ipset list -n "$IPSET_NAME" >/dev/null 2>&1; then
            echo "ipset '$IPSET_NAME': $(count) entries"
        else
            echo "ipset '$IPSET_NAME' does not exist"
        fi
        [ -f "$SAVE_FILE" ] && echo "Saved state : $SAVE_FILE ($(date -r "$SAVE_FILE" '+%Y-%m-%d %H:%M'))"
        systemctl list-timers ipset-update.timer --no-pager 2>/dev/null | sed -n '1,2p'
        ;;
    *)
        echo "Usage: $0 {save|restore|status}"
        exit 1
        ;;
esac
