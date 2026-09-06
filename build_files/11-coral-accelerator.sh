#!/bin/bash

set -ouex pipefail

### Coral accelerator support -- two independent pieces, for two different Coral
# products, both shared across every variant/board (Coral is a USB/PCIe peripheral,
# not a property of any board). Pinned sources/checksums live in versions.env.

. /ctx/versions.env
ARCH=$(uname -m)

## 1. libedgetpu (Coral USB Accelerator runtime)
#
# No Fedora/COPR package exists -- upstream (google-coral/libedgetpu) only builds via
# Bazel, no prebuilt RPM anywhere. Google's own apt repo ships a prebuilt aarch64 .deb
# of the same Apache-2.0 binary though, so this unpacks that rather than building from
# source.
#
# USB-only: the USB Accelerator talks over libusb (Depends: libusb-1.0-0 in the .deb's
# own control file), no kernel driver involved -- unlike the PCIe/M.2 Coral module
# below, which needs the gasket/apex modules instead.

dnf5 -y install libusb1

TMP=$(mktemp -d)
curl -fsSL -o "${TMP}/libedgetpu1-std.deb" "${LIBEDGETPU_DEB_URL}"
echo "${LIBEDGETPU_DEB_SHA256}  ${TMP}/libedgetpu1-std.deb" | sha256sum -c -

# .deb = an ar archive of debian-binary + control.tar.gz + data.tar.xz -- only the
# latter has real files (the shared lib + a udev rule). `ar` itself comes from
# 00-pre-build.sh's global binutils install.
(cd "${TMP}" && ar x libedgetpu1-std.deb data.tar.xz)
mkdir -p "${TMP}/data"
tar -xJf "${TMP}/data.tar.xz" -C "${TMP}/data"

LIB_SRC=$(find "${TMP}/data" -iname 'libedgetpu.so.1.0' -type f -print -quit)
if [[ -z "${LIB_SRC}" ]]; then
    echo "error: libedgetpu.so.1.0 not found in the downloaded .deb" >&2
    exit 1
fi

EDGETPU_BUILDROOT=$(mktemp -d)

LIB_DIR="${EDGETPU_BUILDROOT}/usr/lib64"
install -d "${LIB_DIR}"
install -m 755 "${LIB_SRC}" "${LIB_DIR}/libedgetpu.so.1.0"
ln -s libedgetpu.so.1.0 "${LIB_DIR}/libedgetpu.so.1"

# Same USB vendor/product IDs as upstream's own udev rule (60-libedgetpu1-std.rules) --
# MODE=0666 instead of its GROUP="plugdev" (Fedora has no plugdev group; matches this
# repo's own convention for device permissions, see the Hailo/gasket udev rules below).
EDGETPU_UDEV_DIR="${EDGETPU_BUILDROOT}/usr/lib/udev/rules.d"
install -d "${EDGETPU_UDEV_DIR}"
cat >"${EDGETPU_UDEV_DIR}/60-libedgetpu1-std.rules" <<'EOF'
SUBSYSTEM=="usb",ATTRS{idVendor}=="1a6e",ATTRS{idProduct}=="089a",MODE="0666"
SUBSYSTEM=="usb",ATTRS{idVendor}=="18d1",ATTRS{idProduct}=="9302",MODE="0666"
EOF

EDGETPU_SPEC=$(mktemp --suffix=.spec)
cat >"${EDGETPU_SPEC}" <<EOF
%global debug_package %{nil}
%global __os_install_post %{nil}

Name: libedgetpu1-std
Version: ${LIBEDGETPU_VERSION}
Release: 1
Summary: Edge TPU runtime library for the Coral USB Accelerator
License: Apache-2.0
BuildArch: ${ARCH}
Requires: libusb1

%description
libedgetpu.so.1, unpacked from Google's own prebuilt arm64 .deb
(packages.cloud.google.com/apt, coral-edgetpu-stable) -- no Fedora package or source
RPM exists; upstream only builds via Bazel.

%files
/usr/lib64/libedgetpu.so.1.0
/usr/lib64/libedgetpu.so.1
/usr/lib/udev/rules.d/60-libedgetpu1-std.rules
EOF

EDGETPU_TOPDIR=$(mktemp -d)
rpmbuild -bb --define "_topdir ${EDGETPU_TOPDIR}" --buildroot "${EDGETPU_BUILDROOT}" "${EDGETPU_SPEC}"

EDGETPU_RPM_PATH=$(find "${EDGETPU_TOPDIR}/RPMS" -iname "libedgetpu1-std-${LIBEDGETPU_VERSION}*.rpm" -print -quit)
if [[ -z "${EDGETPU_RPM_PATH}" ]]; then
    echo "error: rpmbuild didn't produce libedgetpu1-std-${LIBEDGETPU_VERSION} under ${EDGETPU_TOPDIR}/RPMS" >&2
    exit 1
fi

dnf5 -y install "${EDGETPU_RPM_PATH}"

# Fail the build rather than ship silently without the library.
rpm -q libedgetpu1-std
[[ -f /usr/lib64/libedgetpu.so.1.0 ]]
[[ -L /usr/lib64/libedgetpu.so.1 ]]

rm -rf "${TMP}" "${EDGETPU_BUILDROOT}" "${EDGETPU_TOPDIR}"

## 2. Coral Gasket/Apex PCIe driver (M.2/mini-PCIe Coral Accelerator module -- a
## separate, optional product from the USB Accelerator above)
#
# kylegospo/gasket-dkms (GPL-2.0, pinned commit) rather than google/gasket-driver
# directly -- it's the same source plus active modern-kernel compatibility fixes
# (6.8+/6.13+, RHEL/Fedora preprocessor quirks) google's own repo hasn't picked up
# since 2024. Its own COPR only publishes x86_64 builds, but the source itself has
# nothing architecture-specific -- built here the same self-contained-rpm way as the
# Hailo/AIC8800 drivers instead of relying on that COPR.
#
# gasket.ko is a support library apex.ko calls into (EXPORT_SYMBOL, not a separate
# device) -- both ship in one kmod-coral-gasket rpm; the kernel resolves the
# dependency and loads gasket automatically when apex is probed.

KVER=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)

GASKET_TMP=$(mktemp -d)
curl -fsSL -o "${GASKET_TMP}/gasket-dkms.tar.gz" "${GASKET_DRIVER_URL}"
echo "${GASKET_DRIVER_SHA256}  ${GASKET_TMP}/gasket-dkms.tar.gz" | sha256sum -c -
tar -xzf "${GASKET_TMP}/gasket-dkms.tar.gz" -C "${GASKET_TMP}"
GASKET_SRC_DIR=$(find "${GASKET_TMP}" -maxdepth 1 -iname 'gasket-dkms-*' -type d -print -quit)
if [[ -z "${GASKET_SRC_DIR}" ]]; then
    echo "error: gasket-dkms archive didn't extract as expected" >&2
    exit 1
fi

# Direct Kbuild target (KERNEL_SOURCE_DIR override beats the Makefile's own `uname -r`
# default), not DKMS -- same reasoning as the Hailo hooks: one fixed-kernel build here,
# not a registration for future kernel updates on this throwaway build container.
#
# cd + plain `make`, not `make -C` -- this Makefile's `all` target passes M="$(PWD)" to
# the kernel build, and $(PWD) is the *environment* variable make inherited from the
# invoking shell, not the directory `-C` chdirs into (confirmed: `-C` alone left it
# pointing at build.sh's own cwd, "/", so the kernel build tried to compile "/" as the
# module source and failed -- "Makefile: No such file or directory"). A real `cd` fixes
# the environment PWD before make ever reads the Makefile. The Hailo driver hooks don't
# need this: their Makefile recomputes PWD itself via `PWD := $(shell pwd)`.
(cd "${GASKET_SRC_DIR}/src" && make "KERNEL_SOURCE_DIR=/usr/lib/modules/${KVER}/build" all)

GASKET_KO=$(find "${GASKET_SRC_DIR}/src" -iname 'gasket.ko' -print -quit)
APEX_KO=$(find "${GASKET_SRC_DIR}/src" -iname 'apex.ko' -print -quit)
if [[ -z "${GASKET_KO}" || -z "${APEX_KO}" ]]; then
    echo "error: driver build didn't produce both gasket.ko and apex.ko" >&2
    exit 1
fi

GASKET_BUILDROOT=$(mktemp -d)

GASKET_MODULE_DIR="${GASKET_BUILDROOT}/usr/lib/modules/${KVER}/extra/coral-gasket"
install -d "${GASKET_MODULE_DIR}"
install -m 644 "${GASKET_KO}" "${APEX_KO}" "${GASKET_MODULE_DIR}/"

# Same idVendor/idProduct match as upstream's 65-apex.rules, MODE=0666 instead of its
# GROUP="apex" (Fedora has no such group; matches this repo's own device-permission
# convention, see the libedgetpu udev rule above).
GASKET_UDEV_DIR="${GASKET_BUILDROOT}/usr/lib/udev/rules.d"
install -d "${GASKET_UDEV_DIR}"
cat >"${GASKET_UDEV_DIR}/65-apex.rules" <<'EOF'
SUBSYSTEM=="apex", MODE="0666"
EOF

GASKET_SPEC=$(mktemp --suffix=.spec)
cat >"${GASKET_SPEC}" <<EOF
%global debug_package %{nil}
%global __os_install_post %{nil}

Name: kmod-coral-gasket
Version: ${GASKET_DRIVER_VERSION}
Release: 1
Summary: Coral Gasket/Apex PCIe kernel driver and udev rule for ${KVER}
License: GPLv2
BuildArch: ${ARCH}

%description
Prebuilt gasket.ko/apex.ko kernel modules and udev rule for ${KVER} -- the optional
M.2/mini-PCIe Coral Accelerator module (EdgeTPU v1, PCI device 1ac1:089a). Built from
kylegospo/gasket-dkms.

%files
/usr/lib/modules/${KVER}/extra/coral-gasket
/usr/lib/udev/rules.d/65-apex.rules

%post
depmod -a ${KVER}

%postun
depmod -a ${KVER}
EOF

GASKET_TOPDIR=$(mktemp -d)
rpmbuild -bb --define "_topdir ${GASKET_TOPDIR}" --buildroot "${GASKET_BUILDROOT}" "${GASKET_SPEC}"

GASKET_RPM_PATH=$(find "${GASKET_TOPDIR}/RPMS" -iname "kmod-coral-gasket-${GASKET_DRIVER_VERSION}*.rpm" -print -quit)
if [[ -z "${GASKET_RPM_PATH}" ]]; then
    echo "error: rpmbuild didn't produce kmod-coral-gasket-${GASKET_DRIVER_VERSION} under ${GASKET_TOPDIR}/RPMS" >&2
    exit 1
fi

dnf5 -y install "${GASKET_RPM_PATH}"

# Fail the build rather than ship silently without the driver.
rpm -q kmod-coral-gasket
find "/usr/lib/modules/${KVER}" -iname 'gasket.ko*' -print | grep -q .
find "/usr/lib/modules/${KVER}" -iname 'apex.ko*' -print | grep -q .

rm -rf "${GASKET_TMP}" "${GASKET_BUILDROOT}" "${GASKET_TOPDIR}"
