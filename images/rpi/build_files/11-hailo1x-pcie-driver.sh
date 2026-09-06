#!/bin/bash

set -ouex pipefail

### Hailo-10H/15 PCIe driver (Raspberry Pi AI HAT+ 2 -- optional add-on hardware)
#
# Separate chip generation from 10-hailo8-pcie-driver.sh's Hailo-8/8L: different module
# (hailo1x_pci vs hailo_pci), different device (/dev/h1x-N vs /dev/hailoN), different
# upstream branch (hailort-drivers' master, not hailo8 -- frozen at v4.24.0 for Hailo-8).
# Same packaging approach otherwise: pinned commit, self-contained kmod rpm, no
# TFLite/npu-run integration (see that file's header for why).
#
# Firmware here is a full U-Boot+kernel+rootfs bundle (the Hailo-10H runs its own
# embedded OS for on-chip LLM/VLM inference) -- ~38 MiB download, ~115 MiB installed
# (image-fs alone is ~100 MiB uncompressed), vs Hailo-8's ~150 KiB blob.

. /ctx/versions.env
DRIVER_VERSION="${HAILO1X_DRIVER_VERSION}"
DRIVER_COMMIT="${HAILO1X_DRIVER_COMMIT}"

KVER=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)
ARCH=$(uname -m)

TMP=$(mktemp -d)

curl -fsSL -o "${TMP}/drivers.tar.gz" "${HAILO1X_DRIVER_URL}"
echo "${HAILO1X_DRIVER_SHA256}  ${TMP}/drivers.tar.gz" | sha256sum -c -
tar -xzf "${TMP}/drivers.tar.gz" -C "${TMP}"
SRC_DIR=$(find "${TMP}" -maxdepth 1 -iname 'hailort-drivers-*' -type d -print -quit)
if [[ -z "${SRC_DIR}" ]]; then
    echo "error: hailort-drivers archive didn't extract as expected" >&2
    exit 1
fi

# Flat archive (files at its root) -- extracted straight into hailo/hailo10h/, matching
# the "hailo/hailo10h/<name>" paths the driver requests (common/pcie_common.c's
# hailo10h_files_stg{1,2,3} tables). Includes every u-boot-<N>.dtb.signed variant since
# the driver substitutes a board-specific "%s" we can't predict -- upstream's own
# download script doesn't filter these either.
curl -fsSL -o "${TMP}/hailo10h_fw.tar.gz" "${HAILO1X_FW_URL}"
echo "${HAILO1X_FW_SHA256}  ${TMP}/hailo10h_fw.tar.gz" | sha256sum -c -
FW_EXTRACT="${TMP}/hailo10h_fw"
mkdir -p "${FW_EXTRACT}"
tar -xzf "${TMP}/hailo10h_fw.tar.gz" -C "${FW_EXTRACT}"

make -C "${SRC_DIR}/linux/pcie" "kernelver=${KVER}" all

KO_PATH=$(find "${SRC_DIR}/linux/pcie/build" -iname 'hailo1x_pci.ko' -print -quit)
if [[ -z "${KO_PATH}" ]]; then
    echo "error: driver build didn't produce hailo1x_pci.ko" >&2
    exit 1
fi

RPM_NAME="kmod-hailo1x-pci"
BUILDROOT=$(mktemp -d)

MODULE_DIR="${BUILDROOT}/usr/lib/modules/${KVER}/extra/hailo1x_pci"
install -d "${MODULE_DIR}"
install -m 644 "${KO_PATH}" "${MODULE_DIR}/"

FW_DIR="${BUILDROOT}/usr/lib/firmware/hailo/hailo10h"
install -d "${FW_DIR}"
cp -a "${FW_EXTRACT}"/. "${FW_DIR}/"

# No udev rule ships upstream for this branch (hailo8's 51-hailo-udev.rules is
# hailo8-branch-only) -- same MODE=0666 intent, against this chip's own class name
# (class_create_compat("hailo1x") in src/pcie.c).
UDEV_DIR="${BUILDROOT}/usr/lib/udev/rules.d"
install -d "${UDEV_DIR}"
cat >"${UDEV_DIR}/51-hailo1x-udev.rules" <<'EOF'
# Change mode rules for Hailo's PCIe driver (Hailo-10H/15)
SUBSYSTEM=="hailo1x", MODE="0666"
EOF

SPEC=$(mktemp --suffix=.spec)
cat >"${SPEC}" <<EOF
%global debug_package %{nil}
%global __os_install_post %{nil}

Name: ${RPM_NAME}
Version: ${DRIVER_VERSION}
Release: 1
Summary: Hailo-10H/15 PCIe driver and firmware for ${KVER}
License: GPLv2
BuildArch: ${ARCH}

%description
Prebuilt hailo1x_pci kernel module, firmware and udev rule for ${KVER} -- the optional
Hailo-10H accelerator on a Raspberry Pi AI HAT+ 2. Built from
hailo-ai/hailort-drivers (commit ${DRIVER_COMMIT}).

%files
/usr/lib/modules/${KVER}/extra/hailo1x_pci
/usr/lib/firmware/hailo/hailo10h
/usr/lib/udev/rules.d/51-hailo1x-udev.rules

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
find "/usr/lib/modules/${KVER}" -iname 'hailo1x_pci.ko*' -print | grep -q .
[[ -f /usr/lib/firmware/hailo/hailo10h/image-fs ]]
[[ -f /usr/lib/firmware/hailo/hailo10h/fitImage ]]
[[ -f /usr/lib/firmware/hailo/hailo10h/customer_certificate.bin ]]
[[ -f /usr/lib/firmware/hailo/hailo10h/scu_fw.bin ]]
find /usr/lib/firmware/hailo/hailo10h -iname 'u-boot-*.dtb.signed' -print | grep -q .

rm -rf "${TMP}" "${BUILDROOT}" "${TOPDIR}"
