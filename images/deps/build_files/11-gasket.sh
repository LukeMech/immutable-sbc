#!/bin/bash

set -ouex pipefail

### Coral Gasket/Apex PCIe driver (M.2/mini-PCIe Coral Accelerator module)
#
# Migrated verbatim from build_files/11-coral-accelerator.sh's second half -- only
# change is the final `cp` to /rpms/kmods/ instead of the main image installing this
# rpm directly. That file's libedgetpu/USB half (no kernel coupling -- it's a
# userspace .so, USB-only, no kmod at all) stays in the main image unchanged, since
# it doesn't belong in a kmod/kernel-matched image at all.
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

. /ctx/versions.env
KVER=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)
ARCH=$(uname -m)

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
# convention).
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

cp "${GASKET_RPM_PATH}" /rpms/kmods/

rm -rf "${GASKET_TMP}" "${GASKET_BUILDROOT}" "${GASKET_TOPDIR}"
