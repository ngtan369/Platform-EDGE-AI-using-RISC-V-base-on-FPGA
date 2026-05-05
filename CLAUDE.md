# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working in this repository.

## Project Overview

Heterogeneous Edge-AI Acceleration Platform targeting the Xilinx Kria KV260 (`xck26-sfvc784-2LV-c`). A standard CNN model (INT8 quantized) runs inference across two compute cores: an ARM Cortex-A53 host controller and a CV32E40P RISC-V soft-core that drives a custom CNN accelerator in the FPGA fabric. The training pipeline supports multiple CNN architectures (VGG, ResNet, EfficientNet, YOLO variants) and two datasets (INRIA Person detection, Cats vs. Dogs classification).

## Repository Structure

```
training/        # Python — model training, INT8 quantization, C-header weight export
fpga/
  hw_src/        # SystemVerilog RTL — RISC-V wrapper (riscv_top.sv), OBI→AXI bridge, axi_pkg/obi_pkg
                 # NOTE: conv_cnn RTL ĐÃ chuyển vào ip_repo/conv_cnn_1_0/{hdl,src}/ (source-of-truth)
  cv32e40p/      # Git submodule — OpenHW RV32IMC core (https://github.com/ngtan369/cv32e40p)
  ip_repo/       # Packaged Vivado IPs (conv_cnn_1_0, riscv_axi_1_0)
  vivado_pj/     # Vivado project (open in GUI to synthesize/implement)
firmware/
  riscv/         # C + RISC-V assembly — bare-metal inference engine
  arm/           # Python host controller (runs on-board Ubuntu)
reports/         # Final report PDF and diagrams
```

## Build Commands

### AI Model (Python)
```bash
cd training
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# CLI args: --model [vgg-tiny | vgg11 | vgg16 | resnet18 | tiny-yolo | yolo-fastest | efficientnet-lite]
#           --dataset [inria | cats_dogs]
#           --epochs <int>     (default: 10)
#           --export_dir <path>     (default: ./export)
python3 main.py --model vgg-tiny --dataset cats_dogs

# Output:
#   ./export/vgg-tiny_cats_dogs_int8.bin               (TFLite reference)
#   ./export/vgg-tiny_cats_dogs_int8.bin.meta.json     (ARM runtime metadata)
#   ./export/vgg-tiny_cats_dogs.weights.bin            (INT8 weights blob — DDR loadable)
#   ../firmware/riscv/layer_table.h                    (overwrites stub — re-build firmware!)
#
# Note: training input là 128×128 cho vgg-tiny (khớp FPGA pipeline).
#       Các model legacy (vgg16/resnet18/...) train 224×224 NHƯNG export sang
#       layer_table.h sẽ FAIL — chứa op chưa hỗ trợ (1×1, DW, residual, BN, ...).
```

#### Khuyến nghị model: `vgg-tiny` (fully-convolutional)
```
Input 128×128×3
├─ Conv 3×3, cout=8,  ReLU         → 126×126×8
├─ Conv 3×3, cout=16, ReLU + Pool  → 62×62×16
├─ Conv 3×3, cout=32, ReLU + Pool  → 30×30×32
├─ Conv 3×3, cout=64, ReLU + Pool  → 14×14×64
└─ Conv 3×3, cout=N (no act)       → 12×12×N    (N = num_classes = 2)
                                     ↑
                       ARM đọc OFM cuối → GAP → softmax → argmax
```
- Không có Dense head — last conv `cout=num_classes`, ARM tự GAP+argmax (giảm ops cần FPGA hỗ trợ).
- 5 conv layer, ~30K params INT8, fits dễ trong DDR.

#### Supported Models
| Model | Backbone | Task |
|-------|----------|------|
| `vgg11`, `vgg16` | VGG16 | Classification |
| `resnet18` | ResNet50V2 | Classification |
| `efficientnet-lite` | EfficientNetB0 | Classification |
| `tiny-yolo`, `yolo-fastest` | MobileNetV2 backbone + Detection Head (TODO) | Detection |

#### Supported Datasets
| Dataset | Classes | Task |
|---------|---------|------|
| `inria` | 2 (Background / Person) | Human detection |
| `cats_dogs` | 2 (Cat / Dog) | Classification |

### RISC-V Firmware
```bash
make -C firmware/riscv
# Requires: riscv-none-elf-gcc, -march=rv32imc -mabi=ilp32
# Output: firmware.bin (linked to BRAM at 0x00000000, 64 KB)
```

### FPGA Bitstream
Open `fpga/vivado_pj/vivado_pj.xpr` in Vivado. Add sources from `fpga/hw_src/` and `fpga/cv32e40p/rtl/`. Run synthesis → implementation → generate bitstream.

### RTL Simulation
Use Vivado's built-in simulator (xvlog/xsim) or ModelSim against the testbenches:
- `fpga/ip_repo/conv_cnn_1_0/src/tb_conv_cnn_v1_0.sv` — AXI-Lite control test (skeleton, doesn't verify datapath)
- `fpga/ip_repo/conv_cnn_1_0/src/tb_conv_core.sv` — STALE: instantiates old port list, won't compile against current `conv_core.sv`
- `fpga/cv32e40p/example_tb/` — reference bare-metal RISC-V test

**Conv_CNN source-of-truth:** `fpga/ip_repo/conv_cnn_1_0/{hdl,src}/`
- `hdl/` — AXI wrappers do Vivado IP Packager sinh: `conv_cnn_v1_0.v` (top), `conv_cnn_v1_0_S00_AXI.v`, `conv_cnn_v1_0_S00_AXIS.v`, `conv_cnn_v1_0_M00_AXIS.v`
- `src/` — RTL datapath modules: `conv_core.sv`, `controller_fsm.sv`, `line_buffer.sv`, `window_3x3.sv`, `pe_mac.sv`, `max_pool.sv` + 2 testbenches

**Workflow:** Tạo Vivado project riêng (RTL only) trỏ source vào `ip_repo/conv_cnn_1_0/{hdl,src}/`, sửa trực tiếp + simulate ở đó. Sau khi xong:
1. Mở `ip_repo/conv_cnn_1_0` IP project → `Re-package IP` (bump version nếu đổi port).
2. Trong `vivado_pj` BD project: `IP Catalog` → `Refresh` → nếu cần thì `Reports → Report IP Status → Upgrade Selected`.
3. `Validate Design` → `Generate Bitstream`.

> `fpga/hw_src/conv_cnn/` là bản backup cũ, **không còn edit**. Nếu drift so với `ip_repo/`, tin `ip_repo/`.

### Submodule Init
```bash
git submodule update --init
```

## Architecture

### Data Flow (DDR-centric: AXI-DMA via S_AXI_HPC0_FPD)
> **Scope hiện tại:** Binary classification từ **file ảnh trên SD card** (chưa camera real-time).
> Output: `class_id ∈ {0,1}` + confidence. INRIA → 0=no_person, 1=person; cats_dogs → 0=cat, 1=dog.

```
ARM (firmware/arm/main.py on Ubuntu KV260)
  → đọc file .jpg/.png từ SD card (cv2.imread)
  → resize 224×224 (training input) → 128×128 (FPGA input)
  → quantize FP32/uint8 pixel → INT8:
        q = round(x_float / input_scale) - input_zero_point
     (input_scale, input_zero_point lấy từ TFLite metadata sau PTQ)
  → cache-coherent DDR buffers via pynq.allocate (CMA region):
        ifm_buf, weight_buf, ofm_buf  (each has .physical_address)
  → ghi INT8 IFM vào ifm_buf, INT8 weights vào weight_buf
  → ghi shared regs vào D-BRAM Port B (0xB0040000):
        REG_DATASET_ID, REG_IFM_PHYS_ADDR, REG_OFM_PHYS_ADDR
  → set CMD_START at conv_cnn S00_AXI (0xB0010000 — same offset PS & RISC-V view)

RISC-V (main.c, executes from I-BRAM at 0x0000_0000)
  → polls REG_CMD_FROM_ARM @ 0xB004_0000 / waits on IRQ
  → reads buf_a (REG_IFM_PHYS_ADDR), buf_b (REG_OFM_PHYS_ADDR), weight_base
  → for i in 0..NUM_LAYERS-1:
        L = &LAYERS[i]                            (compiled-in layer descriptor)
        in  = (i & 1) ? buf_b : buf_a             (ping-pong DDR scratch)
        out = (i & 1) ? buf_a : buf_b
        program axi_dma_0:
            MM2S: DDR (in)  ─► conv_cnn S00_AXIS
            S2MM: conv_cnn M00_AXIS ─► DDR (out)
        configure conv_cnn S00_AXI (active_width, pool_en, …)
        kick start, poll done
        (TODO P1.7: stream weights = weight_base + L->weight_offset trước IFM)
  → set STATUS_DONE  (RISC-V không đọc DDR được — ARM tự argmax)

ARM (sau STATUS_DONE)
  → đọc OFM cuối từ DDR (buf_a nếu NUM_LAYERS chẵn, buf_b nếu lẻ)
  → np.argmax 2 logits → (class_id, confidence)

ARM
  → map class_id sang label string:
       INRIA: ["no_person", "person"][class_id]
       cats_dogs: ["cat", "dog"][class_id]
  → in ra console / overlay lên ảnh / log ra file
```

**Phân biệt 2 loại quantization** (tránh nhầm lẫn):
| Loại | Khi nào | Object | Ai làm |
|------|--------|--------|--------|
| Weight quantization | 1 lần, lúc PTQ trong `training/train.py` | FP32 weights → INT8 + scale/zp | Pipeline training, ghi vào `model_*.bin` / `model_data.h` |
| Input quantization | **Mỗi frame** | uint8 pixel → INT8 dùng `input_scale`,`input_zero_point` | ARM, trước khi DMA |

Có thể loại bỏ bước input quant ở ARM bằng cách **fuse vào layer đầu** trong `conv_cnn` (accept uint8, subtract zero_point trong PE) — đây là design choice hardware, hiện chưa làm.

**Cache coherency:** S_AXI_HPC0_FPD is configured **coherent** (Smart Cache via CCI-400) — ARM writes via cached buffer, DMA reads see latest data without explicit `__clean_dcache()`. If switched to non-coherent HP0_FPD instead, software must flush ARM cache before each DMA kick.

### Block Design (Vivado, see `fpga/vivado_pj/` and `fpga/schematic.png`)
| IP | Role |
|----|------|
| `zynq_ultra_ps_e_0` | Zynq UltraScale+ PS. Master ports: `M_AXI_HPM0_FPD` (→ I-BRAM Port B for firmware reload), `M_AXI_HPM1_FPD` (→ DMA control + conv_cnn control + D-BRAM Port B). Slave port: `S_AXI_HPC0_FPD` (← AXI DMA reads/writes DDR, cache-coherent) |
| `riscv_top_0` | CV32E40P wrapper (FPU=0, COREV_PULP=0); 2 OBI→AXI-Lite bridges (instr + data); `m_axi_instr` → I-BRAM Port A; `m_axi_data` → D-BRAM Port A + DMA control + conv_cnn control. External ports: `fetch_enable_i` (ARM control boot/halt), `irq_conv_cnn_i` (→ MFAST0 = mip[16]), `core_sleep_o` |
| `conv_cnn_0` (v1.1, Pre-Production) | CNN accelerator. `S00_AXI` = control/status, `S00_AXIS` = IFM+weights stream in, `M00_AXIS` = OFM stream out, `irq` = done interrupt |
| `axi_dma_0` | DDR ↔ AXI-Stream bridge. MM2S reads IFM/weights from DDR → conv_cnn; S2MM writes OFM from conv_cnn → DDR. Both M_AXI ports route via `smartconnect_1` to `S_AXI_HPC0_FPD` |
| `axi_bram_ctrl_0` (PortA) + `axi_bram_ctrl_2` (PortB) + `blk_mem_gen_2` | **I-BRAM dual-port**, 64 KB. Port A = RISC-V instr fetch, Port B = ARM firmware reload |
| `axi_bram_ctrl_1` (PortA) + `axi_bram_ctrl_3` (PortB) + `blk_mem_gen_1` | **D-BRAM dual-port**, 256 KB. Port A = RISC-V data, Port B = ARM shared mem (handshake regs, layer descriptors, quant params) |
| `axi_interconnect_0` | Routes PS + RISC-V control writes to peripherals |
| `smartconnect_1` | Crossbar: DMA M_AXI_MM2S/S2MM ↔ `S_AXI_HPC0_FPD`; HPM1_FPD ↔ DMA control + conv_cnn control + D-BRAM Port B |

**RISC-V external wires trong BD** (dây dẫn rời, không qua AXI):
- `conv_cnn_0.irq` → `riscv_top_0.irq_conv_cnn_i` (level interrupt: high khi conv_cnn done, RISC-V dùng MFAST0/`mip[16]`)
- `axi_gpio_0.gpio_io_o[0]` → `riscv_top_0.fetch_enable_i` (ARM control: ghi 0=halt, 1=run)
- `riscv_top_0.core_sleep_o` → `axi_gpio_0.gpio_io_i[0]` (status để ARM poll WFI state)

#### BRAM Topology — Planned Dual-Port Upgrade
Both BRAMs are physically dual-port (RAMB36 on Ultrascale+) but currently configured single-port. Planned upgrade:
| BRAM | Size | Port A | Port B | Rationale |
|------|------|--------|--------|-----------|
| `blk_mem_gen_2` (I-BRAM) | 64 KB | RISC-V `m_axi_instr` | PS via M_AXI_HPM | ARM loads/reloads firmware.bin without halting RISC-V |
| `blk_mem_gen_1` (D-BRAM) | 256 KB | RISC-V `m_axi_data` | PS via M_AXI_HPM | Zero-latency ARM↔RISC-V handshake; holds .data/.bss/stack + DMA descriptors + per-channel quant params cache |

**Resource budget on KV260 (xck26, 144 RAMB36 = 648 KB total BRAM):**
- I-BRAM 64 KB ≈ 16 RAMB36
- D-BRAM 256 KB ≈ 64 RAMB36 (Vivado may map to URAM for blocks ≥ 32 KB)
- Combined ≈ 56% of BRAM budget, leaving ~64 RAMB36 + all 64 URAMs for future weight buffer / line buffer expansion in conv_cnn IP

Each upgraded BRAM needs **two** `axi_bram_ctrl` instances (one per port). Configure `blk_mem_gen` write mode to "Write First". Software must enforce coherency (separate write regions per master, or semaphore at fixed address).

### Key RTL Modules
| File | Role |
|------|------|
| `hw_src/riscv_top.sv` | RISC-V core wrapper. Custom OBI struct (IdWidth=1 to match `ObiDefaultConfig`); 2× `obi_to_axi` instances với `MaxRequests=4`. Exposes `m_axi_instr` + `m_axi_data` AXI-Lite master ports + `fetch_enable_i` / `irq_conv_cnn_i` / `core_sleep_o` |
| `hw_src/obi_to_axi.sv` | Protocol bridge: OBI → AXI4-Lite (ETH Zurich vendor code). Sử dụng `fifo_v3` để track outstanding txns. `AxiLite=1`, `MaxRequests=4` set bởi caller |
| `hw_src/axi_pkg.sv`, `hw_src/obi_pkg.sv` | Shared type/parameter packages (vendor) |
| `hw_src/tb_riscv_top.sv` | Smoke testbench: behavioral instr memory đáp NOP, validate fetch advance |

> **Lưu ý**: sau khi sửa `riscv_top.sv` (thêm 3 ports: `fetch_enable_i`, `irq_conv_cnn_i`, `core_sleep_o`), IP `fpga/ip_repo/riscv_top_1_0/` cần **re-package** trong Vivado IP Packager (bump version 1.0 → 1.1) trước khi BD pickup được port mới.

### Common pitfalls khi re-package IP

**Trigger**: Synth fail với `'conv_pkg' is not declared` hoặc tương tự.

**Nguyên nhân**: Khi Vivado IP Packager re-package, file mới (vd. `conv_pkg.sv`) **không tự động** được thêm vào `component.xml`. Phải manual:

1. Trong "Edit in IP Packager" window:
   - Sources → Add Sources → add file mới
   - Verify trong tab "Package IP" → File Groups → cả Synthesis VÀ Simulation fileset đều list file
2. **Compile order**: package files (`*_pkg.sv`) phải ở đầu fileSet (Vivado dùng order trong XML để sort). Có thể edit `component.xml` trực tiếp để move package lên đầu.
3. Re-Package IP → bump version → Refresh in BD → Upgrade Selected.

**Path issue WSL/Windows**: nếu Vivado synth fail với `Failed to create directory 'C'`, đó là do project ở WSL filesystem được mount thành drive Windows (vd. `T:`). Vivado parser nhầm `c:/...` thành Windows path. Fix bằng cách: (a) chạy Vivado for Linux trong WSL2, hoặc (b) copy project sang Windows native path (`C:\Vivado\...`).
| `ip_repo/conv_cnn_1_0/src/conv_core.sv` | Top of accelerator: instantiates FSM + line_buffer + window_3x3 + 9 PE_MACs + adder tree + ReLU + max_pool, exposes AXI-Stream IO |
| `ip_repo/conv_cnn_1_0/src/controller_fsm.sv` | 4-loop nested FSM (Cout → Y → X → Cin) driving `mac_en`, `acc_clear`, `bias_relu_en`, `out_valid`, `done` |
| `ip_repo/conv_cnn_1_0/src/line_buffer.sv` | Configurable BRAM-backed 2-row buffer (MAX_WIDTH=256), produces 3-pixel column. `active_width` from S00_AXI register |
| `ip_repo/conv_cnn_1_0/src/window_3x3.sv` | Shift register turning 3-pixel column into 3×3 window (9 INT8 pixels) |
| `ip_repo/conv_cnn_1_0/src/pe_mac.sv` | Pipelined INT8×INT8 MAC with 32-bit accumulator (DSP48E2-mappable, MREG + PREG) |
| `ip_repo/conv_cnn_1_0/src/max_pool.sv` | 2×2 stride-2 max pool, optional via `pool_en`, BRAM-backed row buffer |

### Conv_CNN v2.0 — Architecture (in-progress redesign)

> **Trạng thái**: v1.x (Sobel-only, port hardcode weights) đang được rewrite thành v2.0 — TFLite INT8 INT8 conv 3×3 đầy đủ.

**v2.0 Datapath**:
```
weights.bin (DDR) ──► AXIS prefix per-layer ──► weight_buf (BRAM)
                                                      │ read by [cnt_cout, cnt_cin]
                                                      │ filter[3×3], bias[int32]
                                                      ▼
ifm AXIS ──► line_buffer (2×MAX_W×cin BRAM) ──► window_3x3 (3×3×cin) ──► 9× pe_mac ──► adder tree
                                                                                              │
                                                                                              ▼ acc(int32)
                                                                                       requantize.sv
                                                                            (bias_add → ×M_q31 → >>shift → +zp → sat → [ReLU])
                                                                                              │
                                                                                              ▼
                                                                                  [maxpool 2×2 optional]
                                                                                              │
                                                                                              ▼ ofm AXIS
```

**Dataflow** (3 vòng lặp lồng, all-serial):
```
load_weights_for_layer()                                  // 1 lần per layer
for (y_in, x_in raster scan input pixel position):        // outer
    for (cin_in 0..num_cin-1): receive 1 IFM sample       // channel-interleaved per pixel
    if (x_in >= 2 && y_in >= 2):                          // window valid (VALID padding)
        for (cnt_cout 0..num_cout-1):                     // middle
            mac_clear; for (cnt_cin 0..num_cin-1) mac_enable   // inner: dot9
            requant_in_valid; wait REQUANT_LATENCY; emit M_AXIS
```

**Cycles per output pixel** ≈ `num_cout × (num_cin + REQUANT_LATENCY + 1_emit)`. Với vgg-tiny worst (L3, cin=32, cout=64): ~2300 cycles/pixel × 12544 pixel ≈ 290 ms tại 100 MHz. Khoảng ~30 fps cho 5 layer — đủ demo.

**Tài nguyên KV260**:
- 9 PE × 1 cin/cycle = 9 DSP (đã có)
- weight_buf 36 KB ≈ 9 RAMB36, line_buffer 16 KB ≈ 4 RAMB36, requantize 64-bit barrel shifter ~1 DSP
- Tổng: ≪ KV260 budget (144 RAMB, 1248 DSP) — còn vô số tài nguyên cho V3.0 parallel cout sau

### Conv_CNN v2.0 — S00_AXI register map (32-byte, 8 × 32-bit registers)

| Offset | Name | RW | Layout |
|--------|------|----|--------|
| `0x00` | GEOMETRY | RW | `width[15:0]`, `height[31:16]` |
| `0x04` | CTRL | RW | bit0=`start`, bit1=`pool_en`, bit2=`mode_load` (1=weight load, 0=infer), bit3=`has_relu` |
| `0x08` | STATUS | RO | bit0=`done` |
| `0x0C` | CHANNELS | RW | `num_cin[15:0]`, `num_cout[31:16]` |
| `0x10` | M_Q31 | RW | `M_q31[30:0]` (Q31 multiplier, unsigned) |
| `0x14` | SHIFT_ZP | RW | `shift[5:0]`, `output_zp[15:8]` (signed int8) |
| `0x18..0x1C` | reserved | — | available for future fields |

Per-layer programming sequence (RISC-V driver `process_one_layer()`):
```
1. Write GEOMETRY, CHANNELS, M_Q31, SHIFT_ZP                   (layer config)
2. Write CTRL.mode_load=1, CTRL.start=1                        (load mode)
3. Stream weights+biases to S00_AXIS via DMA                   (pre-loaded blob in DDR)
4. Poll STATUS.done == 1, then CTRL.start=0, CTRL.mode_load=0  (load complete)
5. Set CTRL.pool_en, CTRL.has_relu, CTRL.start=1               (infer mode)
6. Stream IFM to S00_AXIS, OFM appears on M00_AXIS via DMA
7. Poll STATUS.done == 1, then CTRL.start=0
```

### Conv_CNN v2.0 — File status

| File | v1.x → v2.0 status |
|------|------|
| `src/conv_pkg.sv` | ✅ NEW — parameter package (MAX_WIDTH, MAX_CIN, MAX_COUT, widths, latencies) |
| `src/requantize.sv` | ✅ NEW — TFLite INT8 requantize (bias + Q31 mul + shift + zp + saturate + ReLU), 3-stage pipelined |
| `src/controller_fsm.sv` | ✅ REWRITE — 6 counters, 6 states; channel-interleaved per pixel + serial cnt_cout; outputs row_advance cho line_buffer |
| `src/line_buffer.sv` | ✅ REWRITE — 2 BRAM bank × MAX_W × MAX_CIN, read-before-write, parity-toggled; 1-cycle BRAM read latency |
| `src/window_3x3.sv` | ✅ REWRITE — 3×3×MAX_CIN register array, shift cols on `shift_cols`, combinational 9-pixel read theo `cnt_cin` |
| `src/weight_buf.sv` | ✅ NEW — 9 RAM ĐỘC LẬP (qua `generate` block, mỗi RAM 4 KB = 1 RAMB18) cho weights + LUTRAM bias INT32; ⚠️ trước đây dùng 3D unpacked `[K_TAPS][MAX_COUT][MAX_CIN]` → Vivado fail BRAM inference, bùng 295K FFs → fix bằng cách tách thành 9 mảng 2D độc lập |
| `src/conv_core.sv` | ✅ REWRITE — top integration: load FSM (AXIS→weight_buf), infer FSM call, pipeline alignment registers, adder tree, requantize. ~270 LoC |
| `src/pe_mac.sv` | ✅ KEEP — INT8×INT8 MAC pipelined (DSP48 mappable) |
| `src/max_pool.sv` | ⚠️ UPDATE — fix output stride khi pool_en (P0.5) |
| `hdl/conv_cnn_v1_0_S00_AXI.v` | ✅ EXTEND — bumped ADDR_WIDTH 4→5, slv_reg0..7 wired ra width/height/ctrl/status/num_cin-cout/M_q31/shift/zp |
| `hdl/conv_cnn_v1_0.v` | ✅ REWRITE — top wrapper integrate new AXI register file + conv_core, remove hardcoded Sobel weights, AXIS data/8 byte truyền thẳng |

### Memory Map

**RISC-V view (`m_axi_instr` + `m_axi_data`, 32-bit address):**
| Address | Size | Slave | Purpose |
|---------|------|-------|---------|
| `0x0000_0000` | 64 KB | I-BRAM Port A (`axi_bram_ctrl_0`) | Instruction fetch — `.text`, `.rodata`. RISC-V boot vector |
| `0xB000_0000` | 64 KB | `axi_dma_0/S_AXI_LITE` | DMA descriptor registers (MM2S_SA, MM2S_LENGTH, S2MM_DA, S2MM_LENGTH, CTRL/STATUS) |
| `0xB001_0000` | 64 KB | `conv_cnn_0/S00_AXI` | conv_cnn control: CMD, STATUS, num_cin, num_cout, active_width, pool_en, BBox result regs |
| `0xB004_0000` | 256 KB | D-BRAM Port A (`axi_bram_ctrl_1`) | `.data`, `.bss`, stack, shared handshake regs |

> Note: RISC-V data peripherals/BRAM được đặt cùng dải `0xB0xx_xxxx` với PS view để cùng địa chỉ logic — ARM và RISC-V có thể trao đổi pointer/offset trực tiếp. I-BRAM phải ở `0x0` cho RISC-V boot vector.

**PS view (ARM, via M_AXI_HPM0/HPM1_FPD):**
| Address | Size | Slave | Purpose |
|---------|------|-------|---------|
| `0xA000_0000` | 64 KB | I-BRAM Port B (`axi_bram_ctrl_2`, HPM0) | ARM nạp/reload firmware.bin |
| `0xB000_0000` | 64 KB | `axi_dma_0/S_AXI_LITE` (HPM1) | (Optional) ARM kicks DMA directly |
| `0xB001_0000` | 64 KB | `conv_cnn_0/S00_AXI` (HPM1) | ARM writes CMD_START, reads STATUS/BBox |
| `0xB004_0000` | 256 KB | D-BRAM Port B (`axi_bram_ctrl_3`, HPM1) | ARM ↔ RISC-V shared mem (layout chi tiết bên dưới) |

**Shared D-BRAM register layout (offset từ `0xB0040000`):**
| Offset | Size | Name | Direction | Mô tả |
|--------|------|------|-----------|-------|
| `+0x00` | 4 B | `CMD_FROM_ARM` | ARM → RISC-V | `0x01` = START, `0x00` = idle |
| `+0x04` | 4 B | `STATUS_TO_ARM` | RISC-V → ARM | `0x00` IDLE / `0x01` BUSY / `0x02` DONE |
| `+0x08` | 4 B | `DATASET_ID` | ARM → RISC-V | `0` = INRIA person, `1` = cats_dogs |
| `+0x0C` | 4 B | `RESULT_CLASS` | RISC-V → ARM | argmax `∈ {0, 1}` |
| `+0x10` | 4 B | `RESULT_CONF` | RISC-V → ARM | confidence Q1.7 (0..127) |
| `+0x18` | 4 B | `IFM_PHYS_ADDR` | ARM → RISC-V | DDR phys addr buffer A (input ảnh, dùng làm scratch ping-pong) |
| `+0x1C` | 4 B | `OFM_PHYS_ADDR` | ARM → RISC-V | DDR phys addr buffer B (scratch ping-pong / final output) |
| `+0x20` | 4 B | `WEIGHT_BASE` | ARM → RISC-V | DDR phys addr của weights blob (`weights.bin`); RISC-V cộng `LAYERS[i].weight_offset` ra phys addr per layer |
| `+0x24...` | — | (reserved) | — | dành cho mở rộng (per-layer scratch override, IRQ mailbox, …) |
| `+0x3FFFC` | 4 B | `MAILBOX` | bidirectional | tuỳ chọn (debug ping) |

**Layer table:** `LAYERS[]` (mảng `layer_desc_t`) hiện được **link-compile vào RISC-V firmware** (read-only, nằm trong `.rodata` ở I-BRAM). Đổi model ⇒ re-train + re-emit `firmware/riscv/layer_table.h` + re-compile firmware. Tương lai có thể đẩy `LAYERS[]` ra D-BRAM để đổi model không cần re-compile.


**DMA view (`axi_dma_0/Data_MM2S` + `Data_S2MM`, via S_AXI_HPC0_FPD, cache-coherent):**
| Address | Size | Slave | Purpose |
|---------|------|-------|---------|
| `0x0000_0000` | 2 GB | DDR_LOW (PS DDR controller) | IFM / weights / OFM buffers allocated by ARM (CMA / pynq.allocate) |

Update both this table and `firmware/riscv/linked.ld` whenever Vivado Address Editor changes.

### Block Design — Address Editor Validation Issues (RESOLVED)
> **Trạng thái:** ✅ Đã fix (validate sạch, 0 errors / 0 critical warnings). Giữ section này để tham chiếu nếu lỗi tái diễn sau khi sửa BD.

Trước khi fix, validate báo 2 errors + 4 critical warnings, đều xuất phát từ cùng 1 root cause: **SmartConnect đang định tuyến `axi_dma_0/Data_MM2S` và `Data_S2MM` đến `axi_bram_ctrl_1` (D-BRAM Port A)** thay vì chỉ tới DDR qua `S_AXI_HPC0_FPD`. Đồng thời `axi_bram_ctrl_3` (D-BRAM Port B) chưa được assign cho mọi master cần dùng nó.

| # | Code | Diagnostic | Root cause |
|---|------|-----------|-----------|
| 1 | BD 41-1267 | `conv_cnn_0/S00_AXI` map ở `0xB001_0000` (PS) **và** `0x4001_0000` (RISC-V) | Cùng slave phải có cùng offset từ tất cả master AXI cùng đến nó |
| 2 | BD 41-1267 | `axi_bram_ctrl_1/S_AXI/Mem0` map ở `0xB004_0000` (DMA MM2S) **và** `0x1000_0000` (RISC-V) | DMA không được phép thấy `axi_bram_ctrl_1` — đó là Port A của RISC-V, không phải shared mem |
| 3 | BD 5-938 | Memory Depth fail cho `axi_bram_ctrl_1` (disjoint `{0x1000_0000, 0xB004_0000}`) | Hệ quả của #2 — Vivado không tính được depth khi 1 BRAM bị 2 đoạn rời |
| 4 | BD 41-1356 | `axi_bram_ctrl_3/S_AXI/Mem0` chưa assign cho `riscv_top_0/m_axi_data` | RISC-V không cần ghi Port B → **Exclude** thay vì assign |
| 5 | BD 41-1356 | `axi_bram_ctrl_3/S_AXI/Mem0` chưa assign cho `axi_dma_0/Data_S2MM` | DMA không được phép tới BRAM (đi DDR) → **Exclude** |
| 6 | BD 41-1273 | `pre_propagate` TCL fail | Hệ quả của #1–5 |

**Fix đã áp dụng (đã validate sạch):**
1. **Đồng bộ offset RISC-V ↔ PS** (fix BD 41-1267): đổi RISC-V `m_axi_data` sang dải `0xB0xx_xxxx` để khớp PS:
   - `axi_dma_0/S_AXI_LITE`: `0x4000_0000` → `0xB000_0000`
   - `conv_cnn_0/S00_AXI`: `0x4001_0000` → `0xB001_0000`
   - `axi_bram_ctrl_1/S_AXI`: `0x1000_0000` → `0xB004_0000`
2. **Exclude DMA → BRAM** (fix BD 41-1267 #2 + BD 5-938): dưới `axi_dma_0/Data_MM2S` và `Data_S2MM` Exclude cả `axi_bram_ctrl_1/S_AXI` và `axi_bram_ctrl_3/S_AXI`. DMA giữ lại `HPC0_DDR_LOW` + `HPC0_QSPI` (+ `HPC0_LPS_OCM` cho S2MM).
3. **Exclude `axi_bram_ctrl_3` khỏi RISC-V** (fix BD 41-1356): RISC-V chỉ ghi Port A; Port B là của ARM.
4. **Đồng bộ linker + firmware base addresses**: cập nhật [firmware/riscv/linked.ld](firmware/riscv/linked.ld) (DRAM `ORIGIN` 0x10000000 → 0xB0040000) và bất kỳ `#define BASE_*` nào trong `firmware/riscv/`.

**Lưu ý SmartConnect routing:** Nguyên nhân DMA từng "thấy" `axi_bram_ctrl_1` ở `0xB004_0000` là vì cả `axi_dma_0/M_AXI_MM2S/S2MM` và `M_AXI_HPM1_FPD` cùng đi vào `smartconnect_1`, mà SmartConnect mặc định cho phép mọi master tới mọi slave nó kết nối. Đã fix bằng Exclude trong Address Editor (cách (i)). Nếu sau này muốn dọn topology cho rõ ràng có thể tách 2 SmartConnect: một cho HPM1_FPD↔peripherals, một cho DMA↔HPC0_FPD.

### RISC-V BRAM Linker Layout (`firmware/riscv/linked.ld`)
Split layout (must match Vivado Address Editor):
```
MEMORY {
    IRAM (rx)  : ORIGIN = 0x00000000, LENGTH = 64K    /* I-BRAM: .text, .rodata */
    DRAM (rwx) : ORIGIN = 0xB0040000, LENGTH = 256K   /* D-BRAM: .data, .bss, stack */
}
```
Stack top at `ORIGIN(DRAM) + LENGTH(DRAM)` = `0xB008_0000`.

### Visual Memory Map (after BD fix)

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
            │  conv_cnn_0 S00_AXI      │  │ via M_AXI_HPM1_FPD path
            │             (64 KB)      │  │ CMD, STATUS, num_cin/cout, BBox
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
            │  axi_bram_ctrl_2         │  → đẩy vào blk_mem_gen_2 Port B
0xA000_FFFF └──────────────────────────┘
0xB000_0000 ┌──────────────────────────┐  via M_AXI_HPM1_FPD → smartconnect_1
            │  axi_dma_0 S_AXI_LITE    │  (optional) ARM kick DMA trực tiếp
0xB001_0000 ├──────────────────────────┤
            │  conv_cnn_0 S00_AXI      │  ARM ghi CMD_START, đọc STATUS/BBox
0xB002_0000 ├──────────────────────────┤
            │     ... gap ...          │
0xB004_0000 ├──────────────────────────┤
            │  D-BRAM Port B (256 KB)  │  ARM ↔ RISC-V shared mem
            │  axi_bram_ctrl_3         │  layer descriptors, phys ptrs, results
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

## Build Plan / Roadmap

Architecture đã chọn (xem chi tiết ngữ cảnh trong các phần trước):

```
LAYER 4 — TOOLCHAIN     training/train.py emit layer_table.h + weights.bin (Python, PC)
LAYER 3 — HOST          firmware/arm/main.py: I/O, preprocess, argmax (Python, ARM Linux)
LAYER 2 — ORCHESTRATOR  firmware/riscv/main.c: layer-by-layer DMA driver (bare-metal C)
LAYER 1 — DATA PLANE    fpga/ip_repo/conv_cnn_1_0/: 3×3 conv + pool (RTL)
```

Trạng thái triển khai theo các bước (mỗi bước ≈ 1 commit):

| Bước | Mô tả | Trạng thái |
|------|-------|-----------|
| 1 | **Layer 4 contract** — `firmware/riscv/layer_desc.h` định nghĩa `layer_desc_t` struct (geometry + quant params + DDR offsets) | ✅ Done |
| 2 | **Layer 2 interpreter** — `main.c` refactor thành `process_one_layer()` driver, đọc `LAYERS[]`, ping-pong DDR buffer A/B; stub `layer_table.h` 1 layer dummy để compile | ✅ Done |
| 3 | **Layer 4 emitter** — `training/train.py` parse TFLite Conv2D ops → emit `firmware/riscv/layer_table.h` + `<model>.weights.bin`; thêm `--model vgg-tiny` fully-conv 5 layers; ARM main.py allocate ping-pong + GAP/argmax từ DDR | ✅ Done |
| **4** | **Conv_CNN v2.0 rewrite** — coherent redesign (gộp các P0/P1 cũ vì interconnected) | 🔄 In progress |
| 4a | `conv_pkg.sv` — parameter package (MAX_WIDTH/CIN/COUT, datatype widths, REQUANT_LATENCY) | ✅ |
| 4b | `requantize.sv` — TFLite INT8 requantize (3-stage pipelined: bias add + Q31 mul + shift + zp + saturate + ReLU) | ✅ |
| 4c | `controller_fsm.sv` rewrite — 6 nested counters, 6 states, channel-interleaved AXIS, serial cnt_cout | ✅ |
| 4d | `line_buffer.sv` extend cho cin: 2×MAX_W×cin BRAM bank, read-before-write, parity toggle | ✅ |
| 4e | `window_3x3.sv` extend: 3×3×cin reg array, shift cols on window_load_en, combinational read | ✅ |
| 4f | `weight_buf.sv` NEW: storage 9-BRAM weights + LUTRAM bias, write/read port (load FSM ở conv_core) | ✅ |
| 4g | `conv_core.sv` rewrite top: ráp tất cả module, AXIS load/infer demux, pipeline align + adder tree | ✅ |
| 4h | S00_AXI extend slv_reg0..7 + top wrapper rewrite (remove Sobel hardcode, wire 12 cfg signals) | ✅ |
| 4i | Maxpool deferred to Phase B (stride-2 conv), vgg-tiny architecture không pool | ✅ |
| 4j | Integrated testbench `tb_conv_core.sv` — viết xong; iverilog không support unpacked-array output port write hiệu quả → cần Vivado xsim để verify | ⏳ Vivado |
| 5 | End-to-end — Tiny-VGG cats_dogs, accuracy ≥ 80% trên test set, latency báo cáo | ⏳ goal |
| 6 | (Stretch B) — VGG11 + ResNet18 (cần thêm PAD_SAME + element-wise add unit) | ⏳ stretch |
| 7 | Optimization — tăng PE từ 9 → 9×N (parallel cout) khi tài nguyên cho phép | ⏳ stretch |

### Đường đi đề xuất (capstone scope, 10 tuần)

```
Phase A (tuần 1-6)  ━━━━━━ vgg-tiny end-to-end           ✅ doing now
                            (binary classification, INRIA + cats_dogs)
                              │
Phase B (tuần 7-8)  ━━━━━━━ + VGG11 + ResNet18           Tier 2 ext
                            (PAD_SAME, stride 2, skip add)
                              │
Phase C (tuần 9-10) ━━━━━━━ + ResNet50 + YOLOv3-Tiny     Tier 3 stretch
                            (1×1 conv mode, leaky-ReLU, upsample)
                              │
                          ━━━━ STOP ━━━━
                              │
Future Work (post-capstone): MobileNet / EfficientNet / YOLO-Fastest
                             (cần depthwise — datapath rework lớn, không demo)
```

**Tier 1 → 2 → 3 đều incremental** (không phá ABI v2.0): mỗi op mới = thêm enum value `activation_t` / `padding_t` / `kernel_size`, hoặc thêm 1 mode bit ở `conv_core` MUX. Layer table contract (`layer_desc.h`) đủ rộng cho cả 3 tier — không cần re-compile firmware/training pipeline khi thêm op.

**Tier 4 (depthwise) là barrier**: dataflow ngược (mỗi cin → 1 output thay vì sum across cin) → cần MUX adder tree + FSM mode khác. Effort ~3-4 tuần RTL, vượt scope capstone. Ghi vào "Future Work" của report.

**Anti-patterns đã loại trừ:**
- KHÔNG cho RISC-V chạy CNN bằng software (không có FPU; verify bằng TFLite Interpreter ở PC).
- KHÔNG tự viết DMA engine — dùng `axi_dma_0` Xilinx.
- KHÔNG cố làm "CNN-agnostic"/DPU — cố định 3×3 + bias + ReLU + pool, làm đúng và nhanh.
- KHÔNG dùng VGG16/ResNet50V2 từ `tf.keras.applications` cho demo (quá lớn, có ops chưa hỗ trợ).
- KHÔNG dùng OS trên RISC-V (bare-metal, fits 64 KB I-BRAM).

## On-Board Deployment (Kria KV260, Ubuntu 22.04)
```bash
sudo fpgautil -b <bitstream>.bit    # load PL bitstream
sudo python3 firmware/arm/main.py   # start ARM host controller
```
Transfer files via `scp`. Board requires `python3-opencv` and `python3-numpy`.
