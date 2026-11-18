#!/bin/bash

set -ouex pipefail

### npu-run (system_files/usr/bin/npu-run)
#
# Ships an offline COCO object detector so `npu-run` can run it through the
# RK3588(S) NPU (accel/rocket + mesa-libTeflon, see 20-mesa-teflon.sh) by
# default, plus --check/--benchmark modes that compare it against CPU-only
# inference, on a road-traffic photo (person/car/bicycle/traffic light/... are
# exactly what a COCO-trained detector recognizes). Model, labels and test
# image are pinned by URL+sha256 -- same reasoning as images/boards.toml's
# edk2_url/edk2_sha256: no floating downloads baked into a shipped image.
#
# Stays within the backbones Mesa's own Teflon docs say are validated against
# rocket (MobileNetV1/V2, MobileDet) rather than chasing a newer detector
# architecture -- something like EfficientDet or YOLO uses ops rocket doesn't
# support yet, which would just silently fall back to CPU and defeat the demo.

# Pins (interpreter, ai-edge-litert, model, test image) live in versions.env --
# see its NPU_RUN_* block for why the venv isn't on the system python3.
. /ctx/images/deps/versions.env

# System numpy/Pillow: not for npu-run's own venv (see below), but for the HailoRT
# pyvenvs (images/deps/build_files/30-/31-hailort-hailo*.sh), which are built with
# --system-site-packages against the system python3 and expect these rpms here.
dnf5 -y install python3-numpy python3-pillow "${NPU_RUN_LITERT_PYTHON}"

# ai-edge-litert is Google's actively maintained rename of tflite_runtime (which
# never shipped aarch64 wheels) -- same Interpreter/load_delegate API. It has no
# Fedora rpm, so it goes into its own venv rather than pip-installing over the
# system Python. Fedora's python3-numpy/-pillow rpms only target the system
# python3, so this venv can't reuse them via --system-site-packages -- numpy/Pillow
# come from PyPI wheels instead (--only-binary: never silently fall back to a
# source build).
"${NPU_RUN_LITERT_PYTHON}" -m venv /usr/lib/npu-run/venv
/usr/lib/npu-run/venv/bin/pip install --no-cache-dir --only-binary=numpy,pillow \
    "ai-edge-litert==${NPU_RUN_LITERT_VERSION}" numpy pillow
/usr/lib/npu-run/venv/bin/python3 -c "import numpy, PIL; from ai_edge_litert.interpreter import Interpreter"

DEMO_DIR=/usr/share/npu-run
install -d "${DEMO_DIR}"
TMP=$(mktemp -d)

# SSD MobileNetV1 (0.75 depth is also available upstream, this is the 1.0
# variant), quantized, trained on COCO -- the official TensorFlow Lite object
# detection example's model+label asset, bundled together in one zip.
curl -fL -o "${TMP}/ssd.zip" "${NPU_RUN_MODEL_URL}"
echo "${NPU_RUN_MODEL_SHA256}  ${TMP}/ssd.zip" | sha256sum -c -
# python3's zipfile module instead of an `unzip` package dependency -- python3
# is already being installed above regardless.
python3 -m zipfile -e "${TMP}/ssd.zip" "${TMP}/"
install -m 644 "${TMP}/detect.tflite" "${DEMO_DIR}/detect.tflite"
install -m 644 "${TMP}/labelmap.txt" "${DEMO_DIR}/labelmap.txt"

# A real dashcam frame (Wikimedia Commons, CC0 -- explicit public-domain waiver
# by the uploader, not just a "public domain" tag) -- pinned by its own sha256
# in versions.env (a future edit at the same URL would fail this check rather than
# silently changing what ships).
curl -fL -o "${TMP}/test.jpg" "${NPU_RUN_IMAGE_URL}"
echo "${NPU_RUN_IMAGE_SHA256}  ${TMP}/test.jpg" | sha256sum -c -
install -m 644 "${TMP}/test.jpg" "${DEMO_DIR}/test.jpg"

rm -rf "${TMP}"

chmod 755 /usr/bin/npu-run
