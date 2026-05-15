"""Trace where the real firmware execution dies.
We rebuild on top of debug_blinky: inject prologue at I-BRAM[0x00] that writes
a SEQUENCE of markers as it progresses, THEN jumps into reset_handler.

Markers:
  D-BRAM[0x14] = 0x11 → executed PC=0x00 (basic fetch works on full firmware path)
  D-BRAM[0x18] = 0x22 → store at second word works
  D-BRAM[0x14] = 0xAB → startup.s reset_handler reached (firmware boot marker)
  STATUS = 0xAA       → main() entered
"""
import time
from pynq import Overlay, MMIO

BIT = "/home/ubuntu/edgeai/hw/artifacts/kria_soc_wrapper.bit"
FW  = "/home/ubuntu/edgeai/firmware/firmware.bin"

ov = Overlay(BIT)
gpio  = MMIO(0xB0020000, 0x10000)
ibram = MMIO(0xA0000000, 0x10000)
dbram = MMIO(0xB0040000, 0x40000)

gpio.write(4, 0)        # output mode
gpio.write(0, 0)        # halt

# Load real firmware (overwrites all I-BRAM)
with open(FW, "rb") as f:
    data = f.read()
if len(data) % 4:
    data += b"\x00" * (4 - (len(data) % 4))
for i in range(0, len(data), 4):
    ibram.write(i, int.from_bytes(data[i:i+4], "little"))
print(f"Loaded {len(data)} B firmware\n")

# Verify what's at key offsets
print("=== Firmware content at key offsets ===")
for off in [0x00, 0x04, 0x80, 0x1F0, 0x1F4, 0x1F8, 0x20C, 0x224, 0x22C, 0x230]:
    print(f"  I-BRAM[0x{off:03X}] = 0x{ibram.read(off):08X}")

# Clear markers
dbram.write(0x14, 0)
dbram.write(0x18, 0)
dbram.write(0x04, 0)
print(f"\nMarkers cleared.")

# Release fetch_enable
gpio.write(0, 1)

# Sample over 2 seconds, watch markers
print("\nReleasing fetch_enable, sampling markers every 100ms...")
for i in range(20):
    time.sleep(0.1)
    m14 = dbram.read(0x14)
    m18 = dbram.read(0x18)
    m04 = dbram.read(0x04)
    print(f"  t={(i+1)*0.1:.1f}s  D-BRAM[0x14]=0x{m14:08X}  [0x18]=0x{m18:08X}  STATUS=0x{m04:08X}")
    if m14 != 0 or m18 != 0 or m04 != 0:
        # Found activity, dump full state
        break

print()
print("=== Final state ===")
print(f"  D-BRAM[0x14] = 0x{dbram.read(0x14):08X}  (expect 0xAB → startup.s boot marker)")
print(f"  D-BRAM[0x04] = 0x{dbram.read(0x04):08X}  (expect 0x00 → STATUS_IDLE from main)")
print(f"  GPIO_DATA    = 0x{gpio.read(0):08X}  (expect 1)")

# Try reading I-BRAM[0] one more time — maybe RISC-V data port is interfering
print(f"  I-BRAM[0x00] = 0x{ibram.read(0):08X}  (firmware still loaded?)")
