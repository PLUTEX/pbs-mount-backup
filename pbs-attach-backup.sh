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

sed -n '/^pbs:/,/^\S/{ /^\S/!p; /^pbs:/p; }' /etc/pve/storage.cfg | while read -r KEY VALUE; do
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
if [ -z "${PVE_STORAGE:-}" ]; then
    error "No PBS storage found in PVE!"
fi
read -r 'PBS_CONFIG[password]' < "/etc/pve/priv/storage/${PVE_STORAGE}.pw"

for KEY in username server datastore fingerprint password; do
    if [ -z "${PBS_CONFIG[$KEY]:-}" ]; then
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

qmp_send() {
    # Schickt die QMP-Befehle von der Standardeingabe und gibt die Antworten aus.
    {
        echo '{ "execute": "qmp_capabilities" }'
        cat
        sleep 1
    } | socat - "UNIX:${QMP}"
}

detach() {
    {
        echo '{ "execute": "device_del", "arguments": { "id": "'"$QEMU_DEVICE_NAME"'" } }'
        sleep 2
        echo '{ "execute": "blockdev-del", "arguments": { "node-name": "'"$QEMU_DRIVE_NAME"'" } }'
    } | qmp_send
}

LOCKED=false
ATTACHED=false

# Ohne diesen Trap bleibt die VM nach jedem Abbruch gesperrt zurueck, und
# solange sie gesperrt ist, laeuft fuer sie weder Sicherung noch Migration.
cleanup() {
    local RC=$?
    trap - EXIT
    if $ATTACHED; then
        if [ -S "$QMP" ]; then
            echo "Detaching snapshot from VM"
            # shellcheck disable=SC2251
            detach | { ! grep -F '"error"'; } || echo "Detaching the snapshot failed, see above."
        else
            echo "Management socket disappeared. Maybe the VM is shut down?"
            echo "Skipping detaching the snapshot from the VM."
        fi
    fi
    if $LOCKED; then
        echo "Unlocking VM"
        qm unlock "$VMID" || true
    fi
    exit "$RC"
}
trap cleanup EXIT

# Ein frueherer Lauf kann den Blockknoten hinterlassen haben: bricht das Skript
# ab oder ist die VM beim Aufraeumen schon aus, bleibt er im laufenden QEMU
# stehen, und blockdev-add scheitert mit "Duplicate nodes with node-name".
if echo '{ "execute": "query-named-block-nodes" }' | qmp_send \
        | jq -e --arg n "$QEMU_DRIVE_NAME" \
            'select(has("return")) | any(.return[]; ."node-name" == $n)' > /dev/null 2>&1; then
    echo "Removing leftover node ${QEMU_DRIVE_NAME} from an earlier run"
    detach > /dev/null
fi

# Where to attach the disk. Hanging it off the SCSI controller the VM already
# has costs no PCI slot at all and works on i440fx and q35 alike. Only if there
# is none, fall back to virtio-blk-pci - and then pin the address, because
# letting QEMU choose fails once the root bus is occupied: "slot 31 function 0
# already occupied by pci-bridge, new func virtio-blk-pci cannot be exposed to
# guest".
PCI_TOPOLOGY="$(echo '{ "execute": "query-pci" }' | qmp_send)"

SCSI_BUS=""
echo "$PCI_TOPOLOGY" | jq -r '
    select(has("return"))
    | [ .. | objects
        | select(has("qdev_id") and ((.class_info?.desc? // "") | test("SCSI")))
        | .qdev_id ]
    | map(select(. != null and . != "")) | first // empty
' | head -n 1 | read -r SCSI_BUS || true

if [ -n "$SCSI_BUS" ]; then
    DEVICE_DRIVER="scsi-hd"
    GUEST_DISK="/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_${QEMU_DEVICE_SERIAL}"
    PLACEMENT=",
        \"bus\": \"${SCSI_BUS}.0\""
    echo "Attaching to SCSI controller ${SCSI_BUS}"
else
    DEVICE_DRIVER="virtio-blk-pci"
    GUEST_DISK="$GUEST_DISK"
    PCI_BUS=""
    PCI_SLOT=""
    # Only legacy pci-bridges take a device on an arbitrary slot; a PCIe root
    # port takes exactly one, on slot 0. Count down, because PVE puts its own
    # devices on the low slots.
    echo "$PCI_TOPOLOGY" | jq -r '
        select(has("return")) | .return[].devices[]
        | select(.pci_bridge != null and ((.qdev_id // "") | startswith("pci.")))
        | . as $bridge
        | ([range(1;32)] - [$bridge.pci_bridge.devices[]?.slot]) as $free
        | select(($free | length) > 0)
        | "\($bridge.qdev_id) \($free | last)"
    ' | head -n 1 | read -r PCI_BUS PCI_SLOT || true

    if [ -n "$PCI_BUS" ]; then
        PLACEMENT=",
        \"bus\": \"${PCI_BUS}\",
        \"addr\": \"$(printf '0x%x' "$PCI_SLOT")\""
        echo "No SCSI controller, attaching to ${PCI_BUS} slot $(printf '0x%x' "$PCI_SLOT")"
    else
        PLACEMENT=""
        echo "No SCSI controller and no PCI bridge with a free slot found;"
        echo "letting QEMU choose the address. This may fail on a full root bus."
    fi
fi

echo "Locking VM"
qm set "$VMID" -lock rollback
LOCKED=true
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
        "driver": "${DEVICE_DRIVER}",
        "id": "${QEMU_DEVICE_NAME}",
        "drive": "${QEMU_DRIVE_NAME}",
        "serial": "${QEMU_DEVICE_SERIAL}"${PLACEMENT}
    }
}
EOF
ATTACHED=true
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
    if guest_exec sh -s -- mount -d "$GUEST_DISK" -t "$TARGET" -r "$RAMSIZE" < "$MOUNT_BACKUP_SCRIPT"; then
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
exit 0
