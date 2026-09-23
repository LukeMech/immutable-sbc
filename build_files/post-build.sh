#!/bin/bash

set -ouex pipefail


# nfs-utils comes from the base fedora-bootc image, not anything installed above (no
# package here Requires it -- checked). Its rpc.statd tries to init its state directory
# at every boot and fails (confirmed: "Failed to create /var/lib/nfs/statd/.state.new:
# No such file or directory"). This appliance never does a kernel-level NFS mount;
# Nautilus's own NFS browsing goes through gvfs's userspace libnfs backend instead, so
# just remove the package rather than mask its services around it.
dnf5 -y remove nfs-utils

dnf5 -y remove terra-release terra-gpg-keys

# linux-firmware's main package only *Recommends* every one of these per-vendor
# firmware sub-packages (confirmed in its spec) -- but Recommends still gets pulled
# in by whatever built the base fedora-bootc:44 image itself, before this image's own
# 00-pre-build.sh ever sets install_weak_deps=False, so that setting can't stop them.
# None of these vendors' hardware exists on either board this repo targets (rpi:
# Broadcom Wi-Fi only; rk3588: aic8800, built from source in images/deps/ instead --
# see images/boards.toml's own brcm/ comment and images/rk3588/build_files/
# 10-aic8800-wifi-bt.sh). Each one only Requires linux-firmware-whence (checked, same
# spec), not the other way around, so removing them doesn't cascade into removing
# anything real -- brcmfmac-firmware (rpi's actual onboard Wi-Fi) stays installed.
dnf5 -y remove \
    amd-gpu-firmware \
    amd-ucode-firmware \
    atheros-firmware \
    cirrus-audio-firmware \
    intel-audio-firmware \
    intel-gpu-firmware \
    mt7xxx-firmware \
    nvidia-gpu-firmware \
    nxpwireless-firmware \
    qcom-wwan-firmware \
    realtek-firmware \
    tiwilink-firmware \
    intel-npu-firmware

# Same base-image-baked-in-before-our-own-dnf.conf-edit story as the firmware removal
# above -- vim-minimal (Provides: vi) isn't installed by anything in this repo, comes
# from fedora-bootc:44 itself. nano already covers this image's only editing need
# (base image ships it too), so drop vim rather than keep two.
dnf5 -y remove vim-minimal

### Final cleanup: every COPR repo any hook enabled, every build-time-only dependency
# 00-pre-build.sh installed, and the dnf cache -- all build-time-only convenience,
# none of it should survive into the final image.
#
# Not picked up by either hook loop in build.sh -- invoked explicitly there, after
# every hook (shared and variant) has already run. The shared build_files/*.sh loop
# finishes in full before the variant loop even starts, so a shared "99-"-style hook
# picked up by that loop's own glob would still run before any variant hook, not after
# -- hence invoking this explicitly instead.
#
# `copr remove` (unlike `disable`) cleans up the .repo file and imported GPG key, and
# must run before the plugin package providing it is removed. Repo id is the standard
# `_copr:<host>:<owner>:<project>.repo` naming, so owner/project comes straight back
# out of the filename rather than needing each hook to report what it enabled.
shopt -s nullglob
for repo_file in /etc/yum.repos.d/_copr:*.repo; do
    project=$(basename "${repo_file}" .repo | cut -d: -f3-4 --output-delimiter=/)
    dnf5 -y copr remove "${project}"
done

KVER=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)

# Belt-and-braces: catches anything the explicit removes above still left orphaned
# (a no-op if they didn't).
dnf5 -y autoremove

# One explicit initramfs rebuild, now that the kernel (00-pre-build.sh) and every
# kmod (every hook above it) are already in their final state -- matches the
# confirmed ublue-os/bazzite + ublue-os/ucore pattern of a single, final `dracut -f`
# rather than letting it fire (or not, since it's shimmed off during the kernel
# swap) once per package. --add ostree: required for an ostree/bootc root to boot at
# all, not optional.
#
# Expect a wall of "cp: setting attributes ... Operation not supported" /
# "dracut-install: ERROR: installing '...'" noise here (e.g. for /root) -- that's
# dracut-install's xattr-preserving cp failing on the container build's own overlayfs
# layer, not a real failure. Confirmed non-fatal upstream (a Fedora bootc maintainer:
# "They should not block the build", https://gitlab.com/fedora/bootc/tracker/-/issues/66;
# same verbatim errors reported at
# https://discussion.fedoraproject.org/t/errors-when-running-dracut-in-bootc-container-build/156626).
# Still open/unresolved upstream as of 2025-08 -- nothing to fix on this end.
dracut --no-hostonly --kver "${KVER}" --reproducible --add ostree -f \
    "/usr/lib/modules/${KVER}/initramfs.img"

# Final housekeeping
dnf5 -y clean all
