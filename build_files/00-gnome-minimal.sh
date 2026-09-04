#!/bin/bash

set -ouex pipefail

### Minimal GNOME desktop
#
# A small, Wayland-only GNOME session: shell, settings, a file manager,
# a terminal, a text editor and a browser. No games, no extra bundled
# GNOME apps (Maps, Weather, Contacts, etc.) -- those are meant to come
# from Flathub if/when the user wants them.
#
# gnome-initial-setup runs GDM's first-boot account creation wizard so
# no default user/password is baked into the image.

dnf5 install -y \
    gdm \
    gnome-shell \
    gnome-initial-setup \
    gnome-control-center \
    gnome-console \
    gnome-text-editor \
    gnome-shell-extension-appindicator \
    nautilus \
    xdg-desktop-portal-gnome \
    xdg-user-dirs \
    firefox \
    flatpak \
    NetworkManager \
    NetworkManager-wifi \
    bluez

systemctl enable gdm.service
systemctl enable NetworkManager.service
systemctl enable bluetooth.service
