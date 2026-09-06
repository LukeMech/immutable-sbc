#!/bin/bash

set -ouex pipefail

### Hailo-8/8L PCIe NPU driver (Raspberry Pi AI HAT+/AI Kit -- optional add-on hardware)
#
# Built from hailo-ai/hailort-drivers (hailo8 branch, GPL-2.0, pinned commit -- no DKMS/COPR
# needed, its Makefile builds a plain out-of-tree module directly) into our own
# self-contained "kmod-hailo8-pci" rpm, same reasoning as kmod-aic8800-usb: no bare files,
# no runtime dependency on build-time-only packages surviving into the image.
#
# Driver + firmware only. Nothing else in this image can use the chip yet: Hailo has no
# standard TFLite delegate (confirmed -- there's an open upstream request for one, still
# unresolved), so npu-run can't drive it, and HailoRT (the userspace runtime that could)
# isn't installed here. This just gets /dev/hailo_chardev to exist when a HAT is attached.

. /ctx/versions.env
DRIVER_VERSION="${HAILO8_DRIVER_VERSION}"
DRIVER_COMMIT="${HAILO8_DRIVER_COMMIT}"

KVER=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)
ARCH=$(uname -m)

TMP=$(mktemp -d)

curl -fsSL -o "${TMP}/drivers.tar.gz" "${HAILO8_DRIVER_URL}"
echo "${HAILO8_DRIVER_SHA256}  ${TMP}/drivers.tar.gz" | sha256sum -c -
tar -xzf "${TMP}/drivers.tar.gz" -C "${TMP}"
SRC_DIR=$(find "${TMP}" -maxdepth 1 -iname 'hailort-drivers-*' -type d -print -quit)
if [[ -z "${SRC_DIR}" ]]; then
    echo "error: hailort-drivers archive didn't extract as expected" >&2
    exit 1
fi

curl -fsSL -o "${TMP}/hailo8_fw.bin" "${HAILO8_FW_URL}"
echo "${HAILO8_FW_SHA256}  ${TMP}/hailo8_fw.bin" | sha256sum -c -

# Direct Kbuild target, not `make install_dkms` -- we're building once for a fixed,
# already-known kernel, not registering for future kernel updates on this throwaway
# build container.
make -C "${SRC_DIR}/linux/pcie" "kernelver=${KVER}" all

KO_PATH=$(find "${SRC_DIR}/linux/pcie/build" -iname 'hailo_pci.ko' -print -quit)
if [[ -z "${KO_PATH}" ]]; then
    echo "error: driver build didn't produce hailo_pci.ko" >&2
    exit 1
fi

RPM_NAME="kmod-hailo8-pci"
BUILDROOT=$(mktemp -d)

MODULE_DIR="${BUILDROOT}/usr/lib/modules/${KVER}/extra/hailo8_pci"
install -d "${MODULE_DIR}"
install -m 644 "${KO_PATH}" "${MODULE_DIR}/"

FW_DIR="${BUILDROOT}/usr/lib/firmware/hailo"
install -d "${FW_DIR}"
install -m 644 "${TMP}/hailo8_fw.bin" "${FW_DIR}/hailo8_fw.bin"

UDEV_DIR="${BUILDROOT}/usr/lib/udev/rules.d"
install -d "${UDEV_DIR}"
install -m 644 "${SRC_DIR}/linux/pcie/51-hailo-udev.rules" "${UDEV_DIR}/"

SPEC=$(mktemp --suffix=.spec)
cat >"${SPEC}" <<EOF
%global debug_package %{nil}
%global __os_install_post %{nil}

Name: ${RPM_NAME}
Version: ${DRIVER_VERSION}
Release: 1
Summary: Hailo-8/8L PCIe NPU kernel driver and firmware for ${KVER}
License: GPLv2
BuildArch: ${ARCH}

%description
Prebuilt hailo_pci kernel module, firmware and udev rule for ${KVER} -- the optional
Hailo-8/8L accelerator on a Raspberry Pi AI HAT+/AI Kit. Built from
hailo-ai/hailort-drivers (commit ${DRIVER_COMMIT}).

%files
/usr/lib/modules/${KVER}/extra/hailo8_pci
/usr/lib/firmware/hailo/hailo8_fw.bin
/usr/lib/udev/rules.d/51-hailo-udev.rules

%post
depmod -a ${KVER}

%postun
depmod -a ${KVER}
EOF

TOPDIR=$(mktemp -d)
rpmbuild -bb --define "_topdir ${TOPDIR}" --buildroot "${BUILDROOT}" "${SPEC}"

RPM_PATH=$(find "${TOPDIR}/RPMS" -iname "${RPM_NAME}-${DRIVER_VERSION}*.rpm" -print -quit)
if [[ -z "${RPM_PATH}" ]]; then
    echo "error: rpmbuild didn't produce ${RPM_NAME}-${DRIVER_VERSION} under ${TOPDIR}/RPMS" >&2
    exit 1
fi

dnf5 -y install "${RPM_PATH}"

# Fail the build rather than ship silently without the driver/firmware.
rpm -q "${RPM_NAME}"
find "/usr/lib/modules/${KVER}" -iname 'hailo_pci.ko*' -print | grep -q .
[[ -f /usr/lib/firmware/hailo/hailo8_fw.bin ]]

rm -rf "${TMP}" "${BUILDROOT}" "${TOPDIR}"
