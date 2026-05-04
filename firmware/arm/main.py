"""
ARM host controller — file-based binary classification on KV260.

Pipeline:
  1. Load bitstream + RISC-V firmware (vào I-BRAM Port B @ 0xA000_0000).
  2. Đọc <weights_blob>.weights.bin → DDR (pynq.allocate). Ghi phys addr vào
     REG_WEIGHT_BASE @ +0x20.
  3. Đọc file ảnh từ SD card → resize → quantize INT8 dùng meta.json.
  4. Allocate 2 ping-pong DDR buffers (buf_a = preprocessed image, buf_b = scratch).
     Ghi phys addr vào REG_IFM_PHYS_ADDR (+0x18) và REG_OFM_PHYS_ADDR (+0x1C).
  5. Set CMD_START. RISC-V chạy layer-by-layer rồi STATUS_DONE.
  6. ARM đọc OFM cuối từ buf_a hoặc buf_b (theo meta['fpga']['final_ofm_buf_idx']).
  7. ARM làm GlobalAveragePool + argmax → in label.

Memory map khớp Vivado Address Editor sau khi fix validate (xem CLAUDE.md).
"""
import os
import sys
import json
import time
import argparse
import numpy as np
import cv2
from pynq import Overlay, allocate

# ==========================================
# CẤU HÌNH (xem CLAUDE.md "Memory Map")
# ==========================================
BRAM_IBRAM_PORTB = "axi_bram_ctrl_2"   # ARM ghi firmware.bin vào đây
BRAM_DBRAM_PORTB = "axi_bram_ctrl_3"   # ARM ↔ RISC-V shared regs

# Shared D-BRAM register layout (phải khớp firmware/riscv/main.c)
REG_CMD_FROM_ARM   = 0x00
REG_STATUS_TO_ARM  = 0x04
REG_DATASET_ID     = 0x08
REG_RESULT_CLASS   = 0x0C
REG_RESULT_CONF    = 0x10
REG_IFM_PHYS_ADDR  = 0x18
REG_OFM_PHYS_ADDR  = 0x1C
REG_WEIGHT_BASE    = 0x20

# Cờ trạng thái
CMD_START    = 0x01
STATUS_IDLE  = 0x00
STATUS_BUSY  = 0x01
STATUS_DONE  = 0x02

POLL_TIMEOUT_S = 5.0


# ==========================================
# HELPERS
# ==========================================
def load_bin_to_bram(bram_ctrl, filepath: str, offset: int = 0):
    if not os.path.exists(filepath):
        raise FileNotFoundError(filepath)
    with open(filepath, "rb") as f:
        data = f.read()
    if len(data) % 4 != 0:
        data += b"\x00" * (4 - (len(data) % 4))
    for i in range(0, len(data), 4):
        val = int.from_bytes(data[i:i+4], byteorder="little")
        bram_ctrl.write(offset + i, val)
    print(f"[*] Loaded {filepath} ({len(data)} B) → BRAM @ +0x{offset:X}")


def load_meta(weights_path: str) -> dict:
    meta_path = weights_path + ".meta.json"
    if not os.path.exists(meta_path):
        raise FileNotFoundError(
            f"Thiếu metadata: {meta_path}\nChạy lại training/main.py để xuất."
        )
    with open(meta_path) as f:
        return json.load(f)


def preprocess_image(img_path: str, meta: dict) -> np.ndarray:
    bgr = cv2.imread(img_path, cv2.IMREAD_COLOR)
    if bgr is None:
        raise ValueError(f"cv2 không decode được ảnh: {img_path}")
    rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)

    H, W = meta["input"]["fpga_size"]
    rgb = cv2.resize(rgb, (W, H), interpolation=cv2.INTER_AREA)

    x = rgb.astype(np.float32) / 255.0
    scale = meta["input"]["scale"]
    zp    = meta["input"]["zero_point"]
    q = np.round(x / scale) + zp
    return np.clip(q, -128, 127).astype(np.int8)


def poll_status(d_bram, expected: int, timeout_s: float):
    deadline = time.time() + timeout_s
    while True:
        s = d_bram.read(REG_STATUS_TO_ARM)
        if s == expected:
            return
        if time.time() > deadline:
            raise TimeoutError(
                f"RISC-V không phản hồi (status=0x{s:08X}, expected=0x{expected:08X})"
            )
        time.sleep(0.0005)


def gap_argmax(ofm_int8: np.ndarray, scale: float, zp: int):
    """
    GlobalAveragePool + argmax trên OFM tensor cuối (shape [H, W, C] hoặc [1, H, W, C]).
    Convert INT8 → real value qua (q - zp) * scale rồi GAP qua trục H,W.
    Trả về (class_id, confidence_pct).
    """
    if ofm_int8.ndim == 4:
        ofm_int8 = ofm_int8[0]   # drop batch
    real = (ofm_int8.astype(np.int32) - zp).astype(np.float32) * scale
    logits = real.mean(axis=(0, 1))   # GAP → vector [C]
    cls = int(np.argmax(logits))
    # Softmax-ish confidence (numerically stable)
    e = np.exp(logits - logits.max())
    probs = e / e.sum()
    return cls, float(probs[cls] * 100.0)


# ==========================================
# MAIN
# ==========================================
def main():
    p = argparse.ArgumentParser(description="Edge-AI ARM host controller (KV260)")
    p.add_argument("--bitstream", required=True)
    p.add_argument("--firmware",  required=True, help="RISC-V firmware.bin")
    p.add_argument("--weights",   required=True,
                   help="<model>_<dataset>.weights.bin (cần file .meta.json đi kèm "
                        "có tên là <model>_<dataset>_int8.bin.meta.json — nhưng cũng "
                        "chấp nhận cùng prefix với --weights nếu match)")
    p.add_argument("--meta",      required=False, default=None,
                   help="Override meta.json path (default: derive from --weights)")
    p.add_argument("--image",     required=True, help="Ảnh đầu vào (.jpg/.png)")
    args = p.parse_args()

    print("=" * 60)
    print(" Edge-AI Classification — ARM host controller ")
    print("=" * 60)

    # Meta.json: training emit cạnh file tflite (..._int8.bin.meta.json), nhưng
    # weights.bin là file riêng. Ưu tiên --meta nếu được chỉ định.
    if args.meta:
        meta_path = args.meta
    else:
        # Try <weights_prefix>_int8.bin.meta.json
        prefix = args.weights.replace(".weights.bin", "")
        candidate = prefix + "_int8.bin.meta.json"
        meta_path = candidate if os.path.exists(candidate) else args.weights + ".meta.json"
    if not os.path.exists(meta_path):
        print(f"[!] Không tìm thấy meta.json (đã thử {meta_path})")
        sys.exit(1)
    with open(meta_path) as f:
        meta = json.load(f)

    labels      = meta["labels"]
    dataset_id  = meta["dataset_id"]
    fpga_meta   = meta["fpga"]
    final_buf   = fpga_meta["final_ofm_buf_idx"]    # 0=buf_a, 1=buf_b
    final_shape = fpga_meta["final_ofm_shape"]
    final_scale = fpga_meta["final_ofm_scale"]
    final_zp    = fpga_meta["final_ofm_zp"]
    max_bytes   = fpga_meta["max_tensor_bytes"]

    print(f"[*] Model={meta['model']}  Dataset={meta['dataset']} (id={dataset_id})")
    print(f"    Labels: {labels}")
    print(f"    NUM_LAYERS={fpga_meta['num_layers']}  "
          f"final OFM shape={final_shape} buf_idx={final_buf}")

    # ---- 1. Bitstream ----
    print(f"\n[1] Loading bitstream {args.bitstream}")
    overlay = Overlay(args.bitstream)
    i_bram = getattr(overlay, BRAM_IBRAM_PORTB)
    d_bram = getattr(overlay, BRAM_DBRAM_PORTB)

    # ---- 2. Firmware + clear shared regs ----
    print(f"\n[2] Loading RISC-V firmware {args.firmware}")
    for off in (REG_CMD_FROM_ARM, REG_STATUS_TO_ARM, REG_DATASET_ID,
                REG_RESULT_CLASS, REG_RESULT_CONF,
                REG_IFM_PHYS_ADDR, REG_OFM_PHYS_ADDR, REG_WEIGHT_BASE):
        d_bram.write(off, 0)
    load_bin_to_bram(i_bram, args.firmware, offset=0)

    if hasattr(overlay, "axi_gpio_0"):
        rst = overlay.axi_gpio_0.channel1
        rst.write(0, 0); time.sleep(0.01); rst.write(0, 1)
        print("[*] RISC-V reset released")

    # ---- 3. Weights blob → DDR ----
    print(f"\n[3] Loading weights blob {args.weights}")
    with open(args.weights, "rb") as f:
        wbytes = f.read()
    wbuf = allocate(shape=(len(wbytes),), dtype=np.uint8)
    wbuf[:] = np.frombuffer(wbytes, dtype=np.uint8)
    wbuf.flush()
    print(f"    Weights: {len(wbytes)} B  phys=0x{wbuf.physical_address:08X}")
    d_bram.write(REG_WEIGHT_BASE, wbuf.physical_address)

    # ---- 4. Image preprocess + ping-pong buffers ----
    print(f"\n[4] Preprocess image: {args.image}")
    ifm_int8 = preprocess_image(args.image, meta)
    print(f"    Input: shape={ifm_int8.shape} dtype={ifm_int8.dtype}")

    pp_size = max(max_bytes, int(np.prod(ifm_int8.shape)))
    buf_a = allocate(shape=(pp_size,), dtype=np.int8)
    buf_b = allocate(shape=(pp_size,), dtype=np.int8)

    flat = ifm_int8.reshape(-1)
    buf_a[:flat.size] = flat
    buf_a.flush()
    print(f"    buf_a (IFM):    phys=0x{buf_a.physical_address:08X}  size={pp_size} B")
    print(f"    buf_b (scratch): phys=0x{buf_b.physical_address:08X}")

    d_bram.write(REG_IFM_PHYS_ADDR, buf_a.physical_address)
    d_bram.write(REG_OFM_PHYS_ADDR, buf_b.physical_address)
    d_bram.write(REG_DATASET_ID,    dataset_id)

    # ---- 5. Kick + poll ----
    print("\n[5] Kick RISC-V (CMD_START)")
    start = time.perf_counter()
    d_bram.write(REG_CMD_FROM_ARM, CMD_START)
    try:
        poll_status(d_bram, STATUS_DONE, POLL_TIMEOUT_S)
    except TimeoutError as e:
        print(f"[!] {e}")
        for b in (wbuf, buf_a, buf_b): b.freebuffer()
        sys.exit(1)
    latency_ms = (time.perf_counter() - start) * 1000

    # ---- 6. Đọc final OFM từ ping-pong buffer đúng ----
    final_buf_obj = buf_a if final_buf == 0 else buf_b
    final_buf_obj.invalidate()    # đảm bảo CPU đọc latest từ DDR

    H, W, C = final_shape[-3:]    # shape có thể là [1,H,W,C] hoặc [H,W,C]
    nbytes  = H * W * C
    ofm_flat = np.frombuffer(final_buf_obj[:nbytes], dtype=np.int8)
    ofm = ofm_flat.reshape(H, W, C)

    # ---- 7. GAP + argmax ----
    cls, conf_pct = gap_argmax(ofm, final_scale, final_zp)
    label = labels[cls] if cls < len(labels) else f"<unknown:{cls}>"

    print("\n" + "=" * 60)
    print(f" Prediction: {label}  (class={cls}, confidence≈{conf_pct:.1f}%)")
    print(f" Latency:    {latency_ms:.2f} ms")
    print("=" * 60)

    # Cleanup
    d_bram.write(REG_CMD_FROM_ARM, 0)
    for b in (wbuf, buf_a, buf_b):
        b.freebuffer()


if __name__ == "__main__":
    main()
