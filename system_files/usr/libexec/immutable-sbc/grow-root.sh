#!/bin/bash
#
# Grows the root partition (and the btrfs filesystem in it) to fill
# whatever's left on the physical disk -- the raw image this board is
# flashed from is deliberately much smaller than a real microSD/eMMC
# (disk_config/disk.toml's minsize), so there's normally something to do
# on a fresh flash.
#
# Targets /var, not / -- confirmed `/` is not a direct mount here (a
# composefs+overlay root, `btrfs filesystem resize max /` fails with
# "not a btrfs filesystem: /"). /var is the actual btrfs mount backing
# the deployment (the same partition is also visible at /sysroot and
# /etc, but /var is the unambiguous one to target).
#
# Safe on every boot: growpart's "NOCHANGE" exit isn't an error here, and
# `btrfs filesystem resize max` is a no-op once already maxed.

set -euo pipefail

# /var is a bind mount of the deployment's stateroot var directory, not a
# plain top-level mount -- findmnt reports a bind mount's SOURCE as
# "device[/subpath]" (confirmed), and lsblk rejects that bracketed string
# outright ("not a block device"). Strip it to get the plain device path.
ROOT_SOURCE=$(findmnt -no SOURCE /var | sed -E 's/\[.*\]$//')
# -r (raw): lsblk's default output right-pads numeric fields (PARTN came
# back " 4", not "4") -- the leading space broke growpart's number check.
ROOT_DISK="/dev/$(lsblk -rno PKNAME "${ROOT_SOURCE}")"
ROOT_PART_NUM=$(lsblk -rno PARTN "${ROOT_SOURCE}")

if [[ -z "${ROOT_DISK}" || "${ROOT_DISK}" == "/dev/" || -z "${ROOT_PART_NUM}" ]]; then
    echo "error: couldn't determine the disk/partition number backing /var (source: ${ROOT_SOURCE})" >&2
    exit 1
fi

# growpart also exits nonzero for real errors (e.g. "FAILED:
# partition-number must be a number", a prior bug here) -- only NOCHANGE
# is benign.
GROWPART_OUTPUT=$(growpart "${ROOT_DISK}" "${ROOT_PART_NUM}" 2>&1) || {
    if [[ "${GROWPART_OUTPUT}" == NOCHANGE:* ]]; then
        echo "note: growpart made no change to ${ROOT_DISK}${ROOT_PART_NUM} -- already at max size" >&2
    else
        echo "${GROWPART_OUTPUT}" >&2
        exit 1
    fi
}

btrfs filesystem resize max /var
