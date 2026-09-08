#!/bin/bash

set -ouex pipefail

### libedgetpu (Coral USB Accelerator runtime)
#
# Migrated from build_files/11-coral-accelerator.sh's first half -- only change is
# the final `cp` to /rpms/kmods/ instead of the main image installing this rpm
# directly. No kernel coupling at all (pure userspace, USB-only via libusb), so this
# doesn't need to wait on 00-kernel.sh the way the actual kmod hooks do -- it's built
# here anyway so the main image never has to compile/wrap anything itself, matching
# every other "weird package" in this repo.
#
# No Fedora/COPR package exists -- upstream (google-coral/libedgetpu) only builds via
# Bazel, no prebuilt RPM anywhere. Google's own apt repo ships a prebuilt aarch64 .deb
# of the same Apache-2.0 binary though, so this unpacks that rather than building from
# source.
#
# USB-only: the USB Accelerator talks over libusb (Depends: libusb-1.0-0 in the .deb's
# own control file, matched here by the rpm's own `Requires: libusb1` -- the main
# image installing this rpm pulls libusb1 in automatically, no separate install
# needed there), no kernel driver involved -- unlike the PCIe/M.2 Coral module
# (11-gasket.sh), which needs the gasket/apex modules instead.

. /ctx/versions.env
ARCH=$(uname -m)

TMP=$(mktemp -d)
curl -fsSL -o "${TMP}/libedgetpu1-std.deb" "${LIBEDGETPU_DEB_URL}"
echo "${LIBEDGETPU_DEB_SHA256}  ${TMP}/libedgetpu1-std.deb" | sha256sum -c -

# .deb = an ar archive of debian-binary + control.tar.gz + data.tar.xz -- only the
# latter has real files (the shared lib + a udev rule).
(cd "${TMP}" && ar x libedgetpu1-std.deb data.tar.xz)
mkdir -p "${TMP}/data"
tar -xJf "${TMP}/data.tar.xz" -C "${TMP}/data"

LIB_SRC=$(find "${TMP}/data" -iname 'libedgetpu.so.1.0' -type f -print -quit)
if [[ -z "${LIB_SRC}" ]]; then
    echo "error: libedgetpu.so.1.0 not found in the downloaded .deb" >&2
    exit 1
fi

BUILDROOT=$(mktemp -d)

LIB_DIR="${BUILDROOT}/usr/lib64"
install -d "${LIB_DIR}"
install -m 755 "${LIB_SRC}" "${LIB_DIR}/libedgetpu.so.1.0"
ln -s libedgetpu.so.1.0 "${LIB_DIR}/libedgetpu.so.1"

# Same USB vendor/product IDs as upstream's own udev rule (60-libedgetpu1-std.rules) --
# MODE=0666 instead of its GROUP="plugdev" (Fedora has no plugdev group; matches this
# repo's own convention for device permissions, see 11-gasket.sh's udev rule).
UDEV_DIR="${BUILDROOT}/usr/lib/udev/rules.d"
install -d "${UDEV_DIR}"
cat >"${UDEV_DIR}/60-libedgetpu1-std.rules" <<'EOF'
SUBSYSTEM=="usb",ATTRS{idVendor}=="1a6e",ATTRS{idProduct}=="089a",MODE="0666"
SUBSYSTEM=="usb",ATTRS{idVendor}=="18d1",ATTRS{idProduct}=="9302",MODE="0666"
EOF

SPEC=$(mktemp --suffix=.spec)
cat >"${SPEC}" <<EOF
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

TOPDIR=$(mktemp -d)
rpmbuild -bb --define "_topdir ${TOPDIR}" --buildroot "${BUILDROOT}" "${SPEC}"

RPM_PATH=$(find "${TOPDIR}/RPMS" -iname "libedgetpu1-std-${LIBEDGETPU_VERSION}*.rpm" -print -quit)
if [[ -z "${RPM_PATH}" ]]; then
    echo "error: rpmbuild didn't produce libedgetpu1-std-${LIBEDGETPU_VERSION} under ${TOPDIR}/RPMS" >&2
    exit 1
fi

dnf5 -y install libusb1 "${RPM_PATH}"

# Fail the build rather than ship silently without the library.
rpm -q libedgetpu1-std
[[ -f /usr/lib64/libedgetpu.so.1.0 ]]
[[ -L /usr/lib64/libedgetpu.so.1 ]]

cp "${RPM_PATH}" /rpms/kmods/

rm -rf "${TMP}" "${BUILDROOT}" "${TOPDIR}"
