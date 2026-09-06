#!/bin/bash
#
# Composes a flashable board image from a firmware blob and a bootc-image-builder
# "raw" output. Two board families need this, in different ways -- picked by
# <layout>:
#
#   raw: RK3588's boot ROM reads firmware from a fixed disk offset, never a
#        partition entry (confirmed: upstream's `dd skip=64 seek=64`), and has no
#        onboard SPI-NOR, so firmware has to share the OS disk. Strategy: dd
#        firmware to offset 0, OS data to an aligned offset after, then build ONE
#        fresh GPT in one sgdisk call (an earlier per-input-patch left GPTs
#        disagreeing). Filesystem UUIDs are never touched -- every OS partition is
#        a verbatim copy with its PARTUUID preserved, so GRUB's `search --fs-uuid`
#        and /etc/fstab keep working.
#
#   fat: a Raspberry Pi's EEPROM bootloader just wants the first FAT partition --
#        already the ESP bootc-image-builder made -- so firmware (a zip: RPI_EFI.fd,
#        config.txt, device trees, and -- Pi 4B only -- start4.elf/fixup4.dat/
#        overlays/) is copied into that filesystem via mtools instead, no GPT
#        changes needed.
#
# Usage: compose-sdcard-image.sh <raw|fat> <firmware> <bib-raw-image> <output.raw>

set -euo pipefail

USAGE="usage: $0 <raw|fat> <firmware> <bib-raw-image> <output.raw>"
LAYOUT="${1:?${USAGE}}"
FIRMWARE="${2:?${USAGE}}"
OS_RAW_IMG="${3:?${USAGE}}"
OUTPUT_IMG="${4:?${USAGE}}"

ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
SECTOR=512

require_tools() {
    for tool in "$@"; do
        command -v "${tool}" >/dev/null || {
            echo "error: required tool '${tool}' not found" >&2
            exit 1
        }
    done
}

# This UEFI-only image should only have a protective MBR (type 0xee, rest zero) --
# sgdisk's own hedge message fires on any corrupt-looking GPT, so check actual bytes.
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

# Fails loudly with a full sgdisk -p dump, rather than `sgdisk --verify`'s bare exit code
# under `set -e`, which doesn't say which step broke or show the disk's state.
assert_gpt_ok() {
    local img="$1"
    if ! sgdisk --verify "${img}"; then
        echo "error: sgdisk --verify failed for ${img} -- dumping partition table for diagnosis:" >&2
        sgdisk -p "${img}" >&2 || true
        exit 1
    fi
    assert_protective_mbr "${img}"
}

compose_raw() {
    local firmware_img="$1" os_raw_img="$2" output_img="$3"
    require_tools sgdisk dd truncate sha256sum od

    local reserved_mib=16
    local reserved_bytes=$((reserved_mib * 1024 * 1024))
    # Reserved (firmware) partition start -- 2048-sector/1 MiB alignment, matching the
    # firmware's own GPT (confirmed) and every modern partitioning tool's default.
    local reserved_start_sector=2048

    local fw_size
    fw_size=$(stat -c '%s' "${firmware_img}")
    if [[ "${fw_size}" -ge "${reserved_bytes}" ]]; then
        echo "error: firmware image (${fw_size} bytes) does not fit in the ${reserved_mib} MiB reserved region" >&2
        exit 1
    fi

    # Read the firmware's partition type/name now, before its GPT is zapped -- last point
    # it's readable. Only type/name carry real meaning (e.g. type 8300 'uboot').
    local fw_info
    fw_info=$(sgdisk -i 1 "${firmware_img}") || {
        echo "error: firmware image ${firmware_img} doesn't have a partition 1 to read a type/name from" >&2
        exit 1
    }
    local fw_typecode fw_name
    fw_typecode=$(awk -F': ' '/^Partition GUID code/ {print $2}' <<<"${fw_info}" | awk '{print $1}')
    fw_name=$(awk -F"'" '/^Partition name/ {print $2}' <<<"${fw_info}")
    if [[ -z "${fw_typecode}" ]]; then
        echo "error: couldn't read a partition type from ${firmware_img}'s partition 1" >&2
        exit 1
    fi

    local os_size
    os_size=$(stat -c '%s' "${os_raw_img}")

    # First partition's start sector -- everything before it (protective MBR
    # + primary GPT) is discarded; we build a fresh GPT instead.
    local old_base_sector
    old_base_sector=$(sgdisk -p "${os_raw_img}" | awk '$1 ~ /^[0-9]+$/ {print $2; exit}')
    if [[ -z "${old_base_sector}" ]]; then
        echo "error: could not read a partition table from ${os_raw_img}" >&2
        exit 1
    fi
    local old_base_bytes=$((old_base_sector * SECTOR))

    # The dd copy below runs at bs=1M for speed -- only safe if the source partition's start
    # is a whole MiB (true for any normal aligned table), so check, don't silently mis-copy.
    if [[ $((old_base_bytes % (1024 * 1024))) -ne 0 ]]; then
        echo "error: source image's first partition (sector ${old_base_sector}) isn't 1 MiB-aligned, can't safely bs=1M copy it" >&2
        exit 1
    fi

    local new_base_sector=$((reserved_bytes / SECTOR))
    if [[ "${new_base_sector}" -lt "${old_base_sector}" ]]; then
        echo "error: reserved region (${new_base_sector} sectors) is smaller than the source image's own partition offset (${old_base_sector} sectors)" >&2
        exit 1
    fi
    local delta_sectors=$((new_base_sector - old_base_sector))

    local total_bytes=$((reserved_bytes + os_size - old_base_bytes))

    echo "== Composing raw-firmware image =="
    echo "  firmware:        ${firmware_img} (${fw_size} bytes, reserved ${reserved_mib} MiB, type ${fw_typecode}, name '${fw_name}')"
    echo "  OS raw image:    ${os_raw_img} (${os_size} bytes, first partition at sector ${old_base_sector})"
    echo "  output:          ${output_img} (${total_bytes} bytes)"
    echo "  partition shift: +${delta_sectors} sectors"

    rm -f "${output_img}"
    truncate -s "${total_bytes}" "${output_img}"

    # 1. Firmware payload, at the front of the disk (offset 0) -- where the
    #    boot ROM actually looks for it, regardless of anything the GPT says.
    dd if="${firmware_img}" of="${output_img}" bs=1M conv=notrunc,fsync status=progress

    # 2. OS partition data: copied verbatim, moved to start ${reserved_mib} MiB in instead
    #    of sector 0 (also carries the OS image's backup GPT -- harmless, wiped next).
    dd if="${os_raw_img}" of="${output_img}" bs=1M \
        skip=$((old_base_bytes / 1024 / 1024)) \
        seek=$((reserved_bytes / 1024 / 1024)) \
        conv=notrunc,fsync status=progress

    # 3. Discard both inputs' now-meaningless GPTs (and the firmware's protective MBR),
    #    leaving a blank slate sized to the combined disk's real final byte count.
    sgdisk --zap-all "${output_img}"

    # 4. Build the entire combined GPT (reserved region + every OS partition, preserving
    #    size/type/name/PARTUUID/attrs) in one sgdisk call -- one write, GPTs can't disagree.
    local sgdisk_args=(
        "--new=1:${reserved_start_sector}:$((new_base_sector - 1))"
        "--typecode=1:${fw_typecode}"
        "--change-name=1:${fw_name}"
    )

    local part_numbers
    mapfile -t part_numbers < <(sgdisk -p "${os_raw_img}" | awk '$1 ~ /^[0-9]+$/ {print $1}')

    local new_num=2 found_esp=false
    for old_num in "${part_numbers[@]}"; do
        local info old_start old_end typecode partuuid name attributes new_start new_end
        info=$(sgdisk -i "${old_num}" "${os_raw_img}")

        old_start=$(awk -F': ' '/^First sector/ {print $2}' <<<"${info}" | awk '{print $1}')
        old_end=$(awk -F': ' '/^Last sector/ {print $2}' <<<"${info}" | awk '{print $1}')
        typecode=$(awk -F': ' '/^Partition GUID code/ {print $2}' <<<"${info}" | awk '{print $1}')
        partuuid=$(awk -F': ' '/^Partition unique GUID/ {print $2}' <<<"${info}" | awk '{print $1}')
        name=$(awk -F"'" '/^Partition name/ {print $2}' <<<"${info}")
        attributes=$(awk -F': ' '/^Attribute flags/ {print $2}' <<<"${info}")

        new_start=$((old_start + delta_sectors))
        new_end=$((old_end + delta_sectors))

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
        echo "error: no EFI System Partition (${ESP_GUID}) found among ${os_raw_img}'s partitions -- this image would not be UEFI-bootable" >&2
        exit 1
    fi

    sgdisk "${sgdisk_args[@]}" "${output_img}"

    assert_gpt_ok "${output_img}"
    sgdisk -p "${output_img}"
}

compose_fat() {
    local firmware_zip="$1" os_raw_img="$2" output_img="$3"
    require_tools sgdisk mcopy unzip

    cp -f "${os_raw_img}" "${output_img}"

    # Find the ESP -- the Pi's bootloader ignores GPT type GUIDs, it just wants the
    # first FAT partition, so this is the one it'll read as-is.
    local esp_num="" num typecode
    local part_numbers
    mapfile -t part_numbers < <(sgdisk -p "${output_img}" | awk '$1 ~ /^[0-9]+$/ {print $1}')
    for num in "${part_numbers[@]}"; do
        typecode=$(sgdisk -i "${num}" "${output_img}" | awk -F': ' '/^Partition GUID code/ {print $2}' | awk '{print $1}')
        if [[ "${typecode,,}" == "${ESP_GUID}" ]]; then
            esp_num="${num}"
            break
        fi
    done
    if [[ -z "${esp_num}" ]]; then
        echo "error: no EFI System Partition (${ESP_GUID}) found in ${os_raw_img}" >&2
        exit 1
    fi

    local esp_info start_sector offset_bytes
    esp_info=$(sgdisk -i "${esp_num}" "${output_img}")
    start_sector=$(awk -F': ' '/^First sector/ {print $2}' <<<"${esp_info}" | awk '{print $1}')
    if [[ -z "${start_sector}" ]]; then
        echo "error: couldn't read partition ${esp_num}'s start sector from ${output_img}" >&2
        exit 1
    fi
    offset_bytes=$((start_sector * SECTOR))

    # "@@offset": mtools reads the FAT filesystem starting at that byte offset directly,
    # no loop mount needed.
    local mtools_img="${output_img}@@${offset_bytes}"

    # Not `local`: the EXIT trap below fires at the *script's* real exit, after this
    # function has already returned and any local would be out of scope (confirmed:
    # "tmp_extract: unbound variable" under set -u).
    tmp_extract=$(mktemp -d)
    trap 'rm -rf "${tmp_extract}"' EXIT
    unzip -q "${firmware_zip}" -d "${tmp_extract}"

    echo "== Composing FAT-firmware image =="
    echo "  firmware:   ${firmware_zip}"
    echo "  OS raw img: ${os_raw_img}"
    echo "  ESP:        partition ${esp_num}, offset ${offset_bytes} bytes"
    echo "  output:     ${output_img}"

    # Skip firmware/ (Wi-Fi blobs, already in Fedora's linux-firmware) and the zip's Readme.
    shopt -s nullglob
    local entry name copied_any=false
    for entry in "${tmp_extract}"/*; do
        name=$(basename "${entry}")
        case "${name,,}" in
            firmware | readme.md | license.txt | licence.txt) continue ;;
        esac
        echo "  + ${name}"
        # -s: recurse (overlays/); -o: overwrite.
        mcopy -s -o -i "${mtools_img}" "${entry}" "::"
        copied_any=true
    done

    if [[ "${copied_any}" != "true" ]]; then
        echo "error: ${firmware_zip} had nothing to copy (unexpected archive layout)" >&2
        exit 1
    fi
}

case "${LAYOUT}" in
    raw) compose_raw "${FIRMWARE}" "${OS_RAW_IMG}" "${OUTPUT_IMG}" ;;
    fat) compose_fat "${FIRMWARE}" "${OS_RAW_IMG}" "${OUTPUT_IMG}" ;;
    *)
        echo "error: unknown layout '${LAYOUT}' -- ${USAGE}" >&2
        exit 1
        ;;
esac

echo "== Done: ${OUTPUT_IMG} =="
