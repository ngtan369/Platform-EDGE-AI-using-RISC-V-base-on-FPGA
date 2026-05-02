# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working in this repository.

## Project Overview

Heterogeneous Edge-AI Acceleration Platform targeting the Xilinx Kria KV260 (`xck26-sfvc784-2LV-c`). A standard CNN model (INT8 quantized) runs inference across two compute cores: an ARM Cortex-A53 host controller and a CV32E40P RISC-V soft-core that drives a custom CNN accelerator in the FPGA fabric. The training pipeline supports multiple CNN architectures (VGG, ResNet, EfficientNet, YOLO variants) and two datasets (INRIA Person detection, Cats vs. Dogs classification).

## Repository Structure

```
training/        # Python — model training, INT8 quantization, C-header weight export
fpga/
  hw_src/        # SystemVerilog RTL — RISC-V wrapper, OBI→AXI bridge, CNN accelerator
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

# CLI args: --model [vgg11|vgg16|resnet18|tiny-yolo|yolo-fastest|efficientnet-lite]
#           --dataset [inria|cats_dogs]
#           --epochs <int>          (default: 50)
#           --export_dir <path>     (default: ./export)
python3 main.py --model resnet18 --dataset inria

# Output: ./export/{model}_{dataset}_int8.bin  (PTQ INT8, TFLite format)
# Note: training uses 224×224 input; FPGA inference uses 128×128 (resize on ARM before write to BRAM)
```

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
- `fpga/hw_src/conv_cnn/tb_conv_core.sv`
- `fpga/hw_src/conv_cnn/tb_conv_cnn.v`
- `fpga/cv32e40p/example_tb/` — reference bare-metal RISC-V test

### Submodule Init
```bash
git submodule update --init
```

## Architecture

### Data Flow (DDR + AXI-Stream + AXI-DMA)
```
Camera → ARM (main.py)
  → preprocess INT8 image + load INT8 weights into PS-DDR
  → set CMD_START at 0x40000000 (control register on conv_cnn S00_AXI)

RISC-V (main.c)
  → polls CMD register
  → programs axi_dma_0 (S_AXI_LITE) descriptors:
       MM2S: DDR (image/weights/IFM) → M_AXIS_MM2S → conv_cnn S00_AXIS
       S2MM: conv_cnn M00_AXIS       → S_AXIS_S2MM → DDR (OFM)
  → starts conv_cnn (S00_AXI control), waits on irq or polls status
  → loops layer-by-layer: re-program DMA, stream weights+IFM, collect OFM
  → after final layer, writes bounding box / class to shared regs
  → sets STATUS_DONE at 0x40000004

ARM
  → reads result, draws OpenCV overlay
```

### Block Design (Vivado, see `fpga/vivado_pj/`)
| IP | Role |
|----|------|
| `zynq_ultra_ps_e_0` | Zynq UltraScale+ PS — provides DDR, two `M_AXI_HPM*_FPD` ports for control, `S_AXI_HP*_FPD` for DMA back into DDR |
| `riscv_top_0` | CV32E40P wrapper; `m_axi_instr` → instruction BRAM, `m_axi_data` → AXI interconnect (peripherals) |
| `conv_cnn_0` (v1.1) | CNN accelerator. `S00_AXI` = control/status, `S00_AXIS` = IFM+weights stream in, `M00_AXIS` = OFM stream out, `irq` = done interrupt |
| `axi_dma_0` | DDR ↔ AXI-Stream bridge. MM2S feeds conv_cnn; S2MM drains it |
| `axi_bram_ctrl_0` + `blk_mem_gen_2` | RISC-V instruction memory (firmware.bin, 64 KB) |
| `axi_bram_ctrl_1` + `blk_mem_gen_1` | Data scratchpad / RISC-V .data section |
| `axi_interconnect_0` | Routes PS + RISC-V control writes to peripherals |
| `smartconnect_1` | High-throughput crossbar between DMA masters and PS HP ports (DDR access) |

### Key RTL Modules
| File | Role |
|------|------|
| `hw_src/riscv_top.sv` | RISC-V core wrapper; exposes two AXI4-Lite master ports |
| `hw_src/obi_to_axi.sv` | Protocol bridge: CV32E40P OBI → AXI4-Lite |
| `hw_src/conv_cnn/conv_core.sv` | CNN accelerator FSM; drives 9 MAC arrays |
| `hw_src/conv_cnn/pe_mac.sv` | Single processing element with multiply-accumulate |
| `hw_src/conv_cnn/line_buffer.sv` | Sliding-window line buffer feeding the 3×3 window |

### Memory Map
| Address | Owner | Purpose |
|---------|-------|---------|
| `0x00000000` | RISC-V | Instruction BRAM (firmware.bin, 64 KB) |
| `0x40000000` | ARM↔RISC-V | conv_cnn control: CMD (start), STATUS, layer config |
| `0x40000004` | RISC-V writes | Status (0=idle, 1=busy, 2=done) |
| `0x40000008–0x14` | RISC-V writes | Bounding box / classification result |
| `0x4xxx_xxxx` | RISC-V writes | axi_dma_0 S_AXI_LITE control (descriptor regs) |
| PS-DDR (`0x000_xxxx_xxxx` HP-mapped) | ARM allocates | INT8 weights, IFM (input feature map), OFM (output feature map) — accessed by DMA, not by RISC-V directly |

### RISC-V BRAM Linker Layout (`firmware/riscv/linked.ld`)
Origin `0x00000000`, 64 KB. Sections in order: `.text`, `.rodata`, `.data`, `.bss`, stack.

## On-Board Deployment (Kria KV260, Ubuntu 22.04)
```bash
sudo fpgautil -b <bitstream>.bit    # load PL bitstream
sudo python3 firmware/arm/main.py   # start ARM host controller
```
Transfer files via `scp`. Board requires `python3-opencv` and `python3-numpy`.
