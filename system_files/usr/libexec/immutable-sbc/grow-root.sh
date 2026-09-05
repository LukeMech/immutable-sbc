#!/bin/bash
#
# Grows the root partition (and then the btrfs filesystem inside it) to
# fill whatever's left on the physical disk. The raw image this board
# is flashed from is deliberately much smaller than any real microSD/
# eMMC (see disk_config/disk.toml's minsize), so there's normally
# something to do here on a fresh flash.
#
# Targets /var, not / -- confirmed on real hardware that `/` is not a
# direct mount of the physical filesystem here (it's a composefs+
# overlay root, `btrfs filesystem resize max /` fails outright with
# "not a btrfs filesystem: /"). /var is the actual btrfs mount backing
# the whole deployment (per `lsblk`, the same partition is also visible
# at /sysroot and /etc, but /var is the plain, unambiguous mountpoint to
# target).
#
# Safe to run on every boot: growpart's own "NOCHANGE" exit (already at
# max size) isn't treated as an error here, and `btrfs filesystem
# resize max` is a no-op once the filesystem already fills its
# partition.

set -euo pipefail

ROOT_SOURCE=$(findmnt -no SOURCE /var)
ROOT_DISK="/dev/$(lsblk -no PKNAME "${ROOT_SOURCE}")"
ROOT_PART_NUM=$(lsblk -no PARTN "${ROOT_SOURCE}")

if [[ -z "${ROOT_DISK}" || "${ROOT_DISK}" == "/dev/" || -z "${ROOT_PART_NUM}" ]]; then
    echo "error: couldn't determine the disk/partition number backing /var (source: ${ROOT_SOURCE})" >&2
    exit 1
fi

if ! growpart "${ROOT_DISK}" "${ROOT_PART_NUM}"; then
    echo "note: growpart made no change to ${ROOT_DISK}${ROOT_PART_NUM} -- already at max size, or nothing to grow into" >&2
fi

btrfs filesystem resize max /var
