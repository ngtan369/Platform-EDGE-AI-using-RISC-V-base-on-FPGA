#!/usr/bin/env python3
"""
CLI inference fallback (no Jupyter required).

Usage:
    python3 infer.py --image path/to/img.jpg

Defaults assume the deploy.sh layout: /home/ubuntu/edgeai/{hw,firmware,training,host}/.
For one-off ad-hoc runs; the canonical demo lives in host/notebooks/inference_demo.ipynb.
"""
import argparse
import sys
import time
from pathlib import Path

import numpy as np
from pynq import allocate

# Allow running this file from anywhere — locate edge_ai/ relative to this script
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from edge_ai import EdgeAIOverlay, load_meta, preprocess_image, load_weights_blob, gap_argmax


DEFAULT_ROOT = Path("/home/ubuntu/edgeai")


def main() -> int:
    p = argparse.ArgumentParser(description="Edge-AI CLI inference (KV260, PYNQ)")
    p.add_argument("--image",     required=True,            help="Input image (.jpg/.png)")
    p.add_argument("--root",      type=Path, default=DEFAULT_ROOT)
    p.add_argument("--bitstream", type=Path, default=None)
    p.add_argument("--firmware",  type=Path, default=None)
    p.add_argument("--weights",   type=Path, default=None)
    args = p.parse_args()

    bitstream = args.bitstream or args.root / "hw/artifacts/kria_soc_wrapper.bit"
    firmware  = args.firmware  or args.root / "firmware/firmware.bin"
    weights   = args.weights   or args.root / "training/export/vgg-tiny_cats_dogs.weights.bin"

    for label, path in [("bitstream", bitstream), ("firmware", firmware), ("weights", weights)]:
        if not path.exists():
            print(f"[!] missing {label}: {path}", file=sys.stderr)
            return 1

    overlay = EdgeAIOverlay(str(bitstream))
    meta    = load_meta(str(weights))
    fpga    = meta["fpga"]

    overlay.clear_shared_regs()
    overlay.load_firmware(str(firmware))

    wb = load_weights_blob(str(weights))
    wbuf = allocate(shape=(len(wb),), dtype=np.uint8)
    wbuf[:] = np.frombuffer(wb, dtype=np.uint8); wbuf.flush()
    overlay.set_weights_addr(wbuf.physical_address)

    ifm = preprocess_image(args.image, meta)
    pp  = max(fpga["max_tensor_bytes"], int(np.prod(ifm.shape)))
    buf_a = allocate(shape=(pp,), dtype=np.int8)
    buf_b = allocate(shape=(pp,), dtype=np.int8)
    flat = ifm.reshape(-1)
    buf_a[:flat.size] = flat; buf_a.flush()
    overlay.set_io_buffers(buf_a.physical_address, buf_b.physical_address)
    overlay.set_dataset_id(meta["dataset_id"])

    t0 = time.perf_counter()
    overlay.kick()
    overlay.poll_done(timeout_s=5.0)
    latency_ms = (time.perf_counter() - t0) * 1000

    final = buf_a if fpga["final_ofm_buf_idx"] == 0 else buf_b
    final.invalidate()
    H, W, C = fpga["final_ofm_shape"][-3:]
    ofm = np.frombuffer(final[:H*W*C], dtype=np.int8).reshape(H, W, C)
    cls, conf, _ = gap_argmax(ofm, fpga["final_ofm_scale"], fpga["final_ofm_zp"])
    label = meta["labels"][cls] if cls < len(meta["labels"]) else f"<{cls}>"

    print(f"{label}\t{conf:.2f}%\t{latency_ms:.2f}ms")

    overlay.reset_cmd()
    for b in (wbuf, buf_a, buf_b):
        b.freebuffer()
    return 0


if __name__ == "__main__":
    sys.exit(main())
