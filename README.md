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
Edge-AI Acceleration Platform on FPGA/
├── training/          # AI Model development (Python, TensorFlow)
│   ├── main.py        # Training, Quantization, and C-header generation script
│   └── model_data.h   # Exported INT8 weights array for bare-metal C
│   └── requirements.txt   # Library for python
│   └── mobilenet_v2_128_quant.tflite  # Quantize to int8
├── fpga/           # Hardware RTL design (Verilog/SystemVerilog)
│   ├── hw_src      # AXI4 Wrapper for RISC-V core
│   ├── cv32e40p    # Vendor Openhw Group CV32E40P RISC-V core source
│   └── vivado_pj   # Project Vivado, Add file from hw_src, cv32e40p. Adding IP Block
├── firmware/       # Bare-metal software for RISC-V (C/C++)
│   └── main.c      # Main control loop executing AI inference - Using xpack-riscv-none-elf-gcc-13.2.0-2
└── reports/        # Documentation, Block Diagrams, and Vivado timing reports
    └── main.pdf    # Final compiled report
```

---

## 📊 Dataset

This project uses the **INRIAPerson** dataset from Kaggle for training and evaluation.

- Kaggle dataset: https://www.kaggle.com/datasets/jcoral02/inriaperson
- Original dataset: Dalal, N. and Triggs, B., *Histograms of Oriented Gradients for Human Detection*, CVPR 2005.

We thank the Kaggle contributor **jcoral02** and the original authors for providing the dataset.

---

## 🚀 How to Run

Follow these steps sequentially to build and deploy the entire system from scratch.

### 0️⃣ Prerequisites & Board Setup (on kit KV260)
Before running any hardware or software configurations, the Kria KV260 board must be provisioned with an operating system.

1. **Download the OS Image:** Download the official [Ubuntu 22.04 LTS image for Kria KV260](https://ubuntu.com/download/amd) provided by Canonical/Xilinx.
2. **Flash the SD Card:** Use a tool like **BalenaEtcher** or **Rufus** to flash the downloaded `.img` file onto a MicroSD card (16GB or larger).
3. **Boot the Board:** Insert the SD card into the board, connect an Ethernet cable (to your local router), and power it on.
4. **Connect via SSH:** Find the board's IP address and access it from your development PC:

```bash
ssh ubuntu@<board_ip_address>
```

Install Dependencies: On the board's terminal, install the required Python libraries for the host application:

```bash
sudo apt update
sudo apt install python3-opencv python3-numpy
```

(Once this step is done, the SD card remains in the board permanently. All subsequent development files will be transferred over the network via SSH/SCP).

Detail manual: https://xilinx.github.io/kria-apps-docs/kv260/2022.1/linux_boot/ubuntu_22_04/build/html/docs/known_issues.html

### 1️⃣ Train Model & Generate C-Array Weights on Host PC
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

> Note: If the `cv32e40p` core is not present under `fpga/`, clone it first:
>
> ```bash
> cd fpga
> git clone https://github.com/openhwgroup/cv32e40p.git
> ```

1. Launch **Xilinx Vivado**.
2. Create a **New Project** and select the Kria KV260 part: `xck26-sfvc784-2LV-c`.
3. Add all `.v` and `.sv` sources from the `fpga/hw_src` directory to the project.
3. Add `rtl` sources from the `fpga/cv32e40p` folder to the project.
4. Open **IP Integrator** and build the Block Design (integrate Zynq MPSoC, CV32E40P IP, and AXI DMA).
5. Click **Generate Bitstream**.

✅ **Success Check**: Vivado will generate a `.bit` (or `.pdi`) file in the `runs` directory.

---

### 3️⃣ Compile the RISC-V Firmware
Compile the bare-metal C code, embedding the AI model weights generated in Step 1.

```bash
cd firmware

# Compile the firmware using the RISC-V GNU Toolchain
riscv-none-elf-gcc-13.2.0-2 -O2 -I../training -o riscv_fw.bin main.c 
```

✅ **Success Check**: A `riscv_fw.bin` executable is created in the `firmware/` folder.

---

### 4️⃣ Deploy & Run on Kria KV260
Move the generated files to the board and start the inference engine.

**Step 4.1: Access the Board's Terminal**
You can interact with the Kria KV260 board running Ubuntu/PetaLinux using one of these methods:
* **Method A (SSH / Headless):** Connect the board to your local network via Ethernet. Open a terminal on your PC and SSH into the board (e.g., `ssh ubuntu@<board_ip>`).
* **Method B (Direct Setup):** Plug a USB keyboard and a DisplayPort/HDMI monitor directly into the board and open the local terminal.

**Step 4.2: Transfer Files**
Transfer the hardware bitstream (`.bit`), the RISC-V firmware (`riscv_fw.bin`), and the host application script (`main_arm.py`) to the board using `scp` or a USB drive.

**Step 4.3: Execute the Hardware & Software**
On the board's terminal, load the hardware bitstream into the Programmable Logic (PL):

```bash
sudo fpgautil -b <your_bitstream_name>.bit
```
Next, load the RISC-V firmware into the shared memory space so the CV32E40P core can boot. Finally, execute the ARM host application to initialize the camera and manage communication:


```bash
sudo python3 main_arm.py
```
The application will start the camera stream and display bounding boxes around detected humans in real time on the connected monitor.