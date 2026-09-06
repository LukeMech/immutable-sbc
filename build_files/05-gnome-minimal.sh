#!/bin/bash

set -ouex pipefail

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

# Gnome etc. -- minimal set of packages to get a working Gnome desktop, plus a few
# extras (loupe, papers, fastfetch, mission-center) for convenience.
dnf5 install -y \
    glibc-langpack-en \
    gdm \
    gnome-shell \
    gnome-shell-extension-appindicator \
    xdg-desktop-portal-gnome \
    xdg-user-dirs \
    NetworkManager \
    NetworkManager-wifi \
    bluez \
    \
    gnome-control-center \
    gnome-console \
    nautilus \
    loupe \
    papers \
    gnome-logs \
    \
    mission-center \
    which \
    nethogs \
    lm_sensors \
    libcap \
    \
    fastfetch \

systemctl enable gdm.service NetworkManager.service bluetooth.service lm-sensors-detect.service

# Mission Center's "Enabling Additional Values" first-run dialog wants three things set up
# (github.com/mission-center-devs/gng, platform-linux/bin/missioncenter-magpie-setup-linux):
# nethogs with extra capabilities, a powercap udev rule (system_files/etc/udev/rules.d/
# 99-powercap.rules), and lm_sensors. sensors-detect itself has to probe the *booted*
# board's real i2c/hwmon buses, not whatever this image happens to be built on, so that
# part runs at first real boot instead (system_files/usr/lib/systemd/system/
# lm-sensors-detect.service) -- nethogs' capabilities are build-host-independent, so that
# part happens here.
NETHOGS_PATH=$(command -v nethogs)
if [[ -z "${NETHOGS_PATH}" ]]; then
    echo "error: nethogs didn't install a binary onto PATH" >&2
    exit 1
fi
setcap "cap_net_admin,cap_net_raw,cap_dac_read_search,cap_sys_ptrace+pe" "${NETHOGS_PATH}"

# Default account is locked, not passworded: autologin + passwordless sudo cover it.
# Declared via sysusers.d/tmpfiles.d (not useradd, per bootc guidance); skel set below.
systemd-sysusers /usr/lib/sysusers.d/lm.conf
systemd-tmpfiles --create /usr/lib/tmpfiles.d/lm-home.conf
cp -a /etc/skel/. /var/home/lm/
chown -R lm:lm /var/home/lm
passwd -l lm

# sudoers.d requires 0440 -- git only tracks the executable bit, so it
# lands here as plain 644 and needs fixing up.
chmod 0440 /etc/sudoers.d/lm-nopasswd

# Compile dconf db from system_files/etc/dconf/db/local.d -- normally self-recompiling
# by watching the directory at runtime, which a read-only system can't do.
dconf update
