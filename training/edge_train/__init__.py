"""Edge-AI training pipeline — model + PTQ + FPGA layer-table emitter.

Dataset loading lives inline in `train.ipynb` (kagglehub + tf.data) — bỏ
`datasets.py` để tránh indirection: notebook là single entry point.
"""

from .config import (
    FPGA_INPUT_SIZE, LABEL_MAPS, DATASET_IDS,
    project_root, firmware_dir, export_dir,
)
from .models import build_model, build_vgg_tiny, build_legacy
from .quantize import (
    quantize_multiplier, random_representative_dataset, representative_samples,
)
from .emit import emit_layer_table, convert_to_tflite_int8, export_to_int8

__all__ = [
    # config
    "FPGA_INPUT_SIZE", "LABEL_MAPS", "DATASET_IDS",
    "project_root", "firmware_dir", "export_dir",
    # models
    "build_model", "build_vgg_tiny", "build_legacy",
    # quantize + calibration
    "quantize_multiplier", "random_representative_dataset", "representative_samples",
    # emit
    "emit_layer_table", "convert_to_tflite_int8", "export_to_int8",
]
