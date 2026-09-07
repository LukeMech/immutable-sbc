#!/bin/bash

set -ouex pipefail

### npu-run's Hailo backend (Hailo-8/8L + Hailo-10H/15) -- rpi-only: neither chip has a
# TFLite delegate (confirmed, see npu-run's own module docstring), so this can't just be
# another --delegate path like Coral/rockchip. Instead: hailo_platform, HailoRT's own
# Python API (pyhailort, built via pybind11 from the SAME hailort source tree
# 20-/21-hailort-*.sh already build libhailort/hailortcli from), running a
# hailo_model_zoo-precompiled SSD MobileNetV1 .hef per chip (versions.env).
#
# Two SEPARATE isolated venvs, one per chip's own /opt/hailort-<version> prefix -- same
# reason those prefixes exist at all: hailo_platform 4.24.0 (hailo8) and 5.4.0 (hailo10h)
# link against mutually incompatible libhailort major versions, so they can no more share
# one Python venv than the C++ CLIs can share one /usr/bin/hailortcli. npu-run itself
# (its own separate venv, /usr/lib/npu-run/venv) never imports hailo_platform directly --
# it shells out to hailo_infer.py using whichever isolated venv's own python3 matches the
# chip actually selected.

. /ctx/versions.env

install -d /usr/share/npu-run/hailo

LABELS_PATH=/usr/share/npu-run/hailo/coco.txt
curl -fsSL -o "${LABELS_PATH}" "${HAILO_COCO_LABELS_URL}"
echo "${HAILO_COCO_LABELS_SHA256}  ${LABELS_PATH}" | sha256sum -c -

# Vendored CMake -- same reasoning as 20-/21-hailort-*.sh (these two builds are just as
# version-locked forever), and needed here too: setup.py below shells out to a bare
# `cmake`, which no longer exists as a system package (see 00-pre-build.sh's rpi case).
TMP=$(mktemp -d)
curl -fsSL -o "${TMP}/cmake.tar.gz" "${CMAKE_URL}"
echo "${CMAKE_SHA256}  ${TMP}/cmake.tar.gz" | sha256sum -c -
tar -xzf "${TMP}/cmake.tar.gz" -C "${TMP}"
CMAKE_BIN_DIR="${TMP}/cmake-${CMAKE_VERSION}-linux-aarch64/bin"
if [[ ! -x "${CMAKE_BIN_DIR}/cmake" ]]; then
    echo "error: cmake archive didn't extract as expected" >&2
    exit 1
fi

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

build_hailo_python_bindings() {
    local hailort_version="$1" hailort_url="$2" hailort_sha256="$3" hef_url="$4" hef_sha256="$5" hef_name="$6"

    local prefix="/opt/hailort-${hailort_version}"
    if [[ ! -f "${prefix}/lib/libhailort.so" ]]; then
        echo "error: ${prefix}/lib/libhailort.so not found -- did the matching 2x-hailort-*.sh hook run first?" >&2
        exit 1
    fi

    local src_tmp
    src_tmp=$(mktemp -d)
    curl -fsSL -o "${src_tmp}/hailort.tar.gz" "${hailort_url}"
    echo "${hailort_sha256}  ${src_tmp}/hailort.tar.gz" | sha256sum -c -
    tar -xzf "${src_tmp}/hailort.tar.gz" -C "${src_tmp}"
    local src_dir
    src_dir=$(find "${src_tmp}" -maxdepth 1 -iname 'hailort-*' -type d -print -quit)
    if [[ -z "${src_dir}" ]]; then
        echo "error: hailort archive didn't extract as expected" >&2
        exit 1
    fi

    python3 -m venv --system-site-packages "${prefix}/pyvenv"

    # PATH: setup.py's own build_ext shells out to a bare `cmake` -- prepend our vendored
    # one so that resolves instead of failing outright (no system cmake package anymore).
    PATH="${CMAKE_BIN_DIR}:${PATH}" \
        LIBHAILORT_PATH="${prefix}/lib/libhailort.so" \
        HAILORT_INCLUDE_DIR="${prefix}/include" \
        "${prefix}/pyvenv/bin/pip" install --no-cache-dir \
        "${src_dir}/hailort/libhailort/bindings/python/platform"

    "${prefix}/pyvenv/bin/python3" -c "import hailo_platform" || {
        echo "error: hailo_platform didn't import after building for ${prefix}" >&2
        exit 1
    }

    curl -fsSL -o "/usr/share/npu-run/hailo/${hef_name}" "${hef_url}"
    echo "${hef_sha256}  /usr/share/npu-run/hailo/${hef_name}" | sha256sum -c -

    rm -rf "${src_tmp}"
}

build_hailo_python_bindings \
    "${HAILORT_HAILO8_VERSION}" "${HAILORT_HAILO8_URL}" "${HAILORT_HAILO8_SHA256}" \
    "${HAILO8_HEF_URL}" "${HAILO8_HEF_SHA256}" "ssd_mobilenet_v1_hailo8.hef"

build_hailo_python_bindings \
    "${HAILORT_HAILO1X_VERSION}" "${HAILORT_HAILO1X_URL}" "${HAILORT_HAILO1X_SHA256}" \
    "${HAILO10H_HEF_URL}" "${HAILO10H_HEF_SHA256}" "ssd_mobilenet_v1_hailo10h.hef"

rm -rf "${TMP}"
