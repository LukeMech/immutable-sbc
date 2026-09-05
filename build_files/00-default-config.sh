#!/bin/bash

set -ouex pipefail

### Never install weak dependencies (Recommends/Supplements)
#
# Runs first (00-default-config.sh sorts before every other hook here
# and in images/<variant>/build_files/) so every dnf5 install call for
# the rest of the build is covered by this, not just the ones we
# remembered to add --setopt=install_weak_deps=False to individually --
# this is what was pulling in gnome-tour despite nothing here ever
# asking for it (01-gnome-minimal.sh no longer needs its own
# --exclude=gnome-tour because of this).
sed -i '/^\[main\]/a install_weak_deps=False' /etc/dnf/dnf.conf

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

