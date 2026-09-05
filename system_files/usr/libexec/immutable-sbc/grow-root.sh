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

# /var is a bind mount of the deployment's own stateroot var directory
# (e.g. /sysroot/ostree/deploy/default/var -> /var), not a plain
# top-level mount -- findmnt reports a bind mount's SOURCE as
# "device[/subpath]" (confirmed: "/dev/mmcblk1p4[/root/ostree/deploy/
# default/var]"), and lsblk rejects that whole bracketed string outright
# ("not a block device"). Strip the bracketed subpath to get back the
# plain device path lsblk expects.
ROOT_SOURCE=$(findmnt -no SOURCE /var | sed -E 's/\[.*\]$//')
# -r (raw): lsblk's default column output right-pads numeric fields
# (PARTN came back as " 4", not "4") -- that leading space made it
# straight into growpart's argument and broke its own number check.
ROOT_DISK="/dev/$(lsblk -rno PKNAME "${ROOT_SOURCE}")"
ROOT_PART_NUM=$(lsblk -rno PARTN "${ROOT_SOURCE}")

if [[ -z "${ROOT_DISK}" || "${ROOT_DISK}" == "/dev/" || -z "${ROOT_PART_NUM}" ]]; then
    echo "error: couldn't determine the disk/partition number backing /var (source: ${ROOT_SOURCE})" >&2
    exit 1
fi

# growpart also exits nonzero for its own real errors (e.g. "FAILED:
# partition-number must be a number", which a prior bug here triggered
# on every boot without anyone noticing) -- only NOCHANGE is benign.
GROWPART_OUTPUT=$(growpart "${ROOT_DISK}" "${ROOT_PART_NUM}" 2>&1) || {
    if [[ "${GROWPART_OUTPUT}" == NOCHANGE:* ]]; then
        echo "note: growpart made no change to ${ROOT_DISK}${ROOT_PART_NUM} -- already at max size" >&2
    else
        echo "${GROWPART_OUTPUT}" >&2
        exit 1
    fi
}

btrfs filesystem resize max /var
