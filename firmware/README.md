# Firmware Workspace

This directory contains the complete software stack for the Asymmetric Multiprocessing (AMP) system running on the Kria KV260 board. The system is divided into two independent but tightly coupled processing units communicating via Shared Memory (BRAM).

## File Structure

### 1. `main_arm.py` (Host Controller)
- **Target Platform:** ARM Cortex-A53 Core (Ubuntu 24.04 OS).
- **Role:** System Manager (Master).
- **Key Features:**
  - Initializes camera connection and captures real-time video streams.
  - Performs image pre-processing (Resize, Normalize) to prepare inputs for the AI model.
  - Utilizes Memory Mapping (`/dev/mem`) to push INT8 image data into the Data BRAM.
  - Triggers the RISC-V accelerator to start processing.
  - Reads the resulting Bounding Box coordinates from BRAM and overlays them on the display.

### 2. `main_riscv.c` (Hardware Accelerator)
- **Target Platform:** RISC-V CV32E40P Core (Bare-metal).
- **Role:** AI Hardware Accelerator (Slave).
- **Key Features:**
  - Fetches INT8 image matrices from the Data BRAM.
  - Executes compute-intensive matrix multiplication (MAC) operations for the Convolutional Neural Network (Person Detection).
  - Writes the calculated Bounding Box coordinates back to the Shared Memory for the ARM host to read.

## Build Instructions

### For the RISC-V Core
Since the CV32E40P is a 32-bit core supporting the RV32IMC instruction set, you will need the `riscv32-unknown-elf-gcc` cross-compiler toolchain to build the C code into a raw binary file (`.bin`).

```bash
# Example build commands 
riscv32-unknown-elf-gcc -march=rv32imc -mabi=ilp32 -O3 -nostartfiles -T link.ld main_riscv.c -o main.elf
riscv32-unknown-elf-objcopy -O binary main.elf main.bin
```

Note: The generated main.bin file will later be loaded into the Instruction BRAM by the ARM host for execution.

For the ARM Core
Ensure your Ubuntu environment has the required Python libraries installed:

```bash
pip install numpy opencv-python pynq
python3 main_arm.py
```