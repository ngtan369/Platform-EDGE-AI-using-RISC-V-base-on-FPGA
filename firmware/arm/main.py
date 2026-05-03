"""
ARM host controller — file-based binary classification on KV260.

Pipeline:
  1. Load bitstream + RISC-V firmware (vào I-BRAM Port B @ 0xA000_0000).
  2. Đọc file ảnh từ SD card → resize 128×128 → quantize INT8 dùng
     scale/zero_point từ <weights>.bin.meta.json (do training/main.py xuất).
  3. Allocate DDR buffer (pynq.allocate, cache-coherent qua HPC0_FPD).
  4. Ghi physical_address + dataset_id vào D-BRAM Port B @ 0xB004_0000.
  5. Set CMD_START tại conv_cnn S00_AXI @ 0xB001_0000 (RISC-V poll bit này
     qua D-BRAM ở cùng offset shared).
  6. Poll STATUS đến DONE, đọc RESULT_CLASS, in label.

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
# Block names trong overlay — phải khớp tên trong Vivado Block Design
BRAM_IBRAM_PORTB = "axi_bram_ctrl_2"   # ARM ghi firmware.bin vào đây
BRAM_DBRAM_PORTB = "axi_bram_ctrl_3"   # ARM ↔ RISC-V shared regs
CONV_CNN_BLOCK   = "conv_cnn_0"        # AXI-Lite control regs

# Shared D-BRAM register layout (phải khớp firmware/riscv/main.c)
REG_CMD_FROM_ARM   = 0x00
REG_STATUS_TO_ARM  = 0x04
REG_DATASET_ID     = 0x08
REG_RESULT_CLASS   = 0x0C
REG_RESULT_CONF    = 0x10
REG_IFM_PHYS_ADDR  = 0x18
REG_OFM_PHYS_ADDR  = 0x1C

# Cờ trạng thái
CMD_START    = 0x01
STATUS_IDLE  = 0x00
STATUS_BUSY  = 0x01
STATUS_DONE  = 0x02

POLL_TIMEOUT_S = 5.0    # tối đa chờ RISC-V


# ==========================================
# HELPERS
# ==========================================
def load_bin_to_bram(bram_ctrl, filepath: str, offset: int = 0):
    """Ghi file nhị phân vào BRAM qua AXI BRAM Controller."""
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


def load_quant_meta(weights_path: str) -> dict:
    """Đọc <weights>.bin.meta.json do training/main.py xuất."""
    meta_path = weights_path + ".meta.json"
    if not os.path.exists(meta_path):
        raise FileNotFoundError(
            f"Thiếu metadata file: {meta_path}\n"
            "Chạy lại training/main.py để xuất scale/zero_point."
        )
    with open(meta_path) as f:
        return json.load(f)


def preprocess_image(img_path: str, meta: dict) -> np.ndarray:
    """
    Đọc ảnh → resize → quantize INT8 theo input_scale/input_zero_point.

    Trả về ndarray INT8 layout (H, W, C) đã sẵn sàng DMA.
    """
    if not os.path.exists(img_path):
        raise FileNotFoundError(img_path)

    bgr = cv2.imread(img_path, cv2.IMREAD_COLOR)
    if bgr is None:
        raise ValueError(f"cv2 không decode được ảnh: {img_path}")
    rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)

    H, W = meta["input"]["fpga_size"]
    rgb = cv2.resize(rgb, (W, H), interpolation=cv2.INTER_AREA)

    # Normalize giống lúc training (Keras applications: 0..1 hoặc preprocess riêng).
    # Để generic, ta dùng 0..1 (chia 255). Nếu model dùng preprocess khác,
    # đổi đoạn này theo `meta['model']`.
    x_float = rgb.astype(np.float32) / 255.0

    # Quantize: q = round(x / scale) - zero_point  (lưu ý dấu trừ — TFLite convention)
    scale = meta["input"]["scale"]
    zp    = meta["input"]["zero_point"]
    q = np.round(x_float / scale) + zp
    q = np.clip(q, -128, 127).astype(np.int8)

    return q  # (H, W, 3) int8


def poll_status(d_bram, expected: int, timeout_s: float):
    """Spin-wait STATUS_TO_ARM == expected, hoặc raise TimeoutError."""
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


# ==========================================
# MAIN
# ==========================================
def main():
    p = argparse.ArgumentParser(description="Edge-AI ARM host controller (KV260)")
    p.add_argument("--bitstream", required=True, help="Path tới .bit file")
    p.add_argument("--firmware",  required=True, help="RISC-V firmware.bin")
    p.add_argument("--weights",   required=True,
                   help="<model>_<dataset>_int8.bin (cần có file .meta.json đi kèm)")
    p.add_argument("--image",     required=True, help="Ảnh đầu vào (.jpg/.png)")
    args = p.parse_args()

    print("=" * 60)
    print(" Edge-AI Classification — ARM host controller ")
    print("=" * 60)

    meta = load_quant_meta(args.weights)
    labels      = meta["labels"]
    dataset_id  = meta["dataset_id"]
    print(f"[*] Model={meta['model']}  Dataset={meta['dataset']} (id={dataset_id})")
    print(f"    Labels: {labels}")
    print(f"    Input quant: scale={meta['input']['scale']:.6g}, zp={meta['input']['zero_point']}")

    # 1. Load bitstream
    print(f"\n[1] Loading bitstream {args.bitstream}")
    overlay = Overlay(args.bitstream)

    i_bram = getattr(overlay, BRAM_IBRAM_PORTB)
    d_bram = getattr(overlay, BRAM_DBRAM_PORTB)
    conv   = getattr(overlay, CONV_CNN_BLOCK)

    # 2. Load RISC-V firmware vào I-BRAM Port B (RISC-V boot vector @ 0x0000_0000)
    print(f"\n[2] Loading RISC-V firmware {args.firmware}")
    # Clear shared regs trước khi RISC-V boot, để nó bắt đầu sạch
    d_bram.write(REG_CMD_FROM_ARM,   0)
    d_bram.write(REG_STATUS_TO_ARM,  STATUS_IDLE)
    d_bram.write(REG_DATASET_ID,     0)
    d_bram.write(REG_RESULT_CLASS,   0)
    d_bram.write(REG_RESULT_CONF,    0)
    d_bram.write(REG_IFM_PHYS_ADDR,  0)
    d_bram.write(REG_OFM_PHYS_ADDR,  0)
    load_bin_to_bram(i_bram, args.firmware, offset=0)

    # (Tuỳ block design): nếu có axi_gpio_0 nối vào rst_ni của RISC-V, pulse reset.
    # Nếu RISC-V chạy ngay khi BRAM có code thì có thể bỏ bước này.
    if hasattr(overlay, "axi_gpio_0"):
        rst = overlay.axi_gpio_0.channel1
        rst.write(0, 0)
        time.sleep(0.01)
        rst.write(0, 1)
        print("[*] RISC-V reset released")
    else:
        print("[*] Không có axi_gpio_0 — RISC-V tự chạy theo bitstream default")

    # 3. Preprocess + allocate DDR buffer
    print(f"\n[3] Preprocess image: {args.image}")
    ifm_int8 = preprocess_image(args.image, meta)
    print(f"    Output shape: {ifm_int8.shape} dtype={ifm_int8.dtype}")

    ifm_buf = allocate(shape=ifm_int8.shape, dtype=np.int8)
    ifm_buf[:] = ifm_int8
    ifm_buf.flush()
    print(f"    DDR phys addr = 0x{ifm_buf.physical_address:08X}, size={ifm_buf.nbytes} B")

    # 4. Ghi shared regs cho RISC-V
    d_bram.write(REG_DATASET_ID,    dataset_id)
    d_bram.write(REG_IFM_PHYS_ADDR, ifm_buf.physical_address)
    # OFM tuỳ chọn — chưa cấp nếu inference engine chưa cần

    # 5. Kick — set CMD_START
    print("\n[4] Kick RISC-V (CMD_START)")
    start = time.perf_counter()
    d_bram.write(REG_CMD_FROM_ARM, CMD_START)

    # 6. Chờ DONE
    try:
        poll_status(d_bram, STATUS_DONE, POLL_TIMEOUT_S)
    except TimeoutError as e:
        print(f"[!] {e}")
        ifm_buf.freebuffer()
        sys.exit(1)
    elapsed_ms = (time.perf_counter() - start) * 1000

    # 7. Đọc kết quả
    cls  = d_bram.read(REG_RESULT_CLASS) & 0xFF
    conf = d_bram.read(REG_RESULT_CONF)  & 0xFF
    label = labels[cls] if cls < len(labels) else f"<unknown:{cls}>"
    conf_pct = (conf / 127.0) * 100.0

    print("\n" + "=" * 60)
    print(f" Prediction: {label}  (class={cls}, confidence≈{conf_pct:.1f}%)")
    print(f" Latency:    {elapsed_ms:.2f} ms")
    print("=" * 60)

    # Cleanup
    d_bram.write(REG_CMD_FROM_ARM, 0)
    ifm_buf.freebuffer()


if __name__ == "__main__":
    main()
