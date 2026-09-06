#!/bin/bash

set -ouex pipefail

### npu-run (images/rock5/system_files/usr/bin/npu-run)
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

dnf5 -y install python3 python3-pip python3-numpy python3-pillow

# ai-edge-litert is Google's actively maintained rename of tflite_runtime (which
# never shipped aarch64 wheels) -- same Interpreter/load_delegate API. It's the
# only piece here without a Fedora rpm, so it alone goes into a venv rather than
# pip-installing over the system Python: `--system-site-packages` reuses the
# rpm-tracked numpy/Pillow above (kept current by normal package updates)
# without needing pip's own --break-system-packages override.
python3 -m venv --system-site-packages /usr/lib/npu-run/venv
/usr/lib/npu-run/venv/bin/pip install --no-cache-dir "ai-edge-litert==2.2.0"

DEMO_DIR=/usr/share/npu-run
install -d "${DEMO_DIR}"
TMP=$(mktemp -d)

# SSD MobileNetV1 (0.75 depth is also available upstream, this is the 1.0
# variant), quantized, trained on COCO -- the official TensorFlow Lite object
# detection example's model+label asset, bundled together in one zip.
MODEL_URL="https://storage.googleapis.com/download.tensorflow.org/models/tflite/coco_ssd_mobilenet_v1_1.0_quant_2018_06_29.zip"
MODEL_SHA256="a809cd290b4d6a2e8a9d5dad076e0bd695b8091974e0eed1052b480b2f21b6dc"
curl -fL -o "${TMP}/ssd.zip" "${MODEL_URL}"
echo "${MODEL_SHA256}  ${TMP}/ssd.zip" | sha256sum -c -
# python3's zipfile module instead of an `unzip` package dependency -- python3
# is already being installed above regardless.
python3 -m zipfile -e "${TMP}/ssd.zip" "${TMP}/"
install -m 644 "${TMP}/detect.tflite" "${DEMO_DIR}/detect.tflite"
install -m 644 "${TMP}/labelmap.txt" "${DEMO_DIR}/labelmap.txt"

# A real dashcam frame (Wikimedia Commons, CC0 -- explicit public-domain waiver
# by the uploader, not just a "public domain" tag) -- pinned by its own sha256
# below (a future edit at the same URL would fail this check rather than
# silently changing what ships).
IMAGE_URL="https://upload.wikimedia.org/wikipedia/commons/a/a3/SB_NE_Collin_Kelley_Highway_Road_Intersection_CR_591%2C_Madison_dashcam.jpg"
IMAGE_SHA256="25ee822b6986895cc2d3656a7fdb13f16513060c20de355ce9e6a9f19871822b"
curl -fL -o "${TMP}/test.jpg" "${IMAGE_URL}"
echo "${IMAGE_SHA256}  ${TMP}/test.jpg" | sha256sum -c -
install -m 644 "${TMP}/test.jpg" "${DEMO_DIR}/test.jpg"

rm -rf "${TMP}"

chmod 755 /usr/bin/npu-run
