"""Software ops applied on ARM between conv layers (Phase B).

Ops:
    pad_same     — zero-pad 1px border so conv with VALID hardware emulates SAME
    maxpool_2x2  — 2x2 stride-2 max pooling (per channel)
    relu, relu6  — INT8 clamp (rarely needed; hardware does ReLU after requantize)
    skip_add     — INT8 residual add with saturation (for ResNet, future)

All ops operate on INT8 NHWC numpy arrays (height, width, channels). Designed
to be fast on ARM NEON via numpy's vectorized backends.
"""
from __future__ import annotations
import numpy as np


def pad_same(ifm: np.ndarray, kernel: int = 3) -> np.ndarray:
    """Zero-pad NHWC INT8 IFM so VALID conv emulates SAME conv.

    For kernel=3: pad 1px each side (top, bottom, left, right). Note the pad
    value is 0 in the SIGNED int8 domain — for unsigned-shifted inputs (input_zp
    nonzero), the pad should be input_zp instead, but TFLite reference treats
    pad as 0 in real domain (= input_zp in quantized domain). Our hardware
    folds input_zp correction into bias (see emit.py), so 0-padding is correct.
    """
    if ifm.dtype != np.int8:
        raise TypeError(f"pad_same expects int8 IFM, got {ifm.dtype}")
    if kernel == 3:
        pad = 1
    elif kernel == 1:
        return ifm   # no padding for 1x1 conv
    elif kernel == 5:
        pad = 2
    else:
        raise NotImplementedError(f"pad_same: kernel {kernel} not supported")
    return np.pad(ifm, ((pad, pad), (pad, pad), (0, 0)), mode="constant",
                  constant_values=0)


def maxpool_2x2(ofm: np.ndarray) -> np.ndarray:
    """2x2 stride-2 max pool on NHWC INT8 OFM. Halves spatial dims.

    Trims trailing odd row/col if input dim is odd (drop floor convention).
    """
    if ofm.dtype != np.int8:
        raise TypeError(f"maxpool_2x2 expects int8 OFM, got {ofm.dtype}")
    h, w, c = ofm.shape
    h_even = h & ~1
    w_even = w & ~1
    x = ofm[:h_even, :w_even, :]
    # Reshape to (h/2, 2, w/2, 2, c) then max over the two pool axes
    x = x.reshape(h_even // 2, 2, w_even // 2, 2, c)
    return x.max(axis=(1, 3)).astype(np.int8)


def relu_int8(ofm: np.ndarray, zp: int) -> np.ndarray:
    """ReLU on quantized INT8: clamp values below output_zp up to zp."""
    return np.maximum(ofm, np.int8(zp))


def relu6_int8(ofm: np.ndarray, scale: float, zp: int) -> np.ndarray:
    """ReLU6 quantized: clamp real value to [0, 6] → quantized [zp, q6]."""
    q6 = int(round(6.0 / scale)) + zp
    q6 = np.clip(q6, -128, 127)
    return np.clip(ofm, zp, q6).astype(np.int8)


def skip_add(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """Saturating add of two INT8 NHWC arrays (for ResNet residual).
    Both inputs must have same shape AND same (scale, zp) — re-quantization
    handled by training-side fusion."""
    if a.shape != b.shape:
        raise ValueError(f"skip_add shape mismatch: {a.shape} vs {b.shape}")
    s = a.astype(np.int16) + b.astype(np.int16)
    return np.clip(s, -128, 127).astype(np.int8)
