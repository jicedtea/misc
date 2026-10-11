#!/bin/bash
# Refresh the blacklist ipset from stamparm/ipsum.
#
# ipsum lists "IP<TAB>score", score = number of public blacklists the IP is on.
# Only IPs with score >= MIN_SCORE are kept.
#
# The new list is built in a temporary set and swapped in atomically, so the
# blacklist is never empty while updating, and a failed download keeps the
# current list. Runs daily from ipset-update.timer; output goes to the journal
# (journalctl -u ipset-update).

IPSET_NAME="blacklist"
MIN_SCORE=3
SOURCE_URL="https://raw.githubusercontent.com/stamparm/ipsum/master/ipsum.txt"
MIN_ENTRIES=100      # fewer IPs than this = broken download, keep the current list
[ -f /etc/default/ipset-blacklist ] && . /etc/default/ipset-blacklist

TMP_SET="${IPSET_NAME}_new"
TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"; ipset destroy "$TMP_SET" 2>/dev/null' EXIT

echo "Updating ipset '$IPSET_NAME' from $SOURCE_URL (score >= $MIN_SCORE)"

if ! curl -fsS --compressed --retry 3 --max-time 120 "$SOURCE_URL" -o "$TMP_FILE"; then
    echo "Download failed, keeping the current list"
    exit 1
fi

# "add <set> <ip>" lines for ipset restore; skips comments and low scores
awk -v set="$TMP_SET" -v min="$MIN_SCORE" \
    '!/^#/ && NF >= 2 && $2 >= min && $1 ~ /^[0-9.]+$/ { print "add " set " " $1 }' \
    "$TMP_FILE" > "$TMP_FILE.add"
mv "$TMP_FILE.add" "$TMP_FILE"
NEW=$(wc -l < "$TMP_FILE")

if [ "$NEW" -lt "$MIN_ENTRIES" ]; then
    echo "Only $NEW IPs in the download (expected >= $MIN_ENTRIES), keeping the current list"
    exit 1
fi

ipset create -exist "$IPSET_NAME" hash:ip hashsize 65536 maxelem 1048576
ipset create -exist "$TMP_SET" hash:ip hashsize 65536 maxelem 1048576
ipset flush "$TMP_SET"
if ! ipset restore -exist < "$TMP_FILE"; then
    echo "Loading the new list failed, keeping the current list"
    exit 1
fi

OLD=$(ipset list -t "$IPSET_NAME" | sed -n 's/^Number of entries: //p')
ipset swap "$TMP_SET" "$IPSET_NAME"
echo "ipset '$IPSET_NAME' updated: $OLD -> $NEW IPs"

/usr/local/bin/manage_ipset.sh save
