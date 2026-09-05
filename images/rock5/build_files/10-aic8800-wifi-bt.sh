#!/bin/bash

set -ouex pipefail

### AIC8800 Wi-Fi/BT driver (ROCK 5C onboard AIC8800D80 combo chip)
#
# Built once, at container *build* time in a writable layer, from the
# aic8800-usb-dkms COPR package -- but the build's own dkms/kernel-devel
# tooling, and the aic8800-usb-dkms/aic8800-firmware packages themselves,
# never ship in the final image. Two separate, confirmed failure modes
# drove this:
#
# 1. A bare `dkms install` (a raw file copy, untracked by rpm) does not
#    reliably survive this pipeline's rechunking pass -- confirmed: the
#    .ko was present right after this script ran, but missing from the
#    deployed system.
# 2. aic8800-usb-dkms `Requires: kernel-devel`, and aic8800-firmware is
#    only required by aic8800-usb-dkms -- so this script's *own* final
#    cleanup (`dnf5 remove ... kernel-devel-${KVER} ...`) cascades:
#    dnf5 removes aic8800-usb-dkms as a now-unsatisfiable dependent
#    package, which in turn leaves aic8800-firmware an orphaned
#    dependency and removes that too. Confirmed via the build log
#    ("Removing dependent packages: aic8800-usb-dkms" / "Removing
#    unused dependencies: ... aic8800-firmware"). No rechunker is even
#    involved -- the firmware is gone before the image layer is ever
#    committed.
#
# Fix for both: never let the final image depend on anything from
# aic8800-usb-dkms/aic8800-firmware surviving. Build the module with
# dkms as before, but pull both the compiled .ko *and* the firmware
# files it needs out into our own self-contained "kmod-*" RPM before
# the cleanup step runs, same as how ublue-os images ship extra kernel
# modules (nvidia, v4l2loopback, ...) -- rpm-tracked, not a bare file,
# and with no runtime dependency on the upstream COPR packages at all.
#
# https://copr.fedorainfracloud.org/coprs/ausil/aic8800-dkms/

KVER=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)
ARCH=$(uname -m)

# quay.io/fedora/fedora-bootc doesn't bundle the copr plugin the way
# ublue-os base images do -- install it explicitly first.
dnf5 -y install 'dnf5-command(copr)'

dnf5 -y copr enable ausil/aic8800-dkms

# aic8800-usb-dkms's %post scriptlet auto-runs `dkms install` against
# `$(uname -r)` -- the *build host's* running kernel (this GitHub Actions
# runner's own kernel), which has nothing to do with the Fedora aarch64
# kernel this image ships. That build fails (wrong kernel headers) and
# dnf5 treats the failed scriptlet as fatal to the whole transaction.
# dnf5's tsflags only has the coarse `noscripts` (skips every scriptlet,
# not just %post -- "nopost" is a raw rpm flag, not a dnf tsflags value),
# which is fine here: we don't need any of those side effects, we drive
# dkms ourselves below, pinned to the kernel we're actually building for.
dnf5 -y install --setopt=tsflags=noscripts rpm-build dkms "kernel-devel-${KVER}" aic8800-usb-dkms

SRC_DIR=$(find /usr/src -maxdepth 1 -iname 'aic8800*' -type d -print -quit)
if [[ -z "${SRC_DIR}" ]]; then
    echo "error: aic8800-usb-dkms didn't drop sources under /usr/src" >&2
    exit 1
fi
# dkms.conf is the package's own source of truth for its name/version --
# read it instead of guessing at the source directory's naming scheme.
# It's not safe to `source` directly: it references dkms-internal
# variables (e.g. kernel_source_dir) that only the real `dkms` tool
# defines before evaluating it, so pull out just the two fields we need.
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
# /usr/lib/modules. It leaves the compiled .ko under /var/lib/dkms,
# which is where we pick it up from below.
dkms add -m "${PACKAGE_NAME}" -v "${PACKAGE_VERSION}"
dkms build -m "${PACKAGE_NAME}" -v "${PACKAGE_VERSION}" -k "${KVER}"

DKMS_BUILD_DIR="/var/lib/dkms/${PACKAGE_NAME}/${PACKAGE_VERSION}/${KVER}/${ARCH}/module"
mapfile -t BUILT_MODULES < <(find "${DKMS_BUILD_DIR}" -iname '*.ko*' -type f)
if [[ ${#BUILT_MODULES[@]} -eq 0 ]]; then
    echo "error: no built modules found under ${DKMS_BUILD_DIR}" >&2
    exit 1
fi

# aic8800-usb-dkms Requires: aic8800-firmware (a separate, firmware-only
# COPR subpackage) -- pull its usb/ files in now, while it's still
# installed, rather than depend on it surviving this script's own
# cleanup below.
FW_SRC_DIR="/usr/lib/firmware/aic8800/usb"
if [[ ! -d "${FW_SRC_DIR}" ]]; then
    echo "error: aic8800-firmware didn't install anything under ${FW_SRC_DIR}" >&2
    exit 1
fi

# Stage the built module and firmware into a throwaway buildroot and
# wrap them in a minimal binary RPM -- %prep/%build/%install are empty
# since the files are already in place; debug_package/__os_install_post
# are disabled so rpmbuild's strip/debuginfo machinery doesn't touch an
# already-built .ko.
RPM_NAME="kmod-${PACKAGE_NAME}"
BUILDROOT=$(mktemp -d)
MODULE_DIR="${BUILDROOT}/usr/lib/modules/${KVER}/extra/${PACKAGE_NAME}"
install -d "${MODULE_DIR}"
install -m 644 "${BUILT_MODULES[@]}" "${MODULE_DIR}/"

FW_DIR="${BUILDROOT}${FW_SRC_DIR}"
install -d "${FW_DIR}"
cp -a "${FW_SRC_DIR}/." "${FW_DIR}/"

# Everything needed from aic8800-usb-dkms/aic8800-firmware is already
# copied into BUILDROOT above, and rpmbuild packages purely from
# BUILDROOT's contents -- it doesn't care whether the originals are
# still installed. So build our own rpm first, then remove every
# COPR/build package in one shot below (including aic8800-usb-dkms/
# aic8800-firmware, which ship the exact same paths --
# /usr/lib/modules/.../aic8800-usb, /usr/lib/firmware/aic8800/usb -- our
# new rpm is about to claim), and only then install it. One remove pass
# instead of two, while still avoiding ever depending on rpm's
# shared-identical-file tolerance to install alongside the originals.
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

# dkms's own tracking tree for this module (sources, build logs, the
# .ko copy we just packaged from) is disposable now that the module and
# its firmware ship as their own rpm-tracked package.
rm -rf "/var/lib/dkms/${PACKAGE_NAME}"

# `copr disable` is itself a command from the dnf5-command(copr) plugin,
# so it has to run before that plugin package is removed below.
dnf5 -y copr disable ausil/aic8800-dkms
dnf5 -y remove aic8800-usb-dkms aic8800-firmware dkms "kernel-devel-${KVER}" rpm-build 'dnf5-command(copr)'

dnf5 -y install "${RPM_PATH}"

# Fail the image build (rather than ship silently without Wi-Fi) if the
# module or its firmware isn't actually there after the dkms/build
# tooling -- and aic8800-usb-dkms/aic8800-firmware themselves -- are
# gone. This is exactly the state the deployed system will be in.
rpm -q "${RPM_NAME}"
find "/usr/lib/modules/${KVER}" -iname '*aic8800*' -print | grep -q .
grep -q "${PACKAGE_NAME}" "/usr/lib/modules/${KVER}/modules.dep"
find "${FW_SRC_DIR}" -type f | grep -q .
[[ -f "${FW_SRC_DIR}/fw_patch_table_8800d80_u02.bin" ]]
