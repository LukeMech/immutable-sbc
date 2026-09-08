#!/bin/bash

set -ouex pipefail

### uefi-updater (system_files/usr/libexec/immutable-sbc/uefi-updater.py)
#
# OTA updates for board UEFI firmware, the same pinned-by-URL+sha256 source
# images/boards.toml already declares for flash-time use (build-flash.yml) --
# checked periodically (uefi-updater.timer, not tied to boot ordering -- a board
# needing interactive Wi-Fi setup might not be online yet at boot at all), a no-op
# unless the board's pinned edk2_sha256 differs from what's recorded as last
# installed. See uefi-updater.py's own docstring for why raw vs. fat apply
# differently, and specifically how the raw case avoids ever touching the live
# disk's own GPT.

install -Dm644 /ctx/images/boards.toml /usr/share/uefi-updater/boards.toml

# Reused verbatim, not reimplemented -- same download+verify code path build-flash.yml
# already uses for every board's firmware.
install -Dm755 /ctx/scripts/fetch-firmware.sh /usr/libexec/immutable-sbc/fetch-firmware.sh

# git only tracks the executable bit inconsistently (same fixup as 05-gnome-minimal.sh's
# lm-nopasswd and 10-hailo-npu-run.sh's hailo_infer.py).
chmod 755 /usr/libexec/immutable-sbc/uefi-updater.py

# sgdisk: only the raw layout's live-disk GPT sanity check (uefi-updater.py) needs it --
# rpi's fat layout never touches a raw disk, just the already-mounted ESP.
case "${VARIANT}" in
    rk3588) dnf5 -y install gdisk ;;
    rpi) ;;
esac

systemctl enable uefi-updater.timer
