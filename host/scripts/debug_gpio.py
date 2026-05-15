"""Diagnostic — run this directly in a Jupyter cell (after restarting kernel).
Tests GPIO + RISC-V boot path end-to-end via raw MMIO (bypasses EdgeAIOverlay)."""
import time
from pynq import Overlay, MMIO

BIT = "/home/ubuntu/edgeai/hw/artifacts/kria_soc_wrapper.bit"
FW  = "/home/ubuntu/edgeai/firmware/firmware.bin"

ov = Overlay(BIT)

print("=" * 60)
print("1. ip_dict — is axi_gpio_0 visible to PYNQ?")
print("=" * 60)
keys = sorted(ov.ip_dict.keys())
print(keys)
print(f"  axi_gpio_0 present: {'axi_gpio_0' in ov.ip_dict}")
print(f"  ov.axi_gpio_0 attr: {hasattr(ov, 'axi_gpio_0')}")
if hasattr(ov, "axi_gpio_0"):
    print(f"  type: {type(ov.axi_gpio_0).__name__}")
    g = ov.axi_gpio_0
    if hasattr(g, "channel1"):
        print(f"  channel1 type: {type(g.channel1).__name__}")

print()
print("=" * 60)
print("2. Raw MMIO test — read/write GPIO_DATA @ 0xB0020000")
print("=" * 60)
gpio = MMIO(0xB0020000, 0x10000)
print(f"  GPIO_DATA pre  = 0x{gpio.read(0):08X}")
print(f"  GPIO_TRI  pre  = 0x{gpio.read(4):08X}  (tri-state, 0=output)")
gpio.write(4, 0)        # ensure output
gpio.write(0, 0)        # halt RISC-V
print(f"  GPIO_DATA halt = 0x{gpio.read(0):08X}  (expect 0)")
gpio.write(0, 1)        # start
time.sleep(0.01)
print(f"  GPIO_DATA run  = 0x{gpio.read(0):08X}  (expect 1)")

print()
print("=" * 60)
print("3. Full boot sequence via raw MMIO")
print("=" * 60)
gpio.write(0, 0)        # halt
ibram = MMIO(0xA0000000, 0x10000)
dbram = MMIO(0xB0040000, 0x40000)

with open(FW, "rb") as f:
    data = f.read()
if len(data) % 4:
    data += b"\x00" * (4 - (len(data) % 4))
for i in range(0, len(data), 4):
    ibram.write(i, int.from_bytes(data[i:i+4], "little"))
print(f"  Loaded {len(data)} B firmware → I-BRAM @ 0xA0000000")
print(f"  I-BRAM[0x00] = 0x{ibram.read(0):08X}  (expect 0x1F40006F)")

dbram.write(0x14, 0x00000000)
dbram.write(0x04, 0x00000000)
print(f"  D-BRAM[0x14] cleared = 0x{dbram.read(0x14):08X}")

gpio.write(0, 1)        # release fetch_enable → RISC-V runs
time.sleep(0.5)         # 500 ms for startup.s + initialize_model()

marker = dbram.read(0x14)
status = dbram.read(0x04)
print()
print(f"  D-BRAM[0x14] = 0x{marker:08X}  (expect 0x000000AB — startup.s boot marker)")
print(f"  D-BRAM[0x04] = 0x{status:08X}  (expect 0x00000000 — STATUS IDLE)")
print(f"  GPIO_DATA    = 0x{gpio.read(0):08X}  (expect 0x00000001)")

if marker == 0xAB:
    print("\n[OK] RISC-V booted — boot marker written. Hardware path OK.")
elif gpio.read(0) != 1:
    print("\n[FAIL] GPIO write didn't stick → axi_gpio_0 not reachable on AXI.")
elif ibram.read(0) != 0x1F40006F:
    print("\n[FAIL] I-BRAM doesn't have firmware → I-BRAM Port B routing broken.")
else:
    print("\n[FAIL] GPIO=1, I-BRAM correct, but D-BRAM[0x14] still 0:")
    print("       → fetch_enable not reaching CV32E40P (BD wiring issue), OR")
    print("       → RISC-V running but D-BRAM Port A write path broken, OR")
    print("       → rst_ni stuck asserted")
