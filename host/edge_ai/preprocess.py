"""Image preprocessing: file -> resize -> INT8 quantize matching the FPGA's input scale/zp."""
from __future__ import annotations

import json
import os

import cv2
import numpy as np


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
    rgb = cv2.resize(rgb, (W, H), interpolation=cv2.INTER_AREA)

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
