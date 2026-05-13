"""Convert FPGA's final INT8 OFM -> classification result via GAP + softmax."""
from __future__ import annotations

import numpy as np


def gap_argmax(ofm_int8: np.ndarray, scale: float, zp: int):
    """
    Global-average pool over (H, W) then argmax over channel.
    Accepts ofm shape [H, W, C] or [1, H, W, C].

    Returns:
        cls         (int)         — predicted class id
        conf_pct    (float)       — softmax probability of `cls` * 100
        logits      (np.ndarray)  — per-class real-valued logits (length C)
    """
    if ofm_int8.ndim == 4:
        ofm_int8 = ofm_int8[0]
    real = (ofm_int8.astype(np.int32) - zp).astype(np.float32) * scale
    logits = real.mean(axis=(0, 1))
    cls = int(np.argmax(logits))
    e = np.exp(logits - logits.max())
    probs = e / e.sum()
    return cls, float(probs[cls] * 100.0), logits
