"""Image preprocessing: file -> resize -> INT8 quantize matching the FPGA's input scale/zp.

Also exposes `parse_layer_table()` so ARM can dispatch per-layer ops (Path B):
ARM reads each layer's geometry/padding/pool_en and applies pad_same / maxpool
between hardware Conv kicks.
"""
from __future__ import annotations

import json
import os
import struct

import cv2
import numpy as np

# Matches training/edge_train/emit.py LAYER_DESC_FMT and firmware/layer_desc.h
LAYER_DESC_FMT = "<IIII HHHH BBBBB3x i bbbb"
assert struct.calcsize(LAYER_DESC_FMT) == 40

PAD_VALID = 0
PAD_SAME  = 1
ACT_NONE  = 0
ACT_RELU  = 1
ACT_RELU6 = 2


def parse_layer_table(path: str) -> list[dict]:
    """Parse a packed layer_table.bin file into a list of per-layer dicts.

    Each dict has the same fields as firmware/layer_desc.h layer_desc_t (40 B):
        weight_offset, weight_bytes, bias_offset, bias_bytes,
        ifm_width, ifm_height, cin, cout,
        kernel, stride, padding, pool_en, activation,
        output_M, output_shift, input_zp, output_zp, weight_zp
    """
    data = open(path, "rb").read()
    n = len(data) // 40
    layers = []
    for i in range(n):
        fields = struct.unpack_from(LAYER_DESC_FMT, data, i * 40)
        layers.append({
            "weight_offset": fields[0], "weight_bytes": fields[1],
            "bias_offset":   fields[2], "bias_bytes":   fields[3],
            "ifm_width":  fields[4], "ifm_height": fields[5],
            "cin":        fields[6], "cout":       fields[7],
            "kernel":   fields[8],  "stride":     fields[9],
            "padding":  fields[10], "pool_en":    fields[11],
            "activation": fields[12],
            "output_M":     fields[13],
            "output_shift": fields[14],
            "input_zp":     fields[15],
            "output_zp":    fields[16],
            "weight_zp":    fields[17],
        })
    return layers


def load_meta(weights_path: str, override: str | None = None) -> dict:
    """
    Locate <weights>.meta.json (training emits it next to the .tflite reference).
    Search order:
      1. `override` (if given)
      2. <weights_prefix>_int8.bin.meta.json   (canonical name from train.py)
      3. <weights>.meta.json                   (fallback)
    """
    candidates: list[str] = []
    if override:
        candidates.append(override)
    prefix = weights_path.replace(".weights.bin", "")
    candidates.append(prefix + "_int8.bin.meta.json")
    candidates.append(weights_path + ".meta.json")

    for path in candidates:
        if os.path.exists(path):
            with open(path) as f:
                return json.load(f)
    raise FileNotFoundError(
        "No meta.json found. Tried:\n  " + "\n  ".join(candidates) +
        "\nRe-run training/train.py to regenerate."
    )


def preprocess_image(img_path: str, meta: dict) -> np.ndarray:
    """
    Read RGB image -> resize to meta['input']['fpga_size'] -> normalize [0,1] ->
    quantize INT8 using `input.scale` and `input.zero_point` from meta.
    Returns array shape (H, W, 3) dtype int8.
    """
    bgr = cv2.imread(img_path, cv2.IMREAD_COLOR)
    if bgr is None:
        raise ValueError(f"cv2 could not decode image: {img_path}")
    rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)

    H, W = meta["input"]["fpga_size"]
    # Match training pipeline (tf.image.resize bilinear) — INTER_AREA gives
    # different anti-aliasing → measurably lower accuracy on multi-class tasks.
    rgb = cv2.resize(rgb, (W, H), interpolation=cv2.INTER_LINEAR)

    x = rgb.astype(np.float32) / 255.0
    scale = meta["input"]["scale"]
    zp    = meta["input"]["zero_point"]
    q = np.round(x / scale) + zp
    return np.clip(q, -128, 127).astype(np.int8)


def load_weights_blob(weights_path: str) -> bytes:
    if not os.path.exists(weights_path):
        raise FileNotFoundError(weights_path)
    with open(weights_path, "rb") as f:
        return f.read()
