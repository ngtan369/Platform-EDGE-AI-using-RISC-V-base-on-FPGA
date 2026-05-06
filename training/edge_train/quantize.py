"""TFLite-style INT8 requantize math + calibration helpers."""
from __future__ import annotations

import math

import numpy as np

from .config import FPGA_INPUT_SIZE


def quantize_multiplier(M_real: float) -> tuple[int, int]:
    """
    Convert a float multiplier (typically (in_scale*w_scale)/out_scale, in (0, 1))
    to TFLite's (Q31_int, right_shift) form:
        real_value ~= (sum * M_q31) >> (31 + right_shift)

    Returns (M_q31, right_shift). For M_real >= 1 we clip to max representable
    (RTL requantize.sv currently doesn't implement left-shift).
    """
    if M_real <= 0.0:
        return 0, 0
    significand, exponent = math.frexp(M_real)            # M_real = sig * 2^exp
    q31 = int(round(significand * (1 << 31)))
    if q31 == (1 << 31):
        q31 //= 2
        exponent += 1
    right_shift = -exponent
    if right_shift < 0:
        print(f"[!] Multiplier {M_real:.4f} >= 1.0 — clipping (RTL needs left-shift support)")
        right_shift = 0
        q31 = (1 << 31) - 1
    return q31, min(right_shift, 31)


def random_representative_dataset(n: int = 100, img_size=FPGA_INPUT_SIZE):
    """Fallback when no real validation set is available — random uniform [0,1]."""
    H, W = img_size
    for _ in range(n):
        yield [np.random.rand(1, H, W, 3).astype(np.float32)]
