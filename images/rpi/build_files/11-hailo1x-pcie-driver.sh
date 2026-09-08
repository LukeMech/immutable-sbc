#!/bin/bash

set -ouex pipefail

### Hailo-10H/15 PCIe driver (Raspberry Pi AI HAT+ 2 -- optional add-on hardware)
#
# Prebuilt by images/deps/build_files/21-hailo1x-pci.sh (ghcr.io/lukemech/immutable-sbc-deps,
# bind-mounted here at /deps-rpms) against the kernel build_files/00-pre-build.sh already
# pinned this image to -- installing the rpm here is all this hook does now. See that
# file for the actual build (hailo-ai/hailort-drivers, master branch -- separate chip
# generation from 10-hailo8-pcie-driver.sh's Hailo-8/8L) and images/deps/README.md for
# why this moved out of the main image build.

RPM_PATH=$(find /deps-rpms/kmods -iname 'kmod-hailo1x-pci-*.rpm' -print -quit)
if [[ -z "${RPM_PATH}" ]]; then
    echo "error: kmod-hailo1x-pci-*.rpm not found under /deps-rpms/kmods" >&2
    exit 1
fi

dnf5 -y install "${RPM_PATH}"

# Fail the build rather than ship silently without the driver/firmware.
rpm -q kmod-hailo1x-pci
