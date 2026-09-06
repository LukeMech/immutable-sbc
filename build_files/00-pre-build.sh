#!/bin/bash

set -ouex pipefail

### Never install weak dependencies (Recommends/Supplements)
#
# Runs first so every dnf5 install below is covered -- this is what
# pulled in gnome-tour unasked.
sed -i '/^\[main\]/a install_weak_deps=False' /etc/dnf/dnf.conf

### Every build-time-only dependency any hook (shared or variant) needs, installed once
# here instead of piecemeal per-hook. See post-build.sh for the matching removal (has
# to happen after every hook, not from its own numbered position -- see build.sh), and
# versions.env for the pinned sources these tools actually build.

# Global: needed regardless of variant -- every out-of-tree kernel module build (this
# variant's own driver hooks, plus the shared 11-coral-accelerator.sh's gasket module)
# needs kernel-devel/gcc/make, and that same shared hook's libedgetpu .deb needs
# binutils (for `ar`) to unpack.
KVER=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)
dnf5 -y install --nogpgcheck --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' terra-release terra-gpg-keys
dnf5 -y install "kernel-devel-${KVER}" gcc make binutils dnf5-plugins rpm-build

# Per-config: only what this specific variant's own hooks go on to need.
case "${VARIANT}" in
    rk3588)
        # dkms: aic8800-usb-dkms's own build (images/rk3588/build_files/10-aic8800-wifi-bt.sh).
        # cpio isn't installed/removed here even though that hook also uses it to
        # rpm2cpio-extract things -- it's a hard dependency of dracut (needed to build
        # the initramfs), so it's already present, and *removing* it later cascades
        # through dracut -> ostree -> bootc/rpm-ostree and takes bootc out with it
        # (confirmed: that's what broke `bootc container lint` in CI). Never manage
        # its lifecycle -- just use it.
        dnf5 -y install dkms
        ;;
    rpi)
        # HailoRT's CMake build (images/rpi/build_files/20-/21-hailort-*.sh).
        dnf5 -y install cmake gcc-c++ git
        ;;
esac
