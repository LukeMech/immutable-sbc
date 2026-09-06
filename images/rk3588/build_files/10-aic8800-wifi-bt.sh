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
# Firmware install path (/usr/lib/firmware/aic8800D80/) confirmed by reading the
# driver source directly, not copied from upstream's own Debian packaging (which
# installs elsewhere) or the previous COPR-based path here -- both
# aic8800_fdrv/aicwf_compat_8800d80.c's aic_fw_path handling and
# aic_load_fw/aicbluetooth.c's aic_default_fw_path fallback resolve to
# /lib/firmware/aic8800D80/ for the D80 chip, on this exact pinned source revision.
# If the pinned commit ever moves, re-check this before assuming it still holds.

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

FW_DIR="${BUILDROOT}/usr/lib/firmware/aic8800D80"
install -d "${FW_DIR}"
cp -a "${FW_SRC_DIR}/." "${FW_DIR}/"

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
[[ -f "/usr/lib/firmware/aic8800D80/fw_patch_table_8800d80_u02.bin" ]]

rm -rf "${TMP}" "${BUILDROOT}" "${TOPDIR}"
