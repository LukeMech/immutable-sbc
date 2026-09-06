#!/bin/bash

set -ouex pipefail

### Never install weak dependencies (Recommends/Supplements)
#
# Runs first so every dnf5 install below is covered -- this is what
# pulled in gnome-tour unasked.
sed -i '/^\[main\]/a install_weak_deps=False' /etc/dnf/dnf.conf

### Grow root on first boot
#
# Image is built small (disk_config/disk.toml's 1 GiB floor); growroot.service
# grows root to fill the card on every boot (no-op once maxed).
dnf5 install -y cloud-utils-growpart btrfs-progs
systemctl enable immutable-sbc-growroot.service

