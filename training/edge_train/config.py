"""Project-wide constants — single source of truth for both train.py and train.ipynb."""
from pathlib import Path

# FPGA accelerator input geometry (Conv-CNN v2.0 alpha — 3x3 valid stride 1, no pool)
FPGA_INPUT_SIZE = (128, 128)        # (H, W)

# Dataset-side label mapping. Order = class_id (RISC-V argmax index).
#
# Capstone scope (Phase B):
#   - cats_dogs : hardware validation / bring-up baseline (binary classification)
#   - imagenette: 10-class multi-class real-world demo (FastAI subset of ImageNet)
LABEL_MAPS = {
    "cats_dogs":  ["cat", "dog"],
    "imagenette": ["tench", "english_springer", "cassette_player", "chainsaw",
                   "church", "french_horn", "garbage_truck", "gas_pump",
                   "golf_ball", "parachute"],
}
DATASET_IDS = {"cats_dogs": 0, "imagenette": 1}

# Project root resolution: works both for `python -m edge_train` and a notebook
# that has cd'd into training/. Walk up until we find CLAUDE.md.
def project_root() -> Path:
    p = Path(__file__).resolve()
    for parent in [p, *p.parents]:
        if (parent / "CLAUDE.md").exists():
            return parent
    # Fallback: assume training/edge_train -> ../..
    return Path(__file__).resolve().parents[2]


def firmware_dir() -> Path:
    return project_root() / "firmware"


def export_dir() -> Path:
    return project_root() / "training" / "export"
