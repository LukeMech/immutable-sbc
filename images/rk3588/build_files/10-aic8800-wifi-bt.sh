#!/bin/bash

set -ouex pipefail

### AIC8800 Wi-Fi/BT driver (ROCK 5C onboard AIC8800D80 combo chip)
#
# Built directly from radxa-pkg/aic8800's USB driver tree (GPLv3, pinned commit in
# versions.env) -- same "fetch a tarball, build via Kbuild, package ourselves"
# approach as 11-coral-accelerator.sh's gasket/apex piece, no DKMS involved even
# though upstream's own Debian packaging wraps this in one (their debian/*.dkms
# files exist only for their own .deb; nothing here goes through the dkms tool).
#
# This replaces the previous ausil/aic8800-dkms COPR-based build: that source was
# Wi-Fi-only despite this hook's name, and had no pinned version/checksum at all
# (unlike everything else in versions.env). radxa-pkg/aic8800 also ships a real
# aic_btusb Bluetooth kernel module, built alongside the Wi-Fi ones below.
#
# debian/patches/ (quilt series, applied below) is NOT cosmetic -- it's the actual
# kernel-compat fixes, actively maintained per-kernel-version back to 6.1 (confirmed:
# building the raw, unpatched source against Fedora's kernel fails outright --
# implicit-declaration/incompatible-pointer-type errors in cfg80211 ops that changed
# signature in recent kernels, both fixed by fix-linux-7.1-build.patch and
# fix-linux-7.2-build.patch). Applying the whole series (not hand-picking) matches
# how upstream's own Debian packaging actually builds this, rather than us guessing
# which of the 28 patches matter.
#
# Firmware install path: TWO destinations, not one -- confirmed by reading the
# (patched) driver source directly, re-verified after applying the series above
# since fix-usb-firmware-path.patch changes this:
#   - aic8800_fdrv.ko (Wi-Fi): aicwf_compat_8800d80.c's aic_fw_path is untouched by
#     any patch, self-referential and empty by default -> resolves to
#     /lib/firmware/aic8800D80/.
#   - aic_load_fw.ko (Bluetooth/general firmware loader): aicbluetooth.c's patched
#     aic_default_fw_path -> /lib/firmware/aic8800_fw/USB/aic8800D80/, matching
#     upstream's own aic8800-firmware.install destination.
# aic_btusb.ko's own per-chip firmware path only special-cases "aic8800DC" and
# "aic8800D80N", not plain "aic8800D80" -- unverified whether that matters for BT on
# this exact chip without real hardware (this class of bug has bitten this hook
# before, see the README).

. /ctx/versions.env
KVER=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)
ARCH=$(uname -m)
KDIR="/usr/lib/modules/${KVER}/build"

TMP=$(mktemp -d)
curl -fsSL -o "${TMP}/aic8800.tar.gz" "${AIC8800_DRIVER_URL}"
echo "${AIC8800_DRIVER_SHA256}  ${TMP}/aic8800.tar.gz" | sha256sum -c -
tar -xzf "${TMP}/aic8800.tar.gz" -C "${TMP}"
SRC_DIR=$(find "${TMP}" -maxdepth 1 -iname 'aic8800-*' -type d -print -quit)
if [[ -z "${SRC_DIR}" ]]; then
    echo "error: aic8800 archive didn't extract as expected" >&2
    exit 1
fi

# Upstream's own source delivery (not our tarball step -- confirmed byte-for-byte in
# the pristine archive) has a handful of CRLF-encoded files, all Bluetooth-related,
# including one of the patches itself (fix-aic_btusb-use-bluez-by-default.patch) --
# normalize both sides to LF before patching, or `patch` fails a hunk on Fedora with
# "different line endings" even though the diff content itself is correct (confirmed
# in CI; a CRLF-tolerant patch/tar toolchain can silently mask this, which is exactly
# what let this slip through local testing here once already).
find "${SRC_DIR}/src/USB/driver_fw/drivers" "${SRC_DIR}/debian/patches" -type f -exec sed -i 's/\r$//' {} +

# Apply the whole quilt series, in order -- see the header comment for why this
# isn't optional. `patch`, not `quilt`: it's already present (rpm-build's own
# dependency), and a plain ordered `patch -p1` loop is exactly what quilt would do
# here anyway.
PATCH_SERIES="${SRC_DIR}/debian/patches/series"
if [[ ! -f "${PATCH_SERIES}" ]]; then
    echo "error: aic8800 archive didn't contain debian/patches/series" >&2
    exit 1
fi
while IFS= read -r patch_name; do
    [[ -z "${patch_name}" || "${patch_name}" == \#* ]] && continue
    patch -p1 -d "${SRC_DIR}" --no-backup-if-mismatch <"${SRC_DIR}/debian/patches/${patch_name}"
done <"${PATCH_SERIES}"

USB_DIR="${SRC_DIR}/src/USB/driver_fw"

# aic_load_fw.ko + aic8800_fdrv.ko: one Kbuild invocation builds both -- the parent
# Makefile's obj-m lines just recurse into each subdir's own Makefile.
(cd "${USB_DIR}/drivers/aic8800" && make -C "${KDIR}" M="$(pwd)" modules)

# aic_btusb.ko: a separate module with its own Makefile. KDIR override beats that
# Makefile's own `uname -r` default -- that's the build container's running
# kernel, not necessarily KVER (the target image's kernel-core).
(cd "${USB_DIR}/drivers/aic_btusb" && make "KDIR=${KDIR}" modules)

AIC_LOAD_FW_KO="${USB_DIR}/drivers/aic8800/aic_load_fw/aic_load_fw.ko"
AIC8800_FDRV_KO="${USB_DIR}/drivers/aic8800/aic8800_fdrv/aic8800_fdrv.ko"
AIC_BTUSB_KO="${USB_DIR}/drivers/aic_btusb/aic_btusb.ko"
for ko in "${AIC_LOAD_FW_KO}" "${AIC8800_FDRV_KO}" "${AIC_BTUSB_KO}"; do
    if [[ ! -f "${ko}" ]]; then
        echo "error: expected module not built: ${ko}" >&2
        exit 1
    fi
done

FW_SRC_DIR="${USB_DIR}/fw/aic8800D80"
if [[ ! -d "${FW_SRC_DIR}" ]]; then
    echo "error: aic8800 archive didn't contain src/USB/driver_fw/fw/aic8800D80" >&2
    exit 1
fi

# Stage modules + firmware into a throwaway buildroot, wrap in a minimal binary RPM
# (%prep/%build/%install empty; debug_package disabled so rpmbuild won't strip the .ko's).
BUILDROOT=$(mktemp -d)

MODULE_DIR="${BUILDROOT}/usr/lib/modules/${KVER}/extra/aic8800-usb"
install -d "${MODULE_DIR}"
install -m 644 "${AIC_LOAD_FW_KO}" "${AIC8800_FDRV_KO}" "${AIC_BTUSB_KO}" "${MODULE_DIR}/"

# Two destinations, not one -- see the header comment: aic8800_fdrv.ko (Wi-Fi) and
# aic_load_fw.ko (Bluetooth) resolve different base paths for the same firmware set.
FW_DIR_WIFI="${BUILDROOT}/usr/lib/firmware/aic8800D80"
FW_DIR_BT="${BUILDROOT}/usr/lib/firmware/aic8800_fw/USB/aic8800D80"
install -d "${FW_DIR_WIFI}" "${FW_DIR_BT}"
cp -a "${FW_SRC_DIR}/." "${FW_DIR_WIFI}/"
cp -a "${FW_SRC_DIR}/." "${FW_DIR_BT}/"

# Matches upstream's own Debian packaging (its Makefile's `install:` target does the
# same) -- unlike aic_load_fw/aic8800_fdrv, which both carry a real
# MODULE_DEVICE_TABLE(usb, ...) and autoload fine via modalias, aic_btusb doesn't
# reliably autoload on every platform, so it needs an explicit nudge.
MODLOAD_DIR="${BUILDROOT}/usr/lib/modules-load.d"
install -d "${MODLOAD_DIR}"
echo "aic_btusb" > "${MODLOAD_DIR}/aic_bt.conf"

SPEC=$(mktemp --suffix=.spec)
cat > "${SPEC}" <<EOF
%global debug_package %{nil}
%global __os_install_post %{nil}

Name: kmod-aic8800-usb
Version: ${AIC8800_DRIVER_VERSION}
Release: 1
Summary: AIC8800D80 Wi-Fi/BT USB kernel modules and firmware for ${KVER}
License: GPLv3
BuildArch: ${ARCH}

%description
aic_load_fw.ko and aic8800_fdrv.ko (Wi-Fi), plus aic_btusb.ko (Bluetooth) and the
firmware all three load at runtime, built from radxa-pkg/aic8800's USB driver tree
for the onboard AIC8800D80 combo chip -- downloaded and built directly, never
installed via upstream's own Debian/DKMS packaging.

%files
/usr/lib/modules/${KVER}/extra/aic8800-usb
/usr/lib/firmware/aic8800D80
/usr/lib/firmware/aic8800_fw
/usr/lib/modules-load.d/aic_bt.conf

%post
depmod -a ${KVER}

%postun
depmod -a ${KVER}
EOF

TOPDIR=$(mktemp -d)
rpmbuild -bb --define "_topdir ${TOPDIR}" --buildroot "${BUILDROOT}" "${SPEC}"

RPM_PATH=$(find "${TOPDIR}/RPMS" -iname "kmod-aic8800-usb-${AIC8800_DRIVER_VERSION}*.rpm" -print -quit)
if [[ -z "${RPM_PATH}" ]]; then
    echo "error: rpmbuild didn't produce kmod-aic8800-usb-${AIC8800_DRIVER_VERSION} under ${TOPDIR}/RPMS" >&2
    exit 1
fi

dnf5 -y install "${RPM_PATH}"

# Fail the build (rather than ship silently without Wi-Fi/BT) if anything is missing.
rpm -q kmod-aic8800-usb
find "/usr/lib/modules/${KVER}" -iname 'aic_load_fw.ko*' -print | grep -q .
find "/usr/lib/modules/${KVER}" -iname 'aic8800_fdrv.ko*' -print | grep -q .
find "/usr/lib/modules/${KVER}" -iname 'aic_btusb.ko*' -print | grep -q .
grep -q 'aic8800_fdrv' "/usr/lib/modules/${KVER}/modules.dep"
find "/usr/lib/firmware/aic8800D80" -type f | grep -q .
find "/usr/lib/firmware/aic8800_fw/USB/aic8800D80" -type f | grep -q .
[[ -f "/usr/lib/firmware/aic8800D80/fw_patch_table_8800d80_u02.bin" ]]
[[ -f "/usr/lib/firmware/aic8800_fw/USB/aic8800D80/fw_patch_table_8800d80_u02.bin" ]]

rm -rf "${TMP}" "${BUILDROOT}" "${TOPDIR}"
