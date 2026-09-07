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
        # Nothing extra -- both this variant's own hooks (10-aic8800-wifi-bt.sh,
        # 20-mesa-teflon.sh) build straight from a Kbuild tree or install a repo
        # package, covered by the global kernel-devel/gcc/make above already.
        ;;
    rpi)
        # HailoRT's build (images/rpi/build_files/20-/21-hailort-*.sh) -- gcc-c++ for
        # the C++ library itself, git for FetchContent's git-clone of its bundled deps
        # (protobuf, spdlog, cli11, ...). python3-devel is 30-hailo-npu-run.sh's own --
        # building hailo_platform's pybind11 extension needs Python.h, which the shared
        # 10-prepare-npu-run-module.sh's plain python3/pip/numpy/pillow install doesn't
        # pull in. Not cmake: those hooks vendor their own pinned build instead of using
        # Fedora's, see their own comments for why. patchelf is 30-hailo-npu-run.sh's own
        # -- see its comment for why the RPATH has to be fixed up after the fact instead
        # of through CMake.
        dnf5 -y install gcc-c++ git python3-devel patchelf
        ;;
esac
