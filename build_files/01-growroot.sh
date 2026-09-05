#!/bin/bash

set -ouex pipefail

### Grow root on first boot
#
# The raw image is deliberately built small (disk_config/disk.toml's
# 1 GiB floor) and flashed onto a much larger microSD/eMMC --
# system_files/usr/lib/systemd/system/immutable-sbc-growroot.service
# (running system_files/usr/libexec/immutable-sbc/grow-root.sh) grows
# the root partition and its btrfs filesystem to fill the rest of the
# disk on every boot (a no-op once already at max size).

dnf5 install -y cloud-utils-growpart btrfs-progs

systemctl enable immutable-sbc-growroot.service
