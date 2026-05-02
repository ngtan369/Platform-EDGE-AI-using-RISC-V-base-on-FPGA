**Specification**
# 1. Hardware Specification Layer
inside folder fpga there have 3 sub folder 
\fpga
\vivado_project
\repo 
\hw_src  (add hw design here)
    |-----  cv32e40p (riscv core)

\ip_repo (add ip here)
    |--------conv_cnn (axi stream + axi lite)
    |--------riscv_axi (obi to axi)

## conv_cnn
input ảnh 128x128, 224x224
conv layer
conv_std.v (3x3)
conv_dw.v (3x3)
pooling.v
window3x3.v



# 2. Linker Layer
```
For arm/zynq:
qynq-sdk (Ubuntu)
python , pip install qynq
python -c "from qynq import Xillybus ... "
gcc -mcpu=cortex-a53 -march=armv8-a+crc -mtune=cortex-a53 -g -Wall -O2 -Wl,-T,Linker.ld,memory_map.h -o firmware.elf firmware.c

```
For riscv C program:
Toolchain 
xpack-riscv-none-elf-gcc-13.2.0-2
\firmware
Linker.ld
memory_map.h
startup.s

# 3. Application Layer 

\trainng
 Sử dụng mạng CNN std: cnn standard Hardware-Software Co-design + Stadard CNN
