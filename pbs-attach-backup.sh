#!/bin/bash

set -eu
set -o pipefail
shopt -s lastpipe

declare -A PBS_CONFIG=()

debug() {
    if [ -n "${DEBUG:-}" ]; then
        echo "$*"
    fi
}

error() {
    echo "ERROR: $*" >&2
    exit 1
}

sed -n '/^pbs:/,/^\S/ p' /etc/pve/storage.cfg | while read -r KEY VALUE; do
    case "$KEY" in
        "")
            ;;
        pbs:)
            if [ -n "${PVE_STORAGE:-}" ]; then
                error "More than one PBS storage configured in PVE!"
            fi
            PVE_STORAGE="$VALUE"
            ;;
        *)
            PBS_CONFIG[$KEY]="$VALUE"
            ;;
    esac
done
read -r 'PBS_CONFIG[password]' < "/etc/pve/priv/storage/${PVE_STORAGE}.pw"

if [ -z "$PVE_STORAGE" ]; then
    error "No PBS storage found in PVE!"
fi

for KEY in username server datastore fingerprint password; do
    if [ -z "${PBS_CONFIG[$KEY]}" ]; then
        error "PBS option ${KEY} not found in storage config!"
    fi
done

declare -i VMID="${1:-0}"
SNAPSHOT="${2:-}"
DRIVE="${3:-}"

if [ "$VMID" = 0 ]; then
    qm list
    echo
    read -r -p "Enter VMID to restore: " VMID
    echo
fi

if [ -z "$SNAPSHOT" ]; then
    pvesh get "/nodes/localhost/storage/${PVE_STORAGE}/content" --content backup --vmid "$VMID" --output-format=json | jq -r ".[].volid | ltrimstr(\"${PVE_STORAGE}:backup/\")" | readarray -t -O 1 SNAPSHOTS
    if [ "${#SNAPSHOTS[@]}" = 1 ]; then
        SNAPSHOT="${SNAPSHOTS[1]}"
    else
        for i in "${!SNAPSHOTS[@]}"; do
            echo "${i}) ${SNAPSHOTS[i]}"
        done
        read -r -p "Choose snapshot: " SNAPSHOT_ID
        echo
        SNAPSHOT="${SNAPSHOTS[$SNAPSHOT_ID]}"
    fi
fi

if [ -z "$DRIVE" ]; then
    pvesh get "/nodes/localhost/storage/${PVE_STORAGE}/file-restore/list" --volume "$SNAPSHOT" --filepath / --output-format=json | jq -r '.[].text' | readarray -t -O 1 DRIVES
    if [ "${#DRIVES[@]}" = 1 ]; then
        DRIVE="${DRIVES[1]}"
    else
        for i in "${!DRIVES[@]}"; do
            echo "${i}) ${DRIVES[i]}"
        done
        read -r -p "Choose drive: " DRIVE_ID
        echo
        DRIVE="${DRIVES[$DRIVE_ID]}"
    fi
fi
QMP="/run/qemu-server/${VMID}.qmp"
QGA="/run/qemu-server/${VMID}.qga"

echo "Locking VM"
qm set "$VMID" -lock rollback
echo "Attaching drive ${DRIVE} from snapshot ${SNAPSHOT} to VM ${VMID}"

# shellcheck disable=SC2251
socat - "UNIX:${QMP}" <<EOF | { ! grep -F '"error"'; }
{ "execute": "qmp_capabilities" }
{
    "execute": "blockdev-add",
    "arguments": {
        "driver": "pbs",
        "node-name": "mounted_backup",
        "read-only": true,
        "repository": "${PBS_CONFIG[username]}@${PBS_CONFIG[server]}:${PBS_CONFIG[datastore]}",
        "namespace": "${PBS_CONFIG[namespace]:-}",
        "snapshot": "${SNAPSHOT}",
        "archive": "${DRIVE}",
        "password": "${PBS_CONFIG[password]}",
        "fingerprint": "${PBS_CONFIG[fingerprint]}" 
    }
}
{
    "execute": "device_add",
    "arguments": {
        "driver": "virtio-blk-pci",
        "id": "mounted_backup",
        "drive": "mounted_backup",
        "serial": "mounted_backup"
    }
}
EOF
if [ -S "$QGA" ]; then
    echo "Mounting backup in VM..."
    sleep 2
    PROC_ID="$(
        {
            echo '{ "execute": "guest-exec", "arguments": {"path": "/usr/local/sbin/pbs-mount-backup.sh", "arg": ["mount"], "env": ["QEMU_AGENT=1"], "capture-output": true} }'
            sleep 0.5
        } | socat - "UNIX:${QGA}" | jq 'select(.return).return.pid')"
    sleep 1
    if [ -n "$PROC_ID" ]; then
        {
            echo '{ "execute": "guest-exec-status", "arguments": {"pid": '"$PROC_ID"'}}'
            sleep 0.5
        } | socat - "UNIX:${QGA}" | jq -r 'select(.return).return["out-data"]' | base64 -d || true
    fi
fi
read -r -s -p "Snapshot attached. Press return when done..."
echo
if [ -S "$QGA" ] && [ -n "$PROC_ID" ]; then
    echo "Unmounting backup in VM..."
    PROC_ID="$(
        {
            echo '{ "execute": "guest-exec", "arguments": {"path": "/usr/local/sbin/pbs-mount-backup.sh", "arg": ["umount"], "capture-output": true} }'
            sleep 0.5
        } | socat - "UNIX:${QGA}" | jq .pid
    )"
    sleep 2
    if [ -n "$PROC_ID" ]; then
        {
            echo '{ "execute": "guest-exec-status", "arguments": {"pid": '"$PROC_ID"'}}'
            sleep 0.5
        } | socat - "UNIX:${QGA}" > /dev/null
    fi
fi
echo "Detaching snapshot from VM"
# shellcheck disable=SC2251
{
    echo '{ "execute": "qmp_capabilities" }'
    echo '{ "execute": "device_del", "arguments": { "id": "mounted_backup" } }'
    sleep 2
    echo '{ "execute": "blockdev-del", "arguments": { "node-name": "mounted_backup" } }'
} | socat - "UNIX:/var/run/qemu-server/${VMID}.qmp" | { ! grep -F '"error"'; }
echo "Unlocking VM"
qm unlock "$VMID"

exit 0
