#!/bin/bash

set -ouex pipefail

### AIC8800 Wi-Fi/BT driver (ROCK 5C onboard AIC8800D80 combo chip)
#
# Downloads ausil/aic8800-dkms COPR's aic8800-usb-dkms/aic8800-firmware .rpm files
# directly and extracts them with rpm2cpio -- never `dnf5 install`s them, same
# "fetch the package, build our own rpm from its contents, never let the original
# package's scriptlets run or its NVR linger in the rpm database" approach as
# 11-coral-accelerator.sh's libedgetpu piece. Sidesteps aic8800-usb-dkms's own %post
# (which auto-runs `dkms install` against the build host's kernel, not the target) --
# since it's never installed, that %post never runs, no `noscripts` workaround needed.
#
# Built via DKMS but never shipped as `dkms install`: that doesn't survive rechunking,
# and cleanup orphans it too (confirmed) -- fixed via our own "kmod-*" rpm instead.

KVER=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)
ARCH=$(uname -m)

# dnf5-plugins (providing copr/download) and dkms/kernel-devel/rpm-build/cpio
# themselves come from 00-pre-build.sh, shared by every hook that needs them.
dnf5 -y copr enable ausil/aic8800-dkms

DL_DIR=$(mktemp -d)
dnf5 -y download --destdir "${DL_DIR}" --resolve aic8800-usb-dkms aic8800-firmware

DKMS_RPM=$(find "${DL_DIR}" -iname 'aic8800-usb-dkms-*.rpm' -print -quit)
FW_RPM=$(find "${DL_DIR}" -iname 'aic8800-firmware-*.rpm' -print -quit)
if [[ -z "${DKMS_RPM}" || -z "${FW_RPM}" ]]; then
    echo "error: dnf5 download didn't fetch both aic8800-usb-dkms and aic8800-firmware" >&2
    exit 1
fi

EXTRACT_DIR=$(mktemp -d)
(cd "${EXTRACT_DIR}" && rpm2cpio "${DKMS_RPM}" | cpio -idm --quiet)
(cd "${EXTRACT_DIR}" && rpm2cpio "${FW_RPM}" | cpio -idm --quiet)

SRC_DIR=$(find "${EXTRACT_DIR}/usr/src" -maxdepth 1 -iname 'aic8800*' -type d -print -quit)
if [[ -z "${SRC_DIR}" ]]; then
    echo "error: aic8800-usb-dkms rpm didn't contain a usr/src/aic8800* tree" >&2
    exit 1
fi
# dkms.conf is the source of truth for name/version -- read it, don't guess the naming.
# Not safe to `source`: it references dkms-internal vars only real `dkms` defines.
dkms_conf_var() {
    grep -E "^${1}=" "${SRC_DIR}/dkms.conf" | head -1 | sed -E "s/^${1}=//; s/^\"//; s/\"\$//"
}
PACKAGE_NAME=$(dkms_conf_var PACKAGE_NAME)
PACKAGE_VERSION=$(dkms_conf_var PACKAGE_VERSION)
if [[ -z "${PACKAGE_NAME}" || -z "${PACKAGE_VERSION}" ]]; then
    echo "error: couldn't read PACKAGE_NAME/PACKAGE_VERSION from ${SRC_DIR}/dkms.conf" >&2
    exit 1
fi

# dkms expects its sources under the real /usr/src/<pkg>-<version>, not just anywhere --
# copy in, build, then discard the tracking tree once packaged below.
DKMS_SRC_DIR="/usr/src/$(basename "${SRC_DIR}")"
install -d "${DKMS_SRC_DIR}"
cp -a "${SRC_DIR}/." "${DKMS_SRC_DIR}/"

# Build only -- unlike `dkms install`, `dkms build` never touches
# /usr/lib/modules; it leaves the .ko under /var/lib/dkms, picked up below.
dkms add -m "${PACKAGE_NAME}" -v "${PACKAGE_VERSION}"
dkms build -m "${PACKAGE_NAME}" -v "${PACKAGE_VERSION}" -k "${KVER}"

DKMS_BUILD_DIR="/var/lib/dkms/${PACKAGE_NAME}/${PACKAGE_VERSION}/${KVER}/${ARCH}/module"
mapfile -t BUILT_MODULES < <(find "${DKMS_BUILD_DIR}" -iname '*.ko*' -type f)
if [[ ${#BUILT_MODULES[@]} -eq 0 ]]; then
    echo "error: no built modules found under ${DKMS_BUILD_DIR}" >&2
    exit 1
fi

FW_SRC_DIR="${EXTRACT_DIR}/usr/lib/firmware/aic8800/usb"
if [[ ! -d "${FW_SRC_DIR}" ]]; then
    echo "error: aic8800-firmware rpm didn't contain usr/lib/firmware/aic8800/usb" >&2
    exit 1
fi

# Stage module + firmware into a throwaway buildroot, wrap in a minimal binary RPM
# (%prep/%build/%install empty; debug_package disabled so rpmbuild won't strip the .ko).
RPM_NAME="kmod-${PACKAGE_NAME}"
BUILDROOT=$(mktemp -d)
MODULE_DIR="${BUILDROOT}/usr/lib/modules/${KVER}/extra/${PACKAGE_NAME}"
install -d "${MODULE_DIR}"
install -m 644 "${BUILT_MODULES[@]}" "${MODULE_DIR}/"

FW_DIR="${BUILDROOT}/usr/lib/firmware/aic8800/usb"
install -d "${FW_DIR}"
cp -a "${FW_SRC_DIR}/." "${FW_DIR}/"

SPEC=$(mktemp --suffix=.spec)
cat > "${SPEC}" <<EOF
%global debug_package %{nil}
%global __os_install_post %{nil}

Name: ${RPM_NAME}
Version: ${PACKAGE_VERSION}
Release: 1
Summary: ${PACKAGE_NAME} kernel module and firmware for ${KVER}
License: GPL
BuildArch: ${ARCH}

%description
Prebuilt ${PACKAGE_NAME} kernel module for ${KVER}, plus the firmware it loads at
runtime, built from the ausil/aic8800-dkms COPR package's DKMS sources -- downloaded
and extracted directly, never installed, so there's no runtime dependency on that
COPR package's own aic8800-usb-dkms/aic8800-firmware rpms.

%files
/usr/lib/modules/${KVER}/extra/${PACKAGE_NAME}
/usr/lib/firmware/aic8800/usb

%post
depmod -a ${KVER}

%postun
depmod -a ${KVER}
EOF

TOPDIR=$(mktemp -d)
rpmbuild -bb --define "_topdir ${TOPDIR}" --buildroot "${BUILDROOT}" "${SPEC}"

RPM_PATH=$(find "${TOPDIR}/RPMS" -iname "${RPM_NAME}-${PACKAGE_VERSION}*.rpm" -print -quit)
if [[ -z "${RPM_PATH}" ]]; then
    echo "error: rpmbuild didn't produce ${RPM_NAME}-${PACKAGE_VERSION} under ${TOPDIR}/RPMS" >&2
    exit 1
fi

# dkms's tracking tree and sources are disposable now that the module ships as its own
# rpm-tracked package -- nothing was ever `dnf5 install`ed, so there's no COPR package
# to remove here (the repo itself is removed generically later, post-build.sh).
rm -rf "/var/lib/dkms/${PACKAGE_NAME}" "${DKMS_SRC_DIR}"

dnf5 -y install "${RPM_PATH}"

# Fail the build (rather than ship silently without Wi-Fi) if the module/firmware is
# missing.
rpm -q "${RPM_NAME}"
find "/usr/lib/modules/${KVER}" -iname '*aic8800*' -print | grep -q .
grep -q "${PACKAGE_NAME}" "/usr/lib/modules/${KVER}/modules.dep"
find "/usr/lib/firmware/aic8800/usb" -type f | grep -q .
[[ -f "/usr/lib/firmware/aic8800/usb/fw_patch_table_8800d80_u02.bin" ]]

rm -rf "${DL_DIR}" "${EXTRACT_DIR}" "${BUILDROOT}" "${TOPDIR}"
