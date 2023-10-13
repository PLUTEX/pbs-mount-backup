# Attach Proxmox Backup Server backups

These scripts allow to attach backups from a [Proxmox Backup Server] to a
running VM as additional disks (`pbs-attach-backup.sh`, to be run on the
[Proxmox Virtual Environment] hypervisor) and mount them inside the VM with a
RAM-backed write buffer (`pbs-mount-backup.sh`).

If the QEMU Guest Agent is installed (and enabled), the mounting (and
unmounting) is triggered automatically from the hypervisor. For that to work,
the `pbs-mount-backup.sh` has to be put in the same directory as
`pbs-attach-backup.sh`.

[Proxmox Backup Server]: https://pbs.proxmox.com/
[Proxmox Virtual Environment]: https://pve.proxmox.com/

## Purpose

Proxmox Backup Server is great for backups of VMs in Proxmox Virtual
Environment, and great for disaster recovery of whole VMs, too! But while it has
a UI for "File Restore", restoring several – possibly huge – files requires one
to download them from the hypervisor WebUI to the client and then copy them to
the server.

With this method of attaching the backup as an additional disk, we can eliminate
the administrator's client computer from the restore operation. Even better, we
can provide users of the VM with the full contents of a backup and let them
choose what to restore, without copying a single bit that's not needed!

## Dependencies

On the hypervisor:

```
apt install jq socat
```


## Usage

The script should determine most variables (like PBS storage ID and credentials)
automatically, and ask for the rest:

```
# pbs-attach-backup.sh
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID
[...]
       174 dev.example.org      running    1024              10.00 49455
[...]

Enter VMID to restore: 174

1) vm/174/2022-10-11T01:08:51Z
2) vm/174/2022-10-12T01:08:48Z
3) vm/174/2022-10-13T01:08:26Z
4) vm/174/2022-10-14T01:08:28Z
5) vm/174/2022-10-15T01:08:45Z
6) vm/174/2022-10-16T01:08:33Z
7) vm/174/2022-10-17T01:08:37Z
8) vm/174/2022-10-18T01:08:35Z
9) vm/174/2022-10-19T01:08:50Z
10) vm/174/2022-10-20T01:08:58Z
11) vm/174/2022-10-21T01:08:38Z
12) vm/174/2022-10-22T01:08:25Z
13) vm/174/2022-10-23T01:08:12Z
14) vm/174/2022-10-24T01:08:19Z
Choose snapshot: 14

Locking VM
update VM 174: -lock rollback
Attaching drive drive-scsi0.img.fidx from snapshot vm/174/2022-10-24T01:08:19Z
to VM 174

Where should the backup be mounted to? [/mnt/backup]

How much RAM should be allocated to buffer writes to mounted backup? [128]

Mounting backup in VM...
Mounted /dev/mapper/mounted_backup6 (assumed backup of /dev/sda6 mounted on /) to /mnt/backup/.
Mounted /dev/mapper/mounted_backup5 (assumed backup of /dev/sda5 mounted on /var/tmp) to /mnt/backup/var/tmp.
Mounted /dev/mapper/mounted_backup1 (assumed backup of /dev/sda1 mounted on /boot) to /mnt/backup/boot.
Snapshot attached. Press return when done...
Unmounting backup in VM...
Detaching snapshot from VM
Unlocking VM
#
```

You can pass only the VM ID or that and the snapshot name on the command line,
too:

```
# pbs-attach-backup.sh 174 vm/174/2022-10-24T01:08:19Z
Locking VM
[...]
```

## Locking

As you can see, the VM is locked for the duration of the mount. This is to
prevent migrations of the VM, since PVE doesn't know about the additional disk
and hence it wouldn't be available on the new hypervisor.

As a side effect, it also prevents new backups from being created! So limit the
duration of the attachment to the duration it's actually needed.
