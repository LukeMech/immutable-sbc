#!/bin/bash

set -ouex pipefail

### AIC8800 Wi-Fi/BT driver (ROCK 5C onboard AIC8800D80 combo chip)
#
# This is a DKMS package, but building it here -- during the container
# build, in a writable layer -- is not the same problem as DKMS trying to
# rebuild itself against a new kernel on an already-deployed, read-only
# bootc system. We build the .ko once, bake it into /usr/lib/modules,
# then remove the DKMS toolchain and COPR so neither ships in the final
# image or tries to run again at runtime.
#
# https://copr.fedorainfracloud.org/coprs/ausil/aic8800-dkms/

KVER=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)

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
dnf5 -y install --setopt=tsflags=noscripts dkms "kernel-devel-${KVER}" aic8800-usb-dkms

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

dkms add -m "${PACKAGE_NAME}" -v "${PACKAGE_VERSION}"
dkms build -m "${PACKAGE_NAME}" -v "${PACKAGE_VERSION}" -k "${KVER}"
dkms install -m "${PACKAGE_NAME}" -v "${PACKAGE_VERSION}" -k "${KVER}"

# Fail the image build (rather than ship silently without Wi-Fi) if the
# module didn't actually get built for this exact kernel.
dkms status
find "/usr/lib/modules/${KVER}" -iname '*aic8800*' -print | grep -q .

depmod -a "${KVER}"

dnf5 -y copr disable ausil/aic8800-dkms
dnf5 -y remove dkms "kernel-devel-${KVER}" 'dnf5-command(copr)'
