<div align="center">
  <img src="https://pakdd.org/archive/pakdd2015/images/543px-Logo-hcmut.svg.png" alt="HCMUT Logo" width="150">
  
  # HO CHI MINH CITY UNIVERSITY OF TECHNOLOGY
  ## FACULTY OF COMPUTER SCIENCE & ENGINEERING
  
  ### 📚 Capstone Project (Spring 2025)
  ### 👨‍🏫 Mentor: Dr. Pham Quoc Cuong (HCMUT - VNU)
</div>

<br>

---

# Heterogeneous Edge-AI Acceleration Platform on FPGA (Kria KV260)

## 🎯 Objectives
This project aims to achieve the following educational goals:
* Understand and apply RISC-V CPU, RISC architecture, Verilog, C, Python.
* Practice skills in deploying Edge AI on FPGA.
* Understand FPGA flows such as AXI bus, TCDM, BRAM, etc.
* Develop the ability to analyze, compare, and evaluate the effectiveness of ANN models through performance metrics.
* Enhance programming, experimenting, and scientific report organization skills.

---

[![Hardware](https://img.shields.io/badge/Hardware-Kria_KV260-orange.svg)]()
[![Core](https://img.shields.io/badge/RISC--V-CV32E40P-blue.svg)]()
[![AI Framework](https://img.shields.io/badge/AI-TensorFlow_Lite-yellow.svg)]()
[![Status](https://img.shields.io/badge/Status-Ongoing-success.svg)]()

## 📌 Project Overview
This project focuses on designing and deploying an end-to-end, hardware-aware Edge-AI platform for real-time **Human Detection**. The system is built on the Xilinx Kria KV260 Vision AI Starter Kit, utilizing a heterogeneous architecture that combines a hard-core ARM Cortex-A53 (running Linux) and a soft-core **RISC-V (CV32E40P)** to manage a custom-designed CNN Accelerator.

### Key Features
* **AI Model:** MobileNetV2 customized for Edge deployment (`alpha=0.5`).
* **Quantization:** Post-Training Quantization (PTQ) to **INT8** via TensorFlow Lite to reduce memory footprint and latency.
* **Hardware Accelerator:** Custom Verilog-based Convolutional Neural Network processing elements.
* **Control Core:** OpenHW Group's CV32E40P (RISC-V) implemented on the FPGA Programmable Logic (PL) region.
* **Data Flow:** AXI4 and AXI-DMA integration for high-throughput image transfer between DDR4 RAM and on-chip SRAM (TCDM).

---

## 📂 Repository Structure

The project is organized strictly following the Hardware/Software Co-design methodology:

```text
DATN/
├── training/       # AI Model development (Python, TensorFlow)
│   ├── main.py     # Training, Quantization, and C-header generation script
│   └── model_data.h# Exported INT8 weights array for bare-metal C
├── FPGA/           # Hardware RTL design (Verilog/SystemVerilog)
│   ├── cpu.v       # AXI4 Wrapper for RISC-V core
│   ├── cv32e40p.v  # CV32E40P RISC-V core source
│   └── ...         # CNN Accelerator modules (PE, Line Buffers)
├── firmware/       # Bare-metal software for RISC-V (C/C++)
│   └── main.c      # Main control loop executing AI inference
├── os/             # Host application running on ARM Cortex-A53 (Linux)
│   └── main.cpp    # OpenCV video capture, pre-processing, and drawing bounding boxes
└── reports/        # Documentation, Block Diagrams, and Vivado timing reports
```

---

## 🚀 How to Run

Follow these steps sequentially to build and deploy the entire system from scratch.

### 1️⃣ Train Model & Generate C-Array Weights
First, prepare the AI model and export the quantized `INT8` weights for the RISC-V core.

```bash
cd training

# 1. Set up and activate Python virtual environment (WSL/Linux recommended)
python3 -m venv .venv
source .venv/bin/activate

# 2. Install dependencies
pip install -r requirements.txt 

# 3. Execute the training and quantization pipeline
python3 main.py
```

This will generate the quantized TFLite model and the `model_data.h` C header containing the INT8 weight array.

---

### 2️⃣ Build the FPGA Hardware (Vivado)
Generate the physical hardware architecture for the Kria KV260.

1. Launch **Xilinx Vivado**.
2. Create a **New Project** and select the Kria KV260 part: `xck26-sfvc784-2LV-c`.
3. Add all `.v` and `.sv` sources from the `FPGA/` directory to the project.
4. Open **IP Integrator** and build the Block Design (integrate Zynq MPSoC, CV32E40P IP, and AXI DMA).
5. Click **Generate Bitstream**.

✅ **Success Check**: Vivado will generate a `.bit` (or `.pdi`) file in the `runs` directory.

---

### 3️⃣ Compile the RISC-V Firmware
Compile the bare-metal C code, embedding the AI model weights generated in Step 1.

```bash
cd firmware

# Compile the firmware using the RISC-V GNU Toolchain
riscv32-unknown-elf-gcc -O2 -I../training -o riscv_fw.bin main.c 
```

✅ **Success Check**: A `riscv_fw.bin` executable is created in the `firmware/` folder.

---

### 4️⃣ Deploy & Run on Kria KV260
Move the generated files to the board and start the inference engine.

1. Boot the Kria KV260 board using an SD Card flashed with **Ubuntu**/**PetaLinux**.
2. Transfer the `.bit` file (from Step 2) and `riscv_fw.bin` (from Step 3) to the board.
3. On the board terminal, load the hardware bitstream into the Programmable Logic (PL):

```bash
sudo fpgautil -b <your_bitstream_name>.bit
```

4. Load the RISC-V firmware into the BRAM/TCDM using your preferred loader (e.g., custom bare-metal loader, PetaLinux app, or XSDB script).
5. Navigate to the `os/` directory on the board, compile, and run the Host Application to start the camera feed:

```bash
cd os
make
./run_inference
```

The application should start the camera, stream video, and display bounding boxes for detected humans in real time.