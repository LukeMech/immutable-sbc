#!/bin/bash
#
# Composes the final ROCK 5C microSD/eMMC image out of two independently
# built inputs:
#
#   1. The ROCK 5C EDK2 UEFI firmware image (fetch-edk2-firmware.sh, in
#      this same directory).
#      This is not a normal "ESP" -- it's the actual boot firmware. It ships
#      its own tiny GPT with a single reserved partition covering IDBlock +
#      UEFI firmware volume + NVRAM variable store, per the upstream
#      instructions: "flash UEFI first, then create any additional
#      partitions without touching the first, reserved one."
#      https://github.com/edk2-porting/edk2-rk3588
#
#   2. A normal bootc-image-builder "raw" output (ESP + boot + root, GPT
#      starting at sector 0), which knows nothing about any of this.
#
# The ROCK 5C has no onboard SPI-NOR (it's an optional, eMMC-connector-
# exclusive accessory), so the firmware has to live on the same medium as
# the OS on every image we ship -- there's no "flash UEFI once to SPI"
# shortcut for the common case.
#
# Strategy: dd the firmware to the front of a fresh image (offset 0), then
# copy the *partition data* (not the GPT) of the OS image to a 16 MiB
# aligned offset after it, and re-register those same partitions (same
# sizes, type GUIDs and unique PARTUUIDs) in the combined GPT. Filesystem
# UUIDs are never touched -- we relocate partition table entries, we never
# reformat -- so GRUB's `search --fs-uuid` and /etc/fstab keep working
# with zero changes.
#
# Usage: compose-sdcard-image.sh <firmware.img> <bib-raw-image> <output.raw>

set -euo pipefail

FIRMWARE_IMG="${1:?usage: $0 <firmware.img> <bib-raw-image> <output.raw>}"
OS_RAW_IMG="${2:?usage: $0 <firmware.img> <bib-raw-image> <output.raw>}"
OUTPUT_IMG="${3:?usage: $0 <firmware.img> <bib-raw-image> <output.raw>}"

for tool in sgdisk dd truncate sha256sum; do
    command -v "${tool}" >/dev/null || {
        echo "error: required tool '${tool}' not found" >&2
        exit 1
    }
done

RESERVED_MIB=16
RESERVED_BYTES=$((RESERVED_MIB * 1024 * 1024))
SECTOR=512

FW_SIZE=$(stat -c '%s' "${FIRMWARE_IMG}")
if [[ "${FW_SIZE}" -ge "${RESERVED_BYTES}" ]]; then
    echo "error: firmware image (${FW_SIZE} bytes) does not fit in the ${RESERVED_MIB} MiB reserved region" >&2
    exit 1
fi

OS_SIZE=$(stat -c '%s' "${OS_RAW_IMG}")

# First partition's start sector in the source image -- everything before
# it (protective MBR + primary GPT header/table) is discarded; we build a
# fresh GPT for the combined disk instead.
OLD_BASE_SECTOR=$(sgdisk -p "${OS_RAW_IMG}" | awk '$1 ~ /^[0-9]+$/ {print $2; exit}')
if [[ -z "${OLD_BASE_SECTOR}" ]]; then
    echo "error: could not read a partition table from ${OS_RAW_IMG}" >&2
    exit 1
fi
OLD_BASE_BYTES=$((OLD_BASE_SECTOR * SECTOR))

# The big dd copy below runs at bs=1M for speed (sector-sized I/O on a
# multi-GB image is painfully slow). That's only safe if the source
# partition's start offset is itself a whole number of MiB -- true for
# any normal 1 MiB/2048-sector-aligned partition table, but check rather
# than silently mis-copying data if it somehow isn't.
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
echo "  firmware:        ${FIRMWARE_IMG} (${FW_SIZE} bytes, reserved ${RESERVED_MIB} MiB)"
echo "  OS raw image:    ${OS_RAW_IMG} (${OS_SIZE} bytes, first partition at sector ${OLD_BASE_SECTOR})"
echo "  output:          ${OUTPUT_IMG} (${TOTAL_BYTES} bytes)"
echo "  partition shift: +${DELTA_SECTORS} sectors"

rm -f "${OUTPUT_IMG}"
truncate -s "${TOTAL_BYTES}" "${OUTPUT_IMG}"

# 1. Firmware: lays down its own GPT + reserved partition + boot blobs at
#    the front of the disk.
dd if="${FIRMWARE_IMG}" of="${OUTPUT_IMG}" bs=1M conv=notrunc,fsync status=progress

# The firmware image's own GPT header still describes a disk the size of
# the firmware image itself, not our (much larger) truncated output file,
# so its backup header/table now point at the wrong LBA. sgdisk would
# otherwise notice the mismatch and interactively ask which table to
# trust -- `-e` is the documented non-interactive fix for exactly this
# ("some other tool" resized the disk underneath it.
sgdisk -e "${OUTPUT_IMG}"

fw_part_count=$(sgdisk -p "${OUTPUT_IMG}" | awk '$1 ~ /^[0-9]+$/ {c++} END{print c+0}')
if [[ "${fw_part_count}" -lt 1 ]]; then
    echo "error: firmware image did not leave a reserved partition behind" >&2
    exit 1
fi

# 2. OS partition data: copied verbatim (never reformatted), just moved to
#    start ${RESERVED_MIB} MiB into the disk instead of at sector 0.
dd if="${OS_RAW_IMG}" of="${OUTPUT_IMG}" bs=1M \
    skip=$((OLD_BASE_BYTES / 1024 / 1024)) \
    seek=$((RESERVED_BYTES / 1024 / 1024)) \
    conv=notrunc,fsync status=progress

# 3. Re-register the OS partitions in the combined GPT, after the
#    firmware's reserved partition(s), preserving size/type/name/PARTUUID.
mapfile -t part_numbers < <(sgdisk -p "${OS_RAW_IMG}" | awk '$1 ~ /^[0-9]+$/ {print $1}')

new_num=$((fw_part_count + 1))
for old_num in "${part_numbers[@]}"; do
    info=$(sgdisk -i "${old_num}" "${OS_RAW_IMG}")

    old_start=$(awk -F': ' '/^First sector/ {print $2}' <<<"${info}" | awk '{print $1}')
    old_end=$(awk -F': ' '/^Last sector/ {print $2}' <<<"${info}" | awk '{print $1}')
    typecode=$(awk -F': ' '/^Partition GUID code/ {print $2}' <<<"${info}" | awk '{print $1}')
    partuuid=$(awk -F': ' '/^Partition unique GUID/ {print $2}' <<<"${info}" | awk '{print $1}')
    name=$(awk -F"'" '/^Partition name/ {print $2}' <<<"${info}")

    new_start=$((old_start + DELTA_SECTORS))
    new_end=$((old_end + DELTA_SECTORS))

    echo "  partition ${old_num} -> ${new_num}: sectors ${new_start}-${new_end}, type ${typecode}, name '${name}'"

    sgdisk \
        --new="${new_num}:${new_start}:${new_end}" \
        --typecode="${new_num}:${typecode}" \
        --change-name="${new_num}:${name}" \
        --partition-guid="${new_num}:${partuuid}" \
        "${OUTPUT_IMG}"

    new_num=$((new_num + 1))
done

sgdisk --verify "${OUTPUT_IMG}"
sgdisk -p "${OUTPUT_IMG}"

echo "== Done: ${OUTPUT_IMG} =="
