#!/bin/bash
#
# Composes the final ROCK 5C microSD/eMMC image from two independently
# built inputs: the EDK2 UEFI firmware image and a bootc-image-builder
# "raw" output (ESP + boot + root). No onboard SPI-NOR on this board, so
# both have to live on the same medium.
#
# The firmware is not a normal ESP -- the RK3588 boot ROM reads it from a
# fixed physical byte offset, never via a partition table entry (confirmed
# by upstream's own in-place update convention: `dd skip=64 seek=64`,
# never touching the target disk's GPT). So its shipped GPT is pure
# bookkeeping, safe to discard.
#
# Strategy: dd the firmware to offset 0 and the OS image's partition data
# (not its GPT) to a 16 MiB aligned offset after it, then build ONE fresh
# GPT for the combined disk in a single sgdisk invocation. An earlier
# version instead relocated/patched each input's own GPT in place across
# several sgdisk calls, and repeatedly left the primary and backup GPT
# disagreeing (confirmed against real builds) -- one atomic write
# sidesteps that.
#
# Filesystem UUIDs are never touched -- every OS partition is a verbatim
# copy with its PARTUUID preserved, so GRUB's `search --fs-uuid` and
# /etc/fstab keep working unchanged.
#
# Usage: compose-sdcard-image.sh <firmware.img> <bib-raw-image> <output.raw>

set -euo pipefail

FIRMWARE_IMG="${1:?usage: $0 <firmware.img> <bib-raw-image> <output.raw>}"
OS_RAW_IMG="${2:?usage: $0 <firmware.img> <bib-raw-image> <output.raw>}"
OUTPUT_IMG="${3:?usage: $0 <firmware.img> <bib-raw-image> <output.raw>}"

for tool in sgdisk dd truncate sha256sum od; do
    command -v "${tool}" >/dev/null || {
        echo "error: required tool '${tool}' not found" >&2
        exit 1
    }
done

RESERVED_MIB=16
RESERVED_BYTES=$((RESERVED_MIB * 1024 * 1024))
SECTOR=512
ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
# Reserved (firmware) partition start -- 2048-sector/1 MiB alignment,
# matching the firmware image's own GPT (confirmed) and every modern
# partitioning tool's default.
RESERVED_START_SECTOR=2048

# This UEFI-only image should only ever have a protective MBR (one entry,
# type 0xee, others all-zero) -- a hybrid MBR (non-zero entries alongside
# it) is a legacy BIOS+GPT trick unused here. sgdisk itself hedges
# ("Found protective or hybrid MBR...") once the GPT looks corrupt, so
# check the actual bytes instead of trusting that message.
assert_protective_mbr() {
    local img="$1"
    local hex
    # -v: od's default collapses repeated lines into "*", which would
    # swallow the all-zero bytes this check exists to inspect.
    hex=$(od -v -An -tx1 -j 446 -N 64 "${img}" | tr -s ' \n' ' ')
    read -ra mbr_bytes <<<"${hex}"
    if [[ ${#mbr_bytes[@]} -ne 64 ]]; then
        echo "error: couldn't read the 64-byte MBR partition table from ${img} (got ${#mbr_bytes[@]} bytes)" >&2
        exit 1
    fi

    local type1="${mbr_bytes[4]}"
    if [[ "${type1}" != "ee" ]]; then
        echo "error: ${img}'s MBR partition 1 has type 0x${type1}, expected 0xee (protective MBR) -- not a plain GPT-protected disk" >&2
        exit 1
    fi

    local entry byte
    for entry in 1 2 3; do
        for byte in $(seq 0 15); do
            if [[ "${mbr_bytes[$((entry * 16 + byte))]}" != "00" ]]; then
                echo "error: ${img}'s MBR partition $((entry + 1)) is non-zero -- this is a hybrid MBR, not a plain protective one" >&2
                exit 1
            fi
        done
    done
}

# Fails loudly with a full sgdisk -p dump, rather than relying on
# `sgdisk --verify`'s bare exit code under `set -e`, which doesn't say
# which step broke or show the disk's actual state.
assert_gpt_ok() {
    local img="$1"
    if ! sgdisk --verify "${img}"; then
        echo "error: sgdisk --verify failed for ${img} -- dumping partition table for diagnosis:" >&2
        sgdisk -p "${img}" >&2 || true
        exit 1
    fi
    assert_protective_mbr "${img}"
}

FW_SIZE=$(stat -c '%s' "${FIRMWARE_IMG}")
if [[ "${FW_SIZE}" -ge "${RESERVED_BYTES}" ]]; then
    echo "error: firmware image (${FW_SIZE} bytes) does not fit in the ${RESERVED_MIB} MiB reserved region" >&2
    exit 1
fi

# Read the firmware's own partition type/name now, before its GPT gets
# zapped below -- last point it's still readable. Only type/name carry
# real meaning to preserve (upstream convention, e.g. type 8300
# 'uboot'); the reserved region's own boundaries are ours, not copied.
fw_info=$(sgdisk -i 1 "${FIRMWARE_IMG}") || {
    echo "error: firmware image ${FIRMWARE_IMG} doesn't have a partition 1 to read a type/name from" >&2
    exit 1
}
FW_TYPECODE=$(awk -F': ' '/^Partition GUID code/ {print $2}' <<<"${fw_info}" | awk '{print $1}')
FW_NAME=$(awk -F"'" '/^Partition name/ {print $2}' <<<"${fw_info}")
if [[ -z "${FW_TYPECODE}" ]]; then
    echo "error: couldn't read a partition type from ${FIRMWARE_IMG}'s partition 1" >&2
    exit 1
fi

OS_SIZE=$(stat -c '%s' "${OS_RAW_IMG}")

# First partition's start sector -- everything before it (protective MBR
# + primary GPT) is discarded; we build a fresh GPT instead.
OLD_BASE_SECTOR=$(sgdisk -p "${OS_RAW_IMG}" | awk '$1 ~ /^[0-9]+$/ {print $2; exit}')
if [[ -z "${OLD_BASE_SECTOR}" ]]; then
    echo "error: could not read a partition table from ${OS_RAW_IMG}" >&2
    exit 1
fi
OLD_BASE_BYTES=$((OLD_BASE_SECTOR * SECTOR))

# The dd copy below runs at bs=1M for speed -- only safe if the source
# partition's start offset is a whole number of MiB (true for any normal
# 1 MiB-aligned table), so check rather than silently mis-copy.
if [[ $((OLD_BASE_BYTES % (1024 * 1024))) -ne 0 ]]; then
    echo "error: source image's first partition (sector ${OLD_BASE_SECTOR}) isn't 1 MiB-aligned, can't safely bs=1M copy it" >&2
    exit 1
fi

NEW_BASE_SECTOR=$((RESERVED_BYTES / SECTOR))
if [[ "${NEW_BASE_SECTOR}" -lt "${OLD_BASE_SECTOR}" ]]; then
    echo "error: reserved region (${NEW_BASE_SECTOR} sectors) is smaller than the source image's own partition offset (${OLD_BASE_SECTOR} sectors)" >&2
    exit 1
fi
DELTA_SECTORS=$((NEW_BASE_SECTOR - OLD_BASE_SECTOR))

TOTAL_BYTES=$((RESERVED_BYTES + OS_SIZE - OLD_BASE_BYTES))

echo "== Composing ROCK 5C image =="
echo "  firmware:        ${FIRMWARE_IMG} (${FW_SIZE} bytes, reserved ${RESERVED_MIB} MiB, type ${FW_TYPECODE}, name '${FW_NAME}')"
echo "  OS raw image:    ${OS_RAW_IMG} (${OS_SIZE} bytes, first partition at sector ${OLD_BASE_SECTOR})"
echo "  output:          ${OUTPUT_IMG} (${TOTAL_BYTES} bytes)"
echo "  partition shift: +${DELTA_SECTORS} sectors"

rm -f "${OUTPUT_IMG}"
truncate -s "${TOTAL_BYTES}" "${OUTPUT_IMG}"

# 1. Firmware payload, at the front of the disk (offset 0) -- where the
#    boot ROM actually looks for it, regardless of anything the GPT says.
dd if="${FIRMWARE_IMG}" of="${OUTPUT_IMG}" bs=1M conv=notrunc,fsync status=progress

# 2. OS partition data: copied verbatim, moved to start ${RESERVED_MIB}
#    MiB into the disk instead of sector 0. This also carries over the OS
#    image's trailing backup GPT (lands at the combined disk's own last
#    sector) -- harmless, since it gets wiped in the next step regardless.
dd if="${OS_RAW_IMG}" of="${OUTPUT_IMG}" bs=1M \
    skip=$((OLD_BASE_BYTES / 1024 / 1024)) \
    seek=$((RESERVED_BYTES / 1024 / 1024)) \
    conv=notrunc,fsync status=progress

# 3. Discard both inputs' now-meaningless GPTs (and the firmware's
#    protective MBR) entirely, leaving a blank slate sized to the combined
#    disk's real, final byte count.
sgdisk --zap-all "${OUTPUT_IMG}"

# 4. Build the entire combined GPT -- reserved region plus every OS
#    partition, preserving size/type/name/PARTUUID and attribute bits
#    (e.g. bit 59 GUID_FLAG_NO_AUTO/GROWFS-style flags some tooling sets
#    on root -- costs nothing to keep, so kept rather than guessed at) --
#    as one sgdisk invocation. sgdisk writes to disk exactly once, at the
#    end, so primary and backup can never disagree.
sgdisk_args=(
    "--new=1:${RESERVED_START_SECTOR}:$((NEW_BASE_SECTOR - 1))"
    "--typecode=1:${FW_TYPECODE}"
    "--change-name=1:${FW_NAME}"
)

mapfile -t part_numbers < <(sgdisk -p "${OS_RAW_IMG}" | awk '$1 ~ /^[0-9]+$/ {print $1}')

new_num=2
found_esp=false
for old_num in "${part_numbers[@]}"; do
    info=$(sgdisk -i "${old_num}" "${OS_RAW_IMG}")

    old_start=$(awk -F': ' '/^First sector/ {print $2}' <<<"${info}" | awk '{print $1}')
    old_end=$(awk -F': ' '/^Last sector/ {print $2}' <<<"${info}" | awk '{print $1}')
    typecode=$(awk -F': ' '/^Partition GUID code/ {print $2}' <<<"${info}" | awk '{print $1}')
    partuuid=$(awk -F': ' '/^Partition unique GUID/ {print $2}' <<<"${info}" | awk '{print $1}')
    name=$(awk -F"'" '/^Partition name/ {print $2}' <<<"${info}")
    attributes=$(awk -F': ' '/^Attribute flags/ {print $2}' <<<"${info}")

    new_start=$((old_start + DELTA_SECTORS))
    new_end=$((old_end + DELTA_SECTORS))

    echo "  partition ${old_num} -> ${new_num}: sectors ${new_start}-${new_end}, type ${typecode}, name '${name}'"

    sgdisk_args+=(
        "--new=${new_num}:${new_start}:${new_end}"
        "--typecode=${new_num}:${typecode}"
        "--change-name=${new_num}:${name}"
        "--partition-guid=${new_num}:${partuuid}"
    )
    if [[ -n "${attributes}" ]]; then
        sgdisk_args+=("--attributes=${new_num}:=:${attributes}")
    fi

    if [[ "${typecode,,}" == "${ESP_GUID}" ]]; then
        found_esp=true
    fi

    new_num=$((new_num + 1))
done

# UEFI-only image (no BIOS/legacy fallback) -- confirm an EFI System
# Partition actually made it across rather than assume it.
if [[ "${found_esp}" != "true" ]]; then
    echo "error: no EFI System Partition (${ESP_GUID}) found among ${OS_RAW_IMG}'s partitions -- this image would not be UEFI-bootable" >&2
    exit 1
fi

sgdisk "${sgdisk_args[@]}" "${OUTPUT_IMG}"

assert_gpt_ok "${OUTPUT_IMG}"
sgdisk -p "${OUTPUT_IMG}"

echo "== Done: ${OUTPUT_IMG} =="
