#!/usr/bin/python3
"""Checks the running board's UEFI firmware against images/boards.toml (shipped
read-only at /usr/share/uefi-updater/boards.toml) and applies an update if the
board's pinned edk2_sha256 doesn't match what's recorded as last installed.

Board identification: /proc/device-tree/model, substring-matched against each
boards.toml entry's own dt_model -- the only thing that lets one shared rpi image
tell an rpi-4b apart from an rpi-5 at runtime (images/boards.toml itself has no
runtime component otherwise; see build-flash.yml for how it's used at flash time).

firmware_layout drives how the update is actually applied, same split as
scripts/compose-sdcard-image.sh uses when first composing the flashable image:

  raw (rock-5c): the firmware asset is itself a small GPT-partitioned disk image
  (see compose-sdcard-image.sh's compose_raw) that gets dd'd wholesale to the real
  disk's offset 0 *only once*, at initial flash time -- compose_raw then wipes and
  rebuilds just the GPT (protective MBR + primary header + partition table: sectors
  0-33, 17408 bytes, the standard on-disk footprint for a default 128-entry GPT)
  over the front of that, discarding the firmware image's own throwaway MBR/GPT
  while leaving everything from sector 34 onward (the real boot payload) in place.
  That sector 34 boundary is exactly what has to be preserved here: the live disk's
  sectors 0-33 are its actual, currently-relied-upon GPT, not leftover firmware
  wrapper, so this script never touches them -- it writes only sector 34 onward,
  verifying the disk's own partition 1 starts at the expected sector 2048 first and
  refusing to touch anything if it doesn't. No GPT-repair step is needed as a
  result, and none was found: sgdisk (unlike interactive gdisk's `r`/`b`/`c`) has no
  documented way to rebuild a primary GPT from a disk's own trailing backup copy.

  fat (rpi-4b/rpi-5): the firmware zip's files are copied straight onto the ESP,
  which is a normal, already-mounted filesystem on a running system -- no raw disk
  access needed at all, unlike compose-sdcard-image.sh's unmounted-image mtools
  trick (only needed there because osbuild's output isn't mounted yet).

The installed-sha256 marker (/var/lib) is only a fast path to skip the network
entirely on the common no-op boot -- it's never trusted blindly for the decision to
actually write. A board's very first boot already has this exact firmware on disk
(compose-sdcard-image.sh just wrote it) but no marker yet (nothing has run there
before), so apply_raw/apply_fat always compare the candidate against what the disk/ESP
actually holds first, only writing if they genuinely differ, and write the marker
afterward either way -- one harmless download on first boot, never a redundant raw
write, and self-healing if the marker and disk were ever somehow out of sync.
"""

import os
import subprocess
import sys
import tempfile
import tomllib
import zipfile
from pathlib import Path

BOARDS_TOML = Path("/usr/share/uefi-updater/boards.toml")
MARKER = Path("/var/lib/uefi-updater/installed-sha256")
BACKUP = Path("/var/lib/uefi-updater/pre-update-backup.img")
FETCH_FIRMWARE = "/usr/libexec/immutable-sbc/fetch-firmware.sh"

SECTOR = 512
# Must match scripts/compose-sdcard-image.sh's own reserved_mib/reserved_start_sector.
RESERVED_MIB = 16
RESERVED_START_SECTOR = 2048
# 1 (protective MBR) + 1 (GPT header) + 32 (a default 128-entry x 128-byte
# partition array) -- see module docstring.
GPT_METADATA_SECTORS = 34


def log(msg):
    print(msg, file=sys.stderr)


def run(*args, **kwargs):
    log(f"+ {' '.join(str(a) for a in args)}")
    return subprocess.run(args, check=True, **kwargs)


def device_tree_model():
    path = Path("/proc/device-tree/model")
    if not path.exists():
        return None
    return path.read_bytes().rstrip(b"\x00").decode("utf-8", "replace")


def detect_board():
    with BOARDS_TOML.open("rb") as f:
        boards = tomllib.load(f)

    model = device_tree_model()
    if not model:
        log("note: no /proc/device-tree/model -- not a device-tree board, nothing to do")
        return None

    for name, data in boards.items():
        dt_model = data.get("dt_model")
        if dt_model and dt_model in model:
            return name, data

    log(f"note: no boards.toml entry matches device-tree model '{model}' -- nothing to do")
    return None


def esp_mountpoint():
    if subprocess.run(
        ["findmnt", "-rno", "TARGET", "/boot/efi"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0:
        return "/boot/efi"

    # Fallback in case this image ever mounts the ESP somewhere else -- whatever's
    # actually mounted as vfat.
    out = run(
        "findmnt", "-rno", "TARGET,FSTYPE",
        capture_output=True, text=True,
    ).stdout
    for line in out.splitlines():
        target, fstype = line.split(maxsplit=1)
        if fstype == "vfat":
            return target
    return None


def disk_for_mountpoint(mountpoint):
    source = run(
        "findmnt", "-no", "SOURCE", mountpoint,
        capture_output=True, text=True,
    ).stdout.strip()
    pkname = run(
        "lsblk", "-rno", "PKNAME", source,
        capture_output=True, text=True,
    ).stdout.strip()
    return f"/dev/{pkname}" if pkname else None


def sgdisk_first_sector(image, partition):
    info = run(
        "sgdisk", "-i", str(partition), str(image),
        capture_output=True, text=True,
    ).stdout
    for line in info.splitlines():
        if line.startswith("First sector:"):
            return int(line.split(":", 1)[1].split()[0])
    return None


def apply_raw(firmware_img, board_name):
    esp = esp_mountpoint()
    if esp is None:
        log("error: could not find the ESP mountpoint")
        sys.exit(1)

    disk = disk_for_mountpoint(esp)
    if disk is None:
        log(f"error: could not determine the disk backing {esp}")
        sys.exit(1)

    # Confirm this disk actually matches compose-sdcard-image.sh's own layout
    # convention before touching it at all -- refuse rather than guess if it doesn't.
    live_start = sgdisk_first_sector(disk, 1)
    if live_start != RESERVED_START_SECTOR:
        log(
            f"error: {disk}'s partition 1 starts at sector {live_start}, expected "
            f"{RESERVED_START_SECTOR} -- this disk doesn't match the layout "
            "compose-sdcard-image.sh builds, refusing to touch it"
        )
        sys.exit(1)

    reserved_bytes = RESERVED_MIB * 1024 * 1024
    fw_size = firmware_img.stat().st_size
    if fw_size >= reserved_bytes:
        log(f"error: firmware image ({fw_size} bytes) does not fit in the {RESERVED_MIB} MiB reserved region")
        sys.exit(1)

    metadata_bytes = GPT_METADATA_SECTORS * SECTOR
    if fw_size <= metadata_bytes:
        log(f"error: firmware image ({fw_size} bytes) is smaller than the GPT metadata region it should start past")
        sys.exit(1)
    payload = firmware_img.read_bytes()[metadata_bytes:]
    payload_sectors = (len(payload) + SECTOR - 1) // SECTOR

    # Compare against what's actually on disk before writing anything -- true on a
    # board's very first boot (compose-sdcard-image.sh just wrote this exact
    # firmware, before any marker existed), and a cheap way to never do a write that
    # wouldn't change anything.
    with open(disk, "rb") as f:
        f.seek(metadata_bytes)
        live_payload = f.read(len(payload))
    if live_payload == payload:
        log(f"{disk} already holds this firmware byte-for-byte -- nothing to write")
        return

    # Cheap local rollback path in case of a bug here, not disaster recovery for a
    # damaged disk -- saves what's currently in the write target before touching it.
    BACKUP.parent.mkdir(parents=True, exist_ok=True)
    backup_sectors = (reserved_bytes - metadata_bytes) // SECTOR
    run(
        "dd", f"if={disk}", f"of={BACKUP}", f"bs={SECTOR}",
        f"skip={GPT_METADATA_SECTORS}", f"count={backup_sectors}",
        "conv=fsync", "status=none",
    )
    log(f"Backed up current reserved-region contents to {BACKUP}")

    log(
        f"Writing {firmware_img} to {disk} (board {board_name}), sectors "
        f"{GPT_METADATA_SECTORS}-{GPT_METADATA_SECTORS + payload_sectors} -- "
        f"{disk}'s own GPT (sectors 0-{GPT_METADATA_SECTORS - 1}) is left untouched"
    )
    with open(disk, "r+b") as f:
        f.seek(metadata_bytes)
        f.write(payload)
        f.flush()
        os.fsync(f.fileno())


def apply_fat(firmware_zip):
    esp = esp_mountpoint()
    if esp is None:
        log("error: could not find the ESP mountpoint")
        sys.exit(1)

    skip_top_names = {"firmware", "readme.md", "license.txt", "licence.txt"}
    found_any = changed_any = False
    with tempfile.TemporaryDirectory() as tmp:
        with zipfile.ZipFile(firmware_zip) as zf:
            zf.extractall(tmp)

        for entry in sorted(Path(tmp).rglob("*")):
            if entry.is_dir():
                continue
            rel = entry.relative_to(tmp)
            if rel.parts[0].lower() in skip_top_names:
                continue
            found_any = True

            dest = Path(esp) / rel
            candidate = entry.read_bytes()
            # Same reasoning as apply_raw: compare before writing, both to skip a
            # board's very first boot (already has this firmware, no marker yet)
            # and to never touch a file that isn't actually changing.
            if dest.exists() and dest.read_bytes() == candidate:
                continue

            log(f"  + {rel}")
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(candidate)
            changed_any = True

    if not found_any:
        log(f"error: {firmware_zip} had nothing to copy (unexpected archive layout)")
        sys.exit(1)
    if not changed_any:
        log(f"{esp} already matches this firmware byte-for-byte -- nothing to write")


def main():
    detected = detect_board()
    if detected is None:
        return
    board_name, board = detected

    url = board.get("edk2_url")
    sha256 = board.get("edk2_sha256")
    if not url or not sha256:
        log(f"note: {board_name} declares no edk2_url/edk2_sha256 -- nothing to do")
        return

    if MARKER.exists() and MARKER.read_text().strip() == sha256:
        log(f"UEFI firmware for {board_name} already up to date ({sha256})")
        return

    layout = board.get("firmware_layout", "raw")
    log(f"UEFI firmware update available for {board_name}: {sha256} (layout={layout})")

    with tempfile.TemporaryDirectory() as tmp:
        firmware = Path(tmp) / "firmware"
        run(FETCH_FIRMWARE, url, sha256, str(firmware))

        if layout == "raw":
            apply_raw(firmware, board_name)
        elif layout == "fat":
            apply_fat(firmware)
        else:
            log(f"error: unknown firmware_layout '{layout}'")
            sys.exit(1)

    MARKER.parent.mkdir(parents=True, exist_ok=True)
    MARKER.write_text(sha256 + "\n")
    log(f"UEFI firmware for {board_name} updated to {sha256}")


if __name__ == "__main__":
    main()
