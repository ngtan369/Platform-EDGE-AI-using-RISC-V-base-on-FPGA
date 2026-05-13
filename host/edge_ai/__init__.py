"""Edge-AI host runtime — PYNQ-side library for Kria KV260."""

from . import constants
from .constants import (
    REG_CMD_FROM_ARM, REG_STATUS_TO_ARM, REG_DATASET_ID,
    REG_RESULT_CLASS, REG_RESULT_CONF,
    REG_IFM_PHYS_ADDR, REG_OFM_PHYS_ADDR, REG_WEIGHT_BASE,
    CMD_START, CMD_IDLE,
    STATUS_IDLE, STATUS_BUSY, STATUS_DONE,
)
from .overlay import EdgeAIOverlay
from .preprocess import load_meta, preprocess_image, load_weights_blob
from .postprocess import gap_argmax

__all__ = [
    "EdgeAIOverlay",
    "load_meta", "preprocess_image", "load_weights_blob",
    "gap_argmax",
    "constants",
    "REG_CMD_FROM_ARM", "REG_STATUS_TO_ARM", "REG_DATASET_ID",
    "REG_RESULT_CLASS", "REG_RESULT_CONF",
    "REG_IFM_PHYS_ADDR", "REG_OFM_PHYS_ADDR", "REG_WEIGHT_BASE",
    "CMD_START", "CMD_IDLE",
    "STATUS_IDLE", "STATUS_BUSY", "STATUS_DONE",
]
