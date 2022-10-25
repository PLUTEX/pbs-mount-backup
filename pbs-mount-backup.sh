#!/bin/sh

set -eu

DEFAULT_DISK="/dev/disk/by-id/virtio-mounted_backup"
DEFAULT_RAMSIZE="128"
DEFAULT_DMNAME="mounted_backup"
DEFAULT_TARGET="/mnt/backup"

usage() {
    cat <<EOF
Usage:
  $(basename "$0") mount [-d <disk>] [-r <RAM size>] [-n <DM name>] [-t <dir>]
  $(basename "$0") umount [-n <DM name>]

  <disk>      The block device with the backup
              Default: ${DEFAULT_DISK}
  <RAM size>  The size of the RAM disk to buffer writes, in MB
              Default: ${DEFAULT_RAMSIZE}
  <DM name>   The name of the device mapper device to create
              Default: ${DEFAULT_DMNAME}
  <dir>       Directory where to mount the backup
              Default: ${DEFAULT_TARGET}
EOF
}

if [ "$#" = 0 ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    usage
    exit 1
fi

MODE="$1"
shift 1
DISK="$DEFAULT_DISK"
RAMSIZE="$DEFAULT_RAMSIZE"
DMNAME="$DEFAULT_DMNAME"
TARGET="$DEFAULT_TARGET"

while getopts d:r:n:t:h OPT; do
    case "$OPT" in
        d) DISK="$OPTARG";;
        r) RAMSIZE="$OPTARG";;
        n) DMNAME="$OPTARG";;
        t) TARGET="$OPTARG";;
        h) usage; exit 0;;
        \?) usage; exit 1;;
    esac
done
shift $((OPTIND - 1))
DMPATH="/dev/mapper/${DMNAME}"

if [ "$MODE" = mount ]; then
    if ! [ -b "$DISK" ]; then
        echo "Backup disk not found: ${DISK}" >&2
        echo "Did you mount it in PVE?" >&2
        exit 1
    fi
    if [ -b "$DMPATH" ]; then
        echo "DM name ${DMNAME} already taken. Did you forget to umount first?" >&2
        exit 1
    fi

    modprobe brd rd_size=$((RAMSIZE*1024))
    echo "0 $(blockdev --getsz "$DISK") snapshot ${DISK} /dev/ram1 P 8" | dmsetup create "$DMNAME"
    partprobe "$DMPATH"

    grep '^/' /proc/mounts | sort -k1 -r | while read -r ORIG_DEV MNT _; do
        UUID="$(blkid -o value -s UUID "$ORIG_DEV")"
        if [ -z "$UUID" ]; then
            continue
        fi

        BACKUP_DEV="$(blkid -U "$UUID")"
        case "$BACKUP_DEV" in
            "$DMPATH"*)
                BACKUP_MNT="${TARGET}/${MNT#/}"
                mkdir -p "$TARGET"
                if mount "$BACKUP_DEV" "$BACKUP_MNT"; then
                    echo "Mounted ${BACKUP_DEV} (assumed backup of ${ORIG_DEV} mounted on ${MNT}) to ${BACKUP_MNT}."
                else
                    echo "Failed to mount ${BACKUP_DEV} (assumed backup of ${ORIG_DEV} mounted on ${MNT}) to ${BACKUP_MNT}."
                fi
                ;;
            *)
                echo "Backup of ${ORIG_DEV} (mounted on ${MNT}) does not seem to be part of the backup."
                ;;
        esac
    done

    if [ -z "${QEMU_AGENT:-}" ]; then
        echo ""
        echo "After usage, please execute '$(basename "$0") umount' (inside VM)"
    fi
elif [ "$MODE" = "umount" ]; then
    if ! [ -b "$DMPATH" ]; then
        echo "DM device not found. Did you mount a backup?" >&2
        exit 1
    fi
    awk "\$2 ~ \"^${TARGET%/}\" { print \$2 }" /proc/mounts | sort -r | xargs umount
    dmsetup ls | grep "^${DMNAME}" | cut -f1 | xargs dmsetup remove
    rmmod brd
fi
