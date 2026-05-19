"""Run TFLite reference inference on board for a few sample images, compare
with FPGA output. Helps identify whether the bias issue is:
  - In FPGA pipeline (pad_same / maxpool / requantize / weights load), OR
  - In the trained model itself (would explain low accuracy even on TFLite)

Usage on board:
    cd /home/ubuntu/edgeai
    sudo python3 host/scripts/tflite_compare.py
"""
import json
import sys
from pathlib import Path
import numpy as np
import cv2

PROJECT_ROOT = Path("/home/ubuntu/edgeai")
sys.path.insert(0, str(PROJECT_ROOT / "host"))
from edge_ai import preprocess_image, load_meta

EXPORT_DIR = PROJECT_ROOT / "training/export"
SAMPLES = PROJECT_ROOT / "samples/cats-dogs"

# Auto-discover model
meta_files = sorted(EXPORT_DIR.glob("*_int8.bin.meta.json"))
assert meta_files, f"No meta.json in {EXPORT_DIR}"
META_PATH = meta_files[0]
meta = json.loads(META_PATH.read_text())
TFLITE_PATH = EXPORT_DIR / f"{meta['model']}_{meta['dataset']}_int8.bin"

print(f"Model    : {meta['model']} + {meta['dataset']}")
print(f"TFLite   : {TFLITE_PATH}")
print(f"Labels   : {meta['labels']}")
print()

# Load TFLite (try tflite_runtime first, fall back to tf.lite)
try:
    from tflite_runtime.interpreter import Interpreter
    print("[*] Using tflite_runtime")
except ImportError:
    try:
        from tensorflow.lite import Interpreter
        print("[*] Using tensorflow.lite")
    except ImportError:
        print("[fail] Neither tflite_runtime nor tensorflow available.")
        print("Install: pip3 install tflite-runtime")
        sys.exit(1)

interp = Interpreter(model_path=str(TFLITE_PATH))
interp.allocate_tensors()
in_d  = interp.get_input_details()[0]
out_d = interp.get_output_details()[0]

print(f"Input  : shape={in_d['shape']} dtype={in_d['dtype']} "
      f"scale={in_d['quantization'][0]:.6f} zp={in_d['quantization'][1]}")
print(f"Output : shape={out_d['shape']} dtype={out_d['dtype']}")
print()

# Run on a few samples
samples = sorted(SAMPLES.glob("*.jpg"))[:20]
correct = 0
for img_path in samples:
    ifm = preprocess_image(str(img_path), meta)   # (128, 128, 3) int8
    interp.set_tensor(in_d['index'], ifm[None, ...])
    interp.invoke()
    out = interp.get_tensor(out_d['index'])  # shape (1, 2) for cats_dogs
    cls = int(out.argmax(axis=-1)[0])
    label = meta['labels'][cls]
    true_lbl = img_path.stem.rsplit('_', 1)[0]
    ok = (label == true_lbl)
    correct += int(ok)
    flag = "✓" if ok else "✗"
    raw = out[0].tolist() if out.ndim == 2 else out.tolist()
    print(f"  {flag} {img_path.name:20}  →  {label:5}  logits={raw}")

print(f"\nTFLite accuracy on samples: {correct}/{len(samples)} = "
      f"{100*correct/len(samples):.1f}%")
print("\nNếu TFLite accuracy cũng ~50% → model train có vấn đề.")
print("Nếu TFLite >85% nhưng FPGA 40% → FPGA pipeline có bug.")
