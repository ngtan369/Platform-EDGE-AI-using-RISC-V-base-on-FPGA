# Memory Map — Edge-AI Kria KV260

> Single source of truth for address assignments. Update this file **and** `firmware/linked.ld` whenever Vivado Address Editor changes.

---

## RISC-V view (`m_axi_instr` + `m_axi_data`, 32-bit address)

| Address | Size | Slave | Purpose |
|---------|------|-------|---------|
| `0x0000_0000` | 64 KB | I-BRAM Port A (`axi_bram_ctrl_0`) | Instruction fetch — `.text`, `.rodata`. RISC-V boot vector |
| `0xB000_0000` | 64 KB | `axi_dma_0/S_AXI_LITE` | DMA descriptor registers (MM2S_SA, MM2S_LENGTH, S2MM_DA, S2MM_LENGTH, CTRL/STATUS) |
| `0xB001_0000` | 64 KB | `conv_cnn_0/S00_AXI` | conv_cnn control: GEOMETRY, CTRL, STATUS, CHANNELS, M_Q31, SHIFT_ZP |
| `0xB004_0000` | 256 KB | D-BRAM Port A (`axi_bram_ctrl_1`) | `.data`, `.bss`, stack, shared handshake regs |

> RISC-V data peripherals/BRAM được đặt cùng dải `0xB0xx_xxxx` với PS view để cùng địa chỉ logic — ARM và RISC-V có thể trao đổi pointer/offset trực tiếp. I-BRAM phải ở `0x0` cho RISC-V boot vector.

---

## PS view (ARM, via M_AXI_HPM0/HPM1_FPD)

| Address | Size | Slave | Purpose |
|---------|------|-------|---------|
| `0xA000_0000` | 64 KB | I-BRAM Port B (`axi_bram_ctrl_2`, HPM0) | ARM nạp/reload firmware.bin |
| `0xB000_0000` | 64 KB | `axi_dma_0/S_AXI_LITE` (HPM1) | (Optional) ARM kicks DMA directly |
| `0xB001_0000` | 64 KB | `conv_cnn_0/S00_AXI` (HPM1) | ARM writes CMD_START, reads STATUS |
| `0xB004_0000` | 256 KB | D-BRAM Port B (`axi_bram_ctrl_3`, HPM1) | ARM ↔ RISC-V shared mem (layout bên dưới) |

---

## Shared D-BRAM register layout (offset từ `0xB004_0000`)

> Code source of truth: [`host/edge_ai/constants.py`](../host/edge_ai/constants.py) — phải khớp với `firmware/main.c`.

| Offset | Size | Name | Direction | Mô tả |
|--------|------|------|-----------|-------|
| `+0x00` | 4 B | `CMD_FROM_ARM`  | ARM → RISC-V | `0x01` = START, `0x00` = idle |
| `+0x04` | 4 B | `STATUS_TO_ARM` | RISC-V → ARM | `0x00` IDLE / `0x01` BUSY / `0x02` DONE |
| `+0x08` | 4 B | `DATASET_ID`    | ARM → RISC-V | `0` = INRIA person, `1` = cats_dogs |
| `+0x0C` | 4 B | `RESULT_CLASS`  | RISC-V → ARM | argmax `∈ {0, 1}` (optional — ARM tự argmax thay) |
| `+0x10` | 4 B | `RESULT_CONF`   | RISC-V → ARM | confidence Q1.7 (0..127, optional) |
| `+0x14` | 4 B | *(boot marker)* | RISC-V → ARM | `0xAB` written by `startup.s` before `main()` — diagnostic only |
| `+0x18` | 4 B | `IFM_PHYS_ADDR` | ARM → RISC-V | DDR phys addr buffer A (input ảnh, ping-pong scratch) |
| `+0x1C` | 4 B | `OFM_PHYS_ADDR` | ARM → RISC-V | DDR phys addr buffer B (ping-pong scratch / final output) |
| `+0x20` | 4 B | `WEIGHT_BASE`   | ARM → RISC-V | DDR phys addr của weights blob (`weights.bin`); RISC-V cộng `LAYERS[i].weight_offset` |
| `+0x24...` | — | (reserved) | — | dành cho mở rộng (per-layer scratch override, IRQ mailbox, …) |

**Layer table:** `LAYERS[]` hiện được link-compile vào firmware (`.rodata`, I-BRAM). Đổi model ⇒ re-train + re-emit `firmware/layer_table.h` + re-compile.

---

## DMA view (`axi_dma_0/Data_MM2S` + `Data_S2MM`, via S_AXI_HPC0_FPD, cache-coherent)

| Address | Size | Slave | Purpose |
|---------|------|-------|---------|
| `0x2000_0000` | 512 MB | DDR_LOW (PS DDR) | IFM / weights / OFM buffers (CMA / `pynq.allocate`) |
| `0xC000_0000` | 512 MB | HPC0_QSPI | ít dùng |
| `0xFF00_0000` | 16 MB | HPC0_LPS_OCM | ít dùng (S2MM only) |

DMA **không** thấy BRAM (đã Exclude trong Address Editor).

---

## Linker layout (`firmware/linked.ld`)

```
MEMORY {
    IRAM (rx)  : ORIGIN = 0x00000000, LENGTH = 64K    /* I-BRAM: .text, .rodata */
    DRAM (rwx) : ORIGIN = 0xB0040000, LENGTH = 256K   /* D-BRAM: .data, .bss, stack */
}
```

Stack top = `ORIGIN(DRAM) + LENGTH(DRAM)` = `0xB008_0000`.

---

## Visual address space

```
RISC-V CV32E40P 32-bit address space (4 GB)
─────────────────────────────────────────────────────────────────────────────
0x0000_0000 ┌──────────────────────────┐  ┐
            │  I-BRAM Port A (64 KB)   │  │ instr fetch (m_axi_instr)
            │  axi_bram_ctrl_0         │  │ .text, .rodata, vectors
0x0001_0000 ├──────────────────────────┤  ┘
            │     ... unmapped ...     │
0x2000_0000 ╞══════════════════════════╡  ┐
            │  HPC0_DDR_LOW  (512 MB)  │  │ DMA target only
            │  PS DDR — IFM/W/OFM      │  │ (RISC-V can read but rarely does)
0x3FFF_FFFF ╞══════════════════════════╡  ┘
            │     ... unmapped ...     │
0xB000_0000 ╞══════════════════════════╡  ┐
            │  axi_dma_0 S_AXI_LITE    │  │ DMA control regs
            │             (64 KB)      │  │ MM2S_SA, S2MM_DA, CTRL/STATUS
0xB001_0000 ├──────────────────────────┤  │ peripherals
            │  conv_cnn_0 S00_AXI      │  │ GEOMETRY, CTRL, STATUS, CHANNELS, M_Q31, SHIFT_ZP
            │             (64 KB)      │  │
0xB002_0000 ├──────────────────────────┤  │
            │     ... gap ...          │  │
0xB004_0000 ├──────────────────────────┤  │
            │  D-BRAM Port A (256 KB)  │  │ data (m_axi_data)
            │  axi_bram_ctrl_1         │  │ .data, .bss
            │  ───── stack grows ↓ ──  │  │ stack top = 0xB008_0000
0xB008_0000 ╞══════════════════════════╡  ┘
            │     ... unmapped ...     │
0xC000_0000 ╞══════════════════════════╡
            │  HPC0_QSPI    (512 MB)   │  rarely used
0xDFFF_FFFF ╞══════════════════════════╡
0xFF00_0000 ╞══════════════════════════╡
            │  HPC0_LPS_OCM  (16 MB)   │  rarely used
0xFFFF_FFFF └──────────────────────────┘

ARM PS view (`zynq_ultra_ps_e_0/Data`)
─────────────────────────────────────────────────────────────────────────────
0xA000_0000 ┌──────────────────────────┐  via M_AXI_HPM0_FPD
            │  I-BRAM Port B (64 KB)   │  ARM ghi/reload firmware.bin
            │  axi_bram_ctrl_2         │
0xA000_FFFF └──────────────────────────┘
0xB000_0000 ┌──────────────────────────┐  via M_AXI_HPM1_FPD → smartconnect_1
            │  axi_dma_0 S_AXI_LITE    │  (optional) ARM kick DMA trực tiếp
0xB001_0000 ├──────────────────────────┤
            │  conv_cnn_0 S00_AXI      │  ARM ghi CMD_START, đọc STATUS
0xB002_0000 ├──────────────────────────┤
            │     ... gap ...          │
0xB004_0000 ├──────────────────────────┤
            │  D-BRAM Port B (256 KB)  │  ARM ↔ RISC-V shared mem
            │  axi_bram_ctrl_3         │  handshake regs, phys ptrs, results
0xB008_0000 └──────────────────────────┘
            (cùng địa chỉ logic như RISC-V Port A — tiện lock-step debug)

DMA view (`axi_dma_0/Data_MM2S` + `Data_S2MM`, qua S_AXI_HPC0_FPD)
─────────────────────────────────────────────────────────────────────────────
Chỉ thấy DDR — KHÔNG thấy BRAM (đã Exclude):
  0x2000_0000 — 0x3FFF_FFFF  HPC0_DDR_LOW   (IFM / weights / OFM buffers)
  0xC000_0000 — 0xDFFF_FFFF  HPC0_QSPI      (ít dùng)
  0xFF00_0000 — 0xFFFF_FFFF  HPC0_LPS_OCM   (ít dùng, S2MM only)

Physical BRAM blocks (dual-port)
─────────────────────────────────────────────────────────────────────────────
blk_mem_gen_2 (I-BRAM, 64 KB)         blk_mem_gen_1 (D-BRAM, 256 KB)
  Port A ← axi_bram_ctrl_0 (RISC-V)     Port A ← axi_bram_ctrl_1 (RISC-V)
            @ 0x0000_0000                         @ 0xB004_0000
  Port B ← axi_bram_ctrl_2 (ARM)        Port B ← axi_bram_ctrl_3 (ARM)
            @ 0xA000_0000                         @ 0xB004_0000
```
