#!/bin/bash

set -ouex pipefail

### Hailo-8/8L PCIe NPU driver (Raspberry Pi AI HAT+/AI Kit -- optional add-on hardware)
#
# Prebuilt by images/deps/build_files/20-hailo8-pci.sh (ghcr.io/lukemech/immutable-sbc-deps,
# bind-mounted here at /deps-rpms) against the kernel build_files/00-pre-build.sh already
# pinned this image to -- installing the rpm here is all this hook does now. See that
# file for the actual build (hailo-ai/hailort-drivers) and images/deps/README.md for why
# this moved out of the main image build.
#
# Driver + firmware only -- this just gets /dev/hailo_chardev to exist when a HAT is
# attached. The userspace side (HailoRT, npu-run's Hailo backend) is 30-hailo-npu-run.sh
# installing its own prebuilt rpm, same source: Hailo has no standard TFLite delegate
# (confirmed -- there's an open upstream request for one, still unresolved), so npu-run
# drives it through HailoRT's own Python API instead of --delegate.

RPM_PATH=$(find /deps-rpms/kmods -iname 'kmod-hailo8-pci-*.rpm' -print -quit)
if [[ -z "${RPM_PATH}" ]]; then
    echo "error: kmod-hailo8-pci-*.rpm not found under /deps-rpms/kmods" >&2
    exit 1
fi

dnf5 -y install "${RPM_PATH}"

# Fail the build rather than ship silently without the driver/firmware.
rpm -q kmod-hailo8-pci

RPM_1x_PATH=$(find /deps-rpms/kmods -iname 'kmod-hailo1x-pci-*.rpm' -print -quit)
if [[ -z "${RPM_1x_PATH}" ]]; then
    echo "error: kmod-hailo1x-pci-*.rpm not found under /deps-rpms/kmods" >&2
    exit 1
fi

dnf5 -y install "${RPM_1x_PATH}"

# Fail the build rather than ship silently without the driver/firmware.
rpm -q kmod-hailo1x-pci
