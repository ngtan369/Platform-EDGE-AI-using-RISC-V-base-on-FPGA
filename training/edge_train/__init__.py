"""Edge-AI training pipeline — model + PTQ + FPGA layer-table emitter."""

from .config import (
    FPGA_INPUT_SIZE, LABEL_MAPS, DATASET_IDS,
    project_root, firmware_dir, export_dir,
)
from .models import build_model, build_vgg_tiny, build_legacy
from .datasets import load_dataset, load_cats_dogs, load_inria, representative_samples
from .quantize import quantize_multiplier, random_representative_dataset
from .emit import emit_layer_table, convert_to_tflite_int8, export_to_int8

__all__ = [
    # config
    "FPGA_INPUT_SIZE", "LABEL_MAPS", "DATASET_IDS",
    "project_root", "firmware_dir", "export_dir",
    # models
    "build_model", "build_vgg_tiny", "build_legacy",
    # datasets
    "load_dataset", "load_cats_dogs", "load_inria", "representative_samples",
    # quantize
    "quantize_multiplier", "random_representative_dataset",
    # emit
    "emit_layer_table", "convert_to_tflite_int8", "export_to_int8",
]
