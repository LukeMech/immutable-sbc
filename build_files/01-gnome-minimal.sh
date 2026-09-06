#!/bin/bash

set -ouex pipefail

dnf5 -y install --nogpgcheck --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' terra-release terra-gpg-keys

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
    baobab \
    gnome-logs \
    mission-center \
    fastfetch

systemctl enable gdm.service
systemctl enable NetworkManager.service
systemctl enable bluetooth.service

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
