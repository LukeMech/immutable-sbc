#!/bin/bash

set -ouex pipefail

### AIC8800 Wi-Fi/BT driver (ROCK 5C onboard AIC8800D80 combo chip)
#
# Prebuilt by images/deps/build_files/10-aic8800.sh (ghcr.io/lukemech/immutable-sbc-deps,
# bind-mounted here at /deps-rpms) against the kernel build_files/00-pre-build.sh already
# pinned this image to -- installing the rpm here is all this hook does now. See that
# file for the actual build (radxa-pkg/aic8800's USB driver tree, the quilt patch series,
# the two-destination firmware install) and images/deps/README.md for why this moved out
# of the main image build.

RPM_PATH=$(find /deps-rpms/kmods -iname 'kmod-aic8800-usb-*.rpm' -print -quit)
if [[ -z "${RPM_PATH}" ]]; then
    echo "error: kmod-aic8800-usb-*.rpm not found under /deps-rpms/kmods" >&2
    exit 1
fi

dnf5 -y install "${RPM_PATH}"

# Fail the build rather than ship silently without Wi-Fi/BT.
rpm -q kmod-aic8800-usb
