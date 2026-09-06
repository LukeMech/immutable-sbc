#!/bin/bash

set -ouex pipefail

dnf5 install -y \
    glibc-langpack-en \
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

# fastfetch, not screenfetch: screenfetch is broken on real hardware (garbled
# CPU/disk fields) and unmaintained; fastfetch resolves both correctly.
dnf5 install -y \
    fastfetch \
    btop \
    chafa

# Hide btop from the app grid -- it's a TUI tool, still usable from a
# terminal, just not meant to be launched as a windowed app.
BTOP_DESKTOP=$(find /usr/share/applications -maxdepth 1 -iname 'btop*.desktop' -print -quit)
if [[ -z "${BTOP_DESKTOP}" ]]; then
    echo "error: btop didn't ship a .desktop file under /usr/share/applications" >&2
    exit 1
fi
echo 'NoDisplay=true' >> "${BTOP_DESKTOP}"

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
