#!/bin/bash

set -eu
set -o pipefail
shopt -s lastpipe

declare -A PBS_CONFIG=()

DEFAULT_TARGET="/mnt/backup"
DEFAULT_RAMSIZE="128"
QEMU_DRIVE_NAME="mounted_backup"
QEMU_DEVICE_NAME="$QEMU_DRIVE_NAME"
QEMU_DEVICE_SERIAL="$QEMU_DRIVE_NAME"
MOUNT_BACKUP_SCRIPT="$(dirname "$(realpath "$0")")/pbs-mount-backup.sh"

debug() {
    if [ -n "${DEBUG:-}" ]; then
        echo "$*"
    fi
}

error() {
    echo "ERROR: $*" >&2
    exit 1
}

guest_exec() {
    local QGA_EXEC_OUT
    QGA_EXEC_OUT="$(mktemp)"
    if ! qm guest exec -pass-stdin 1 "$VMID" -- "$@" > "$QGA_EXEC_OUT"; then
        return 255
    elif [ "$(jq .exited < "$QGA_EXEC_OUT")" = "1" ]; then
        jq -r '.["out-data"] // ""' < "$QGA_EXEC_OUT"
        jq -r '.["err-data"] // ""' < "$QGA_EXEC_OUT" >&2

        return "$(jq .exitcode < "$QGA_EXEC_OUT")"
    elif [ -n "$(jq .pid < "$QGA_EXEC_OUT")" ]; then
        return 254
    fi
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
    qm list | awk '$3 == "running" || NR == 1' | column -t
    echo
    read -r -p "Enter VMID to restore: " VMID
    echo
fi

if [ -z "$SNAPSHOT" ]; then
    pvesh get "/nodes/localhost/storage/${PVE_STORAGE}/content" --content backup --vmid "$VMID" --output-format=json | jq -r ".[].volid | ltrimstr(\"${PVE_STORAGE}:backup/\")" | readarray -t -O 1 SNAPSHOTS
    case "${#SNAPSHOTS[@]}" in
        0)
            echo "Did not find any snapshots for VM ${VMID}!"
            exit 1
            ;;
        1)
            SNAPSHOT="${SNAPSHOTS[1]}"
            ;;
        *)
            for i in "${!SNAPSHOTS[@]}"; do
                echo "${i}) ${SNAPSHOTS[i]}"
            done
            read -r -p "Choose snapshot: " SNAPSHOT_ID
            echo
            SNAPSHOT="${SNAPSHOTS[$SNAPSHOT_ID]}"
            ;;
    esac
fi

if [ -z "$DRIVE" ]; then
    pvesh get "/nodes/localhost/storage/${PVE_STORAGE}/file-restore/list" --volume "$SNAPSHOT" --filepath / --output-format=json | jq -r '.[].text' | readarray -t -O 1 DRIVES
    case "${#DRIVES[@]}" in
        0)
            echo "The snapshot ${SNAPSHOT} of VM ${VMID} does not contain any drives!"
            exit 1
            ;;
        1)
            DRIVE="${DRIVES[1]}"
            ;;
        *)
            for i in "${!DRIVES[@]}"; do
                echo "${i}) ${DRIVES[i]}"
            done
            read -r -p "Choose drive: " DRIVE_ID
            echo
            DRIVE="${DRIVES[$DRIVE_ID]}"
            ;;
    esac
fi
QMP="/run/qemu-server/${VMID}.qmp"

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
        "node-name": "${QEMU_DRIVE_NAME}",
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
        "id": "${QEMU_DEVICE_NAME}",
        "drive": "${QEMU_DRIVE_NAME}",
        "serial": "${QEMU_DEVICE_SERIAL}"
    }
}
EOF
MOUNTED=false
TRIED_TO_MOUNT=false
if ! [ -f "$MOUNT_BACKUP_SCRIPT" ]; then
    echo "Could not find mount script under ${MOUNT_BACKUP_SCRIPT}"
elif qm guest cmd "$VMID" ping; then
    echo
    read -r -p "Where should the backup be mounted to? [${DEFAULT_TARGET}] " TARGET
    echo
    : "${TARGET:=$DEFAULT_TARGET}"

    read -r -p "How much RAM should be allocated to buffer writes to mounted backup? [${DEFAULT_RAMSIZE}] " RAMSIZE
    echo
    : "${RAMSIZE:=$DEFAULT_RAMSIZE}"

    echo "Mounting backup in VM..."
    sleep 2

    QGA_EXEC_OUT="$(mktemp)"
    TRIED_TO_MOUNT=true
    if guest_exec sh -s -- mount -d "/dev/disk/by-id/virtio-${QEMU_DEVICE_SERIAL}" -t "$TARGET" -r "$RAMSIZE" < "$MOUNT_BACKUP_SCRIPT"; then
        MOUNTED=true
    else
        echo "Failed to mount backup in VM (exitcode $?). See above output for details."
    fi
fi
read -r -s -p "Snapshot attached. Press return when done..."
echo
if $TRIED_TO_MOUNT && ! $MOUNTED; then
    read -r -p "Do you want to try unmounting, even though mounting didn't succeed? [n] " TRY_UMOUNT
    case "$TRY_UMOUNT" in
        [yY]*)
            MOUNTED=true
            ;;
    esac
fi
if $MOUNTED; then
    if qm guest cmd "$VMID" ping; then
        echo "Unmounting backup in VM..."
        QGA_EXEC_OUT="$(mktemp)"
        if ! guest_exec sh -s -- umount < "$MOUNT_BACKUP_SCRIPT"; then
            echo "Unmounting backup in VM failed!"
            read -r -s -p "Press enter to continue detaching without unmounting the snapshot..."
            echo
        fi
    else
        echo "QEMU Guest Agent not responding, skipping unmount of backup in VM"
    fi
fi
if [ -S "$QMP" ]; then
    echo "Detaching snapshot from VM"
    # shellcheck disable=SC2251
    {
        echo '{ "execute": "qmp_capabilities" }'
        echo '{ "execute": "device_del", "arguments": { "id": "'"$QEMU_DEVICE_NAME"'" } }'
        sleep 2
        echo '{ "execute": "blockdev-del", "arguments": { "node-name": "'"$QEMU_DRIVE_NAME"'" } }'
    } | socat - "UNIX:${QMP}" | { ! grep -F '"error"'; }
else
    echo "Management socket disappeared. Maybe the VM is shut down?"
    echo "Skipping detaching the snapshot from the VM."
fi
echo "Unlocking VM"
qm unlock "$VMID"

exit 0
