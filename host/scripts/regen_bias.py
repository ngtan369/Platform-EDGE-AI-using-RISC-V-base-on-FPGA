"""Fold input_zp × Σ(weights) correction into biases.
Run on the board (has numpy). Modifies weights.bin in place."""
import numpy as np
import os, shutil

WEIGHTS = "/home/ubuntu/edgeai/training/export/vgg-tiny_cats_dogs.weights.bin"
BACKUP  = WEIGHTS + ".bak"

# Layer params (from layer_table.h)
layers = [
    # w_off, w_bytes, b_off, b_bytes, cin, cout, kernel, input_zp
    (0,     216,   0xd8,   32,   3,  8, 3, -128),
    (248,   1152,  0x578,  64,   8, 16, 3, -128),
    (1464,  4608,  0x17b8, 128, 16, 32, 3, -128),
    (6200,  18432, 0x6038, 256, 32, 64, 3, -128),
    (24888, 1152,  0x65b8, 8,   64,  2, 3, -128),
]

# Backup once (idempotent: if backup exists, restore from it first so we always
# correct from the ORIGINAL TFLite biases — never double-apply correction)
if os.path.exists(BACKUP):
    print(f"Restoring original from backup {BACKUP}")
    shutil.copy(BACKUP, WEIGHTS)
else:
    print(f"Creating backup at {BACKUP}")
    shutil.copy(WEIGHTS, BACKUP)

with open(WEIGHTS, "rb") as f:
    orig = bytearray(f.read())
blob = bytearray(orig)

for idx, L in enumerate(layers):
    w_off, w_bytes, b_off, b_bytes, cin, cout, k, in_zp = L
    w = np.frombuffer(orig[w_off:w_off+w_bytes], dtype=np.int8).reshape(cout, k, k, cin)
    sum_w = w.astype(np.int32).sum(axis=(1,2,3))
    bias = np.frombuffer(orig[b_off:b_off+b_bytes], dtype=np.int32).copy()
    bias_corr = bias - in_zp * sum_w
    blob[b_off:b_off+b_bytes] = bias_corr.astype(np.int32).tobytes()
    print(f"L{idx}: cin={cin} cout={cout} in_zp={in_zp}")
    print(f"    sum_w[:4]   = {sum_w[:4].tolist()}")
    print(f"    bias_orig[:4]={bias[:4].tolist()}")
    print(f"    bias_corr[:4]={bias_corr[:4].tolist()}")

with open(WEIGHTS, "wb") as f:
    f.write(bytes(blob))
print(f"\nWrote corrected weights.bin ({len(blob)} B)")
