#!/bin/bash

set -ouex pipefail

### AIC8800 Wi-Fi/BT driver (ROCK 5C onboard AIC8800D80 combo chip)
#
# Built via ausil/aic8800-dkms COPR but never shipped: `dkms install` doesn't survive
# rechunking, and cleanup orphans it too (confirmed) -- fixed via our own "kmod-*" rpm.

KVER=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)
ARCH=$(uname -m)

# dnf5-command(copr) is installed by 00-default-config.sh, shared by every hook that needs it.
dnf5 -y copr enable ausil/aic8800-dkms

# aic8800-usb-dkms's %post auto-runs `dkms install` against the build host's kernel
# (not the target), which fails; skip via `noscripts` -- we drive dkms ourselves below.
dnf5 -y install --setopt=tsflags=noscripts rpm-build dkms "kernel-devel-${KVER}" aic8800-usb-dkms

SRC_DIR=$(find /usr/src -maxdepth 1 -iname 'aic8800*' -type d -print -quit)
if [[ -z "${SRC_DIR}" ]]; then
    echo "error: aic8800-usb-dkms didn't drop sources under /usr/src" >&2
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

# aic8800-usb-dkms Requires: aic8800-firmware -- pull its usb/ files in
# now, while installed, rather than depend on it surviving cleanup below.
FW_SRC_DIR="/usr/lib/firmware/aic8800/usb"
if [[ ! -d "${FW_SRC_DIR}" ]]; then
    echo "error: aic8800-firmware didn't install anything under ${FW_SRC_DIR}" >&2
    exit 1
fi

# Stage module + firmware into a throwaway buildroot, wrap in a minimal binary RPM
# (%prep/%build/%install empty; debug_package disabled so rpmbuild won't strip the .ko).
RPM_NAME="kmod-${PACKAGE_NAME}"
BUILDROOT=$(mktemp -d)
MODULE_DIR="${BUILDROOT}/usr/lib/modules/${KVER}/extra/${PACKAGE_NAME}"
install -d "${MODULE_DIR}"
install -m 644 "${BUILT_MODULES[@]}" "${MODULE_DIR}/"

FW_DIR="${BUILDROOT}${FW_SRC_DIR}"
install -d "${FW_DIR}"
cp -a "${FW_SRC_DIR}/." "${FW_DIR}/"

# rpmbuild packages purely from BUILDROOT's contents, regardless of what's installed --
# build our rpm first, remove every COPR/build package (same paths), then install it.
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
Prebuilt ${PACKAGE_NAME} kernel module for ${KVER}, plus the firmware
it loads at runtime, built from the ausil/aic8800-dkms COPR package's
DKMS sources -- self-contained, with no runtime dependency on that
COPR package's own aic8800-usb-dkms/aic8800-firmware rpms.

%files
/usr/lib/modules/${KVER}/extra/${PACKAGE_NAME}
${FW_SRC_DIR}

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

# dkms's tracking tree for this module is disposable now that the module
# and firmware ship as their own rpm-tracked package.
rm -rf "/var/lib/dkms/${PACKAGE_NAME}"

# The copr repo itself is removed generically at the end of build.sh, once every
# hook (not just this one) is done with dnf5-command(copr).
dnf5 -y remove aic8800-usb-dkms aic8800-firmware dkms "kernel-devel-${KVER}" rpm-build

dnf5 -y install "${RPM_PATH}"

# Fail the build (rather than ship silently without Wi-Fi) if the module/firmware is
# missing once dkms/COPR packages are gone -- exactly the deployed system's state.
rpm -q "${RPM_NAME}"
find "/usr/lib/modules/${KVER}" -iname '*aic8800*' -print | grep -q .
grep -q "${PACKAGE_NAME}" "/usr/lib/modules/${KVER}/modules.dep"
find "${FW_SRC_DIR}" -type f | grep -q .
[[ -f "${FW_SRC_DIR}/fw_patch_table_8800d80_u02.bin" ]]
