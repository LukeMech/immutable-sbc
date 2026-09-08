#!/bin/bash

set -ouex pipefail

### install-internal (images/rk3588/system_files/usr/bin/install-internal)
#
# Clones the running microSD onto the board's internal eMMC. rk3588-only (rock-5c
# has an eMMC socket, rpi has no second internal disk), so this lives here rather
# than a shared build_files/ hook.
#
# git only tracks the executable bit inconsistently (same fixup as
# 01-uefi-updater.sh's uefi-updater.py and 05-gnome-minimal.sh's lm-nopasswd).
chmod 755 /usr/bin/install-internal
