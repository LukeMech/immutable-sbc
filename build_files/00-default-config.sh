#!/bin/bash

set -ouex pipefail

### Never install weak dependencies (Recommends/Supplements)
#
# Runs first so every dnf5 install below is covered -- this is what
# pulled in gnome-tour unasked.
sed -i '/^\[main\]/a install_weak_deps=False' /etc/dnf/dnf.conf

# quay.io/fedora/fedora-bootc doesn't bundle the copr plugin the way ublue-os base
# images do -- install it once here so any hook below can just `dnf5 copr enable ...`
# without repeating this itself. Removed again in final housekeeping, below.
dnf5 -y install 'dnf5-command(copr)'
dnf5 -y install --nogpgcheck --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' terra-release terra-gpg-keys

### Grow root on first boot
#
# Image is built small (disk_config/disk.toml's 1 GiB floor); growroot.service
# grows root to fill the card on every boot (no-op once maxed).
dnf5 install -y cloud-utils-growpart btrfs-progs
systemctl enable immutable-sbc-growroot.service

### zram swap
#
# zram-generator sizes zram0 itself at boot from system_files/usr/lib/systemd/
# zram-generator.conf (`ram / 2`) -- no board-specific tuning needed across
# the 4/8/16 GiB rock-5* variants. It's a generator, not a service: nothing
# to systemctl enable, the config's presence is what activates it.
dnf5 install -y zram-generator
