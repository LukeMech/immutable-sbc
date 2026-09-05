#!/bin/bash

set -ouex pipefail

### Never install weak dependencies (Recommends/Supplements)
#
# Runs first (sorts before every other hook) so every dnf5 install below
# and in later scripts is covered -- this is what was pulling in
# gnome-tour despite nothing ever asking for it.
sed -i '/^\[main\]/a install_weak_deps=False' /etc/dnf/dnf.conf

### Grow root on first boot
#
# Image is built small on purpose (disk_config/disk.toml's 1 GiB floor)
# and flashed onto a much larger card -- the growroot service
# (system_files/usr/lib/systemd/system/..., running .../grow-root.sh)
# grows root to fill the disk on every boot (no-op once already maxed).
dnf5 install -y cloud-utils-growpart btrfs-progs
systemctl enable immutable-sbc-growroot.service

