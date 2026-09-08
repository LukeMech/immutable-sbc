#!/bin/bash

set -ouex pipefail

### npu-run's Hailo backend (Hailo-8/8L + Hailo-10H/15) -- rpi-only: neither chip has a
# TFLite delegate (confirmed, see npu-run's own module docstring), so this can't just be
# another --delegate path like Coral/rockchip. Instead: hailo_platform, HailoRT's own
# Python API (pyhailort), running a hailo_model_zoo-precompiled SSD MobileNetV1 .hef per
# chip (versions.env).
#
# The actual libhailort/hailortcli/hailo_platform build (two isolated
# /opt/hailort-<version> prefixes, one per chip -- hailo_platform 4.24.0 and 5.4.0 link
# against mutually incompatible libhailort major versions, so they can no more share one
# Python venv than the C++ CLIs can share one /usr/bin/hailortcli) is prebuilt by
# images/deps/build_files/30-/31-hailort-hailo*.sh (ghcr.io/lukemech/immutable-sbc-deps,
# bind-mounted here at /deps-rpms) -- installing those two rpms is all this hook does
# for that part now. npu-run itself (its own separate venv, /usr/lib/npu-run/venv)
# never imports hailo_platform directly -- it shells out to hailo_infer.py using
# whichever isolated venv's own python3 matches the chip actually selected.

. /ctx/images/deps/versions.env

for name in hailort-hailo8 hailort-hailo1x; do
    RPM_PATH=$(find /deps-rpms/hailort -iname "${name}-*.rpm" -print -quit)
    if [[ -z "${RPM_PATH}" ]]; then
        echo "error: ${name}-*.rpm not found under /deps-rpms/hailort" >&2
        exit 1
    fi
    dnf5 -y install "${RPM_PATH}"
    rpm -q "${name}"
done

install -d /usr/share/npu-run/hailo

LABELS_PATH=/usr/share/npu-run/hailo/coco.txt
curl -fsSL -o "${LABELS_PATH}" "${HAILO_COCO_LABELS_URL}"
echo "${HAILO_COCO_LABELS_SHA256}  ${LABELS_PATH}" | sha256sum -c -

curl -fsSL -o /usr/share/npu-run/hailo/ssd_mobilenet_v1_hailo8.hef "${HAILO8_HEF_URL}"
echo "${HAILO8_HEF_SHA256}  /usr/share/npu-run/hailo/ssd_mobilenet_v1_hailo8.hef" | sha256sum -c -

curl -fsSL -o /usr/share/npu-run/hailo/ssd_mobilenet_v1_hailo10h.hef "${HAILO10H_HEF_URL}"
echo "${HAILO10H_HEF_SHA256}  /usr/share/npu-run/hailo/ssd_mobilenet_v1_hailo10h.hef" | sha256sum -c -

# hailo_infer.py itself ships from images/rpi/system_files/usr/lib/npu-run/hailo_infer.py
# -- already copied onto / by build.sh before any hook runs, chmod here since git only
# tracks the executable bit inconsistently (same reasoning as 05-gnome-minimal.sh's
# lm-nopasswd fixup). One script, works against either isolated venv unmodified -- it
# only ever imports hailo_platform (whichever version its own venv resolves) and reads
# --hef/--labels paths passed in, nothing chip-specific hardcoded.
INFER_SCRIPT=/usr/lib/npu-run/hailo_infer.py
if [[ ! -f "${INFER_SCRIPT}" ]]; then
    echo "error: ${INFER_SCRIPT} missing -- images/rpi/system_files should have put it there" >&2
    exit 1
fi
chmod 755 "${INFER_SCRIPT}"
