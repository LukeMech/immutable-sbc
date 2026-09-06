#!/bin/bash
#
# Grows root (and its btrfs fs) to fill the disk -- deliberately smaller than a real
# microSD/eMMC (disk.toml's minsize), so a fresh flash has something to grow.
#
# Targets /var, not / -- confirmed / isn't a direct mount here (composefs+overlay root,
# resize fails "not a btrfs filesystem"); /var is the real mount (also /sysroot, /etc).
#
# Safe on every boot: growpart's "NOCHANGE" exit isn't an error here, and
# `btrfs filesystem resize max` is a no-op once already maxed.

set -euo pipefail

# /var is a bind mount -- findmnt reports its SOURCE as "device[/subpath]" (confirmed),
# and lsblk rejects that ("not a block device"); strip it to get the plain path.
ROOT_SOURCE=$(findmnt -no SOURCE /var | sed -E 's/\[.*\]$//')
# -r (raw): lsblk's default output right-pads numeric fields (PARTN came
# back " 4", not "4") -- the leading space broke growpart's number check.
ROOT_DISK="/dev/$(lsblk -rno PKNAME "${ROOT_SOURCE}")"
ROOT_PART_NUM=$(lsblk -rno PARTN "${ROOT_SOURCE}")

if [[ -z "${ROOT_DISK}" || "${ROOT_DISK}" == "/dev/" || -z "${ROOT_PART_NUM}" ]]; then
    echo "error: couldn't determine the disk/partition number backing /var (source: ${ROOT_SOURCE})" >&2
    exit 1
fi

# growpart also exits nonzero for real errors (e.g. a prior "partition-number must be
# a number" bug here) -- only a NOCHANGE exit is benign.
GROWPART_OUTPUT=$(growpart "${ROOT_DISK}" "${ROOT_PART_NUM}" 2>&1) || {
    if [[ "${GROWPART_OUTPUT}" == NOCHANGE:* ]]; then
        echo "note: growpart made no change to ${ROOT_DISK}${ROOT_PART_NUM} -- already at max size" >&2
    else
        echo "${GROWPART_OUTPUT}" >&2
        exit 1
    fi
}

btrfs filesystem resize max /var
