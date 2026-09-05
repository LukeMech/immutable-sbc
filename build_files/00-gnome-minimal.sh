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
    screenfetch \
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

# Baked-in default account -- there's no gnome-initial-setup wizard to
# create one on first boot. Known, fixed credentials by design (this is
# a personal SBC image, not a multi-user/shared deployment); change the
# password after first login if that assumption stops holding.
useradd -m -G wheel lm
echo 'lm:0000' | chpasswd
