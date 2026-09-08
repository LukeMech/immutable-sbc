#!/bin/bash

set -ouex pipefail

### Coral accelerator support -- two independent pieces, for two different Coral
# products, both shared across every variant/board (Coral is a USB/PCIe peripheral,
# not a property of any board). Both are now prebuilt by images/deps/
# (ghcr.io/lukemech/immutable-sbc-deps, bind-mounted here at /deps-rpms) -- installing
# the two rpms is all this hook does now. See images/deps/build_files/01-libedgetpu.sh
# and 11-gasket.sh for the actual builds, and images/deps/README.md for why they moved
# out of the main image build.

## 1. libedgetpu (Coral USB Accelerator runtime) -- USB-only, no kernel driver
# involved (unlike the PCIe/M.2 module below). Requires: libusb1 in the rpm itself
# pulls that in automatically.
EDGETPU_RPM_PATH=$(find /deps-rpms/kmods -iname 'libedgetpu1-std-*.rpm' -print -quit)
if [[ -z "${EDGETPU_RPM_PATH}" ]]; then
    echo "error: libedgetpu1-std-*.rpm not found under /deps-rpms/kmods" >&2
    exit 1
fi
dnf5 -y install "${EDGETPU_RPM_PATH}"
rpm -q libedgetpu1-std

## 2. Coral Gasket/Apex PCIe driver (M.2/mini-PCIe Coral Accelerator module -- a
## separate, optional product from the USB Accelerator above)
GASKET_RPM_PATH=$(find /deps-rpms/kmods -iname 'kmod-coral-gasket-*.rpm' -print -quit)
if [[ -z "${GASKET_RPM_PATH}" ]]; then
    echo "error: kmod-coral-gasket-*.rpm not found under /deps-rpms/kmods" >&2
    exit 1
fi
dnf5 -y install "${GASKET_RPM_PATH}"
rpm -q kmod-coral-gasket
