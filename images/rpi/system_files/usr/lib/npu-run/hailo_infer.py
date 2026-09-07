#!/usr/bin/env python3
"""Runs one compiled Hailo .hef through HailoRT's own Python API (hailo_platform) --
invoked as a subprocess from npu-run's own venv using whichever isolated
/opt/hailort-<version>/pyvenv matches the chip actually selected (hailo_platform isn't
importable from npu-run's own venv: each HailoRT major version's bindings link against
a mutually incompatible libhailort, see images/rpi/build_files/30-hailo-npu-run.sh).
Writes its result as JSON to --output-json rather than stdout -- hailo_platform's own
C++ layer can print warnings/logs that would otherwise land on stdout and corrupt a
stdout-JSON contract.
"""

import argparse
import json
import time

import numpy as np
from PIL import Image

from hailo_platform import HEF, VDevice


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--hef", required=True)
    p.add_argument("--image", required=True)
    p.add_argument("--labels", required=True)
    p.add_argument("--score-threshold", type=float, default=0.4)
    p.add_argument("--iterations", type=int, default=1)
    p.add_argument("--output-json", required=True)
    return p.parse_args()


def load_labels(path):
    with open(path) as f:
        return [line.strip() for line in f if line.strip()]


def main():
    args = parse_args()
    labels = load_labels(args.labels)

    hef = HEF(args.hef)
    input_info = hef.get_input_vstream_infos()[0]
    height, width = input_info.shape[0], input_info.shape[1]

    image = Image.open(args.image).convert("RGB")
    resized = image.resize((width, height))
    input_data = np.expand_dims(np.array(resized), axis=0).astype(np.uint8)

    params = VDevice.create_params()
    with VDevice(params) as vdevice:
        infer_model = vdevice.create_infer_model(args.hef)
        infer_model.set_batch_size(1)

        with infer_model.configure() as configured:
            output_name = infer_model.outputs[0].name
            output_shape = infer_model.output(output_name).shape

            def run_once():
                output_buffers = {output_name: np.empty(output_shape, dtype=np.uint8)}
                bindings = configured.create_bindings(output_buffers=output_buffers)
                bindings.input().set_buffer(input_data[0])
                configured.wait_for_async_ready(timeout_ms=10000)
                job = configured.run_async([bindings])
                job.wait(10000)
                return bindings.output().get_buffer()

            start = time.time()
            for _ in range(args.iterations):
                raw = run_once()
            elapsed_s = (time.time() - start) / args.iterations

    # HAILO_NMS_BY_CLASS output: a list indexed by class_id, each element itself a list
    # of that class's detections as [ymin, xmin, ymax, xmax, score] (normalized 0-1) --
    # HailoRT's own runtime does the box-decode/NMS, this is already structured, not a
    # raw tensor to decode ourselves.
    detections = []
    for class_id, class_detections in enumerate(raw):
        for det in class_detections:
            score = float(det[4])
            if score < args.score_threshold:
                continue
            ymin, xmin, ymax, xmax = (float(v) for v in det[:4])
            detections.append(
                {
                    "label": labels[class_id] if class_id < len(labels) else str(class_id),
                    "score": score,
                    "box": [xmin, ymin, xmax, ymax],
                }
            )

    with open(args.output_json, "w") as f:
        json.dump({"elapsed_s": elapsed_s, "detections": detections}, f)


if __name__ == "__main__":
    main()
