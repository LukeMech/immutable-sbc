#!/bin/bash

set -ouex pipefail

dnf5 install -y \
    glibc-langpack-en \
    geoclue2 \
    gdm \
    gnome-shell \
    gnome-control-center \
    gnome-console \
    gnome-shell-extension-appindicator \
    nautilus \
    xdg-desktop-portal-gnome \
    xdg-user-dirs \
    NetworkManager \
    NetworkManager-wifi \
    bluez \

systemctl enable gdm.service
systemctl enable NetworkManager.service
systemctl enable bluetooth.service

dnf5 install -y \
    screenfetch \
    btop

# Hide btop from the app grid -- it's a TUI tool, still usable from a
# terminal, just not meant to be launched as a windowed app.
BTOP_DESKTOP=$(find /usr/share/applications -maxdepth 1 -iname 'btop*.desktop' -print -quit)
if [[ -z "${BTOP_DESKTOP}" ]]; then
    echo "error: btop didn't ship a .desktop file under /usr/share/applications" >&2
    exit 1
fi
echo 'NoDisplay=true' >> "${BTOP_DESKTOP}"

# Baked-in default account -- no gnome-initial-setup wizard, no
# multi-user setup. Locked instead of given a password: GDM autologin
# (system_files/etc/gdm/custom.conf) + passwordless sudo
# (system_files/etc/sudoers.d/lm-nopasswd) mean nothing ever needs one.
#
# Declared via sysusers.d/tmpfiles.d (system_files/usr/lib/...), not
# `useradd`, per bootc's own guidance (systemd-sysusers reconciles
# /etc/passwd every boot). Applied now too so the account/home dir exist
# in this build already; neither sets a password or populates skel, so
# that's still explicit here.
systemd-sysusers /usr/lib/sysusers.d/lm.conf
systemd-tmpfiles --create /usr/lib/tmpfiles.d/lm-home.conf
cp -a /etc/skel/. /var/home/lm/
chown -R lm:lm /var/home/lm
passwd -l lm

# sudoers.d requires 0440 -- git only tracks the executable bit, so it
# lands here as plain 644 and needs fixing up.
chmod 0440 /etc/sudoers.d/lm-nopasswd

# Compile system_files/etc/dconf/db/local.d into the binary db dconf
# reads -- normally self-recompiling, but that relies on watching the
# directory at runtime, which a read-only deployed system can't do.
dconf update
