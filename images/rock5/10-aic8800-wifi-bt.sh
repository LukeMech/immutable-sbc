#!/bin/bash

set -ouex pipefail

### AIC8800 Wi-Fi/BT driver (ROCK 5C onboard AIC8800D80 combo chip)
#
# Built once, at container *build* time in a writable layer, from the
# aic8800-usb-dkms COPR package -- but the built .ko is NOT installed
# with a bare `dkms install` (a raw file copy, untracked by rpm). This
# image's build pipeline runs `rpm-ostree compose build-chunked-oci`
# right after the container build (Justfile's ostree-rechunk, called
# from build.yml) to re-derive the final OCI image -- that step walks
# the rpm database to decide what content to keep, and kernel modules
# dropped in as unpackaged files do not reliably survive it (confirmed:
# the module was present right after this script ran, but missing from
# the deployed system). So instead we repackage the built .ko into a
# real "kmod-*" RPM and `dnf5 install` it, same as how ublue-os images
# ship extra kernel modules (nvidia, v4l2loopback, ...) -- rpm-tracked,
# not a bare file.
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

# Stage the built module(s) into a throwaway buildroot and wrap them in
# a minimal binary RPM -- %prep/%build/%install are empty since the
# files are already in place; debug_package/__os_install_post are
# disabled so rpmbuild's strip/debuginfo machinery doesn't touch an
# already-built .ko.
RPM_NAME="kmod-${PACKAGE_NAME}"
BUILDROOT=$(mktemp -d)
MODULE_DIR="${BUILDROOT}/usr/lib/modules/${KVER}/extra/${PACKAGE_NAME}"
install -d "${MODULE_DIR}"
install -m 644 "${BUILT_MODULES[@]}" "${MODULE_DIR}/"

SPEC=$(mktemp --suffix=.spec)
cat > "${SPEC}" <<EOF
%global debug_package %{nil}
%global __os_install_post %{nil}

Name: ${RPM_NAME}
Version: ${PACKAGE_VERSION}
Release: 1
Summary: ${PACKAGE_NAME} kernel module for ${KVER}
License: GPL
BuildArch: ${ARCH}

%description
Prebuilt ${PACKAGE_NAME} kernel module for ${KVER}, built from the
ausil/aic8800-dkms COPR package's DKMS sources.

%files
/usr/lib/modules/${KVER}/extra/${PACKAGE_NAME}

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

dnf5 -y install "${RPM_PATH}"

# dkms's own tracking tree for this module (sources, build logs, the
# .ko copy we just packaged from) is disposable now that the module
# ships as its own rpm-tracked package. aic8800-usb-dkms itself is left
# installed -- removing it alongside dkms in the same erase transaction
# would run its %preun (which calls `dkms remove`) while dkms may
# already be gone from that same transaction; not worth the risk for a
# package that's otherwise inert once dkms/kernel-devel are gone.
rm -rf "/var/lib/dkms/${PACKAGE_NAME}"

dnf5 -y copr disable ausil/aic8800-dkms
dnf5 -y remove dkms "kernel-devel-${KVER}" rpm-build 'dnf5-command(copr)'

# Fail the image build (rather than ship silently without Wi-Fi) if the
# module isn't actually there after the dkms/build tooling is gone --
# this is exactly the state the deployed system will be in.
rpm -q "${RPM_NAME}"
find "/usr/lib/modules/${KVER}" -iname '*aic8800*' -print | grep -q .
grep -q "${PACKAGE_NAME}" "/usr/lib/modules/${KVER}/modules.dep"
