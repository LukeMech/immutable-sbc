#!/bin/bash

set -ouex pipefail

### Minimal GNOME desktop
#
# A small, Wayland-only GNOME session: shell, settings, a file manager,
# a terminal, a text editor and a browser. No games, no extra bundled
# GNOME apps (Maps, Weather, Contacts, etc.), no Flatpak/Flathub, no
# gnome-initial-setup wizard -- a single baked-in account (below) logs
# straight into GDM instead.

dnf5 install -y \
    --exclude=gnome-tour \
    dconf \
    gdm \
    gnome-shell \
    gnome-control-center \
    gnome-console \
    gnome-text-editor \
    gnome-shell-extension-appindicator \
    nautilus \
    xdg-desktop-portal-gnome \
    xdg-user-dirs \
    firefox \
    NetworkManager \
    NetworkManager-wifi \
    bluez

systemctl enable gdm.service
systemctl enable NetworkManager.service
systemctl enable bluetooth.service

dnf5 install -y \
    screenfetch \
    btop

# Keep btop's binary/package intact (still runnable from a terminal) but
# drop it out of the GNOME Shell app grid -- it's a TUI tool, not
# something meant to be launched as a windowed app.
BTOP_DESKTOP=$(find /usr/share/applications -maxdepth 1 -iname 'btop*.desktop' -print -quit)
if [[ -z "${BTOP_DESKTOP}" ]]; then
    echo "error: btop didn't ship a .desktop file under /usr/share/applications" >&2
    exit 1
fi
echo 'NoDisplay=true' >> "${BTOP_DESKTOP}"

# Baked-in default account -- there's no gnome-initial-setup wizard to
# create one on first boot. Known, fixed credentials by design (this is
# a personal SBC image, not a multi-user/shared deployment); change the
# password after first login if that assumption stops holding.
#
# The account itself is declared in system_files/usr/lib/sysusers.d/lm.conf
# and its home directory in system_files/usr/lib/tmpfiles.d/lm-home.conf,
# not `useradd` -- per bootc's own guidance
# (https://bootc.dev/bootc/building/users-and-groups.html), systemd-sysusers
# is what reconciles /etc/passwd on every boot instead of relying only on
# what got baked in at build time once. Applied now so the account/home
# dir exist immediately in this build too, not just from the first boot
# onward. Neither sysusers nor tmpfiles set a password or populate skel,
# so that's still done explicitly here.
systemd-sysusers /usr/lib/sysusers.d/lm.conf
systemd-tmpfiles --create /usr/lib/tmpfiles.d/lm-home.conf
cp -a /etc/skel/. /var/home/lm/
chown -R lm:lm /var/home/lm
echo 'lm:0000' | chpasswd

# Compile system_files/etc/dconf/db/local.d's power settings (never
# blank/suspend) into the binary db dconf actually reads. dconf would
# normally recompile this itself on changes to local.d, but that relies
# on watching the directory at runtime -- this is a read-only deployed
# system, so it has to be baked in at build time instead.
dconf update
