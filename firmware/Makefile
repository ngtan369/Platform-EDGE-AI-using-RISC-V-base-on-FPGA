CROSS_COMPILE = riscv-none-elf-
CC      = $(CROSS_COMPILE)gcc
OBJCOPY = $(CROSS_COMPILE)objcopy

# Tối ưu hóa cho CV32E40P (PULP extensions)
CFLAGS  = -march=rv32imc -mabi=ilp32 -mcmodel=medany -O2 -ffreestanding -nostdlib
LDFLAGS = -T linked.ld -nostdlib

all: firmware.bin

firmware.elf: main.c startup.s
	$(CC) $(CFLAGS) $(LDFLAGS) $^ -o $@

firmware.bin: firmware.elf
	$(OBJCOPY) -O binary $< $@

clean:
	rm -f *.elf *.bin