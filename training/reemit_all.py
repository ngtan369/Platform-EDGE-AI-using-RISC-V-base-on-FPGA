"""Re-emit layer_table.bin + weights.bin for all 4 models using the fixed
per-axis → per-tensor rescale logic in edge_train.emit. Reads existing TFLite
references in training/artifacts/<model>/training/export/*_int8.bin — no
re-training needed.

Run on Colab (where tensorflow is available):
    cd /content/capstoneProject/training
    python3 reemit_all.py
"""
import sys, tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from edge_train.emit import emit_layer_table

ART = HERE / "artifacts"
TARGETS = [
    "vgg-tiny_cats-dogs", "vgg-tiny_imagenette",
    "vgg-a_cats-dogs",    "vgg-a_imagenette",
]

for folder_name in TARGETS:
    folder = ART / folder_name
    art_dir = folder / "training" / "export"
    if not art_dir.is_dir():
        print(f"[SKIP] {folder_name}: missing {art_dir}")
        continue
    tflite_files = list(art_dir.glob("*_int8.bin"))
    if not tflite_files:
        print(f"[SKIP] {folder_name}: no _int8.bin")
        continue
    tflite = tflite_files[0]
    prefix = tflite.name.removesuffix("_int8.bin")
    print(f"\n=== {folder_name} ({prefix}) ===")
    tflite_bytes = tflite.read_bytes()

    weights_path = art_dir / f"{prefix}.weights.bin"
    header_path  = folder / "firmware" / "layer_table.h"
    header_path.parent.mkdir(parents=True, exist_ok=True)

    summary = emit_layer_table(tflite_bytes, header_path, weights_path)
    print(f"  → re-emitted: {weights_path.name} + {prefix}.layer_table.bin")

print("\nAll done. Download artifacts/ back to local + redeploy.")
