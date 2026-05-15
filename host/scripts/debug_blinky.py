"""Blinky test — bypass full firmware. Inject 6-instruction loop directly into I-BRAM,
then check if counter at D-BRAM[0x14] increments.

If counter changes → RISC-V is executing, but real firmware has a bug.
If counter stays 0 → RISC-V is NOT executing at all (clock/fetch_enable/reset issue).
"""
import time
from pynq import Overlay, MMIO

BIT = "/home/ubuntu/edgeai/hw/artifacts/kria_soc_wrapper.bit"

ov = Overlay(BIT)
gpio  = MMIO(0xB0020000, 0x10000)
ibram = MMIO(0xA0000000, 0x10000)
dbram = MMIO(0xB0040000, 0x40000)

# Halt RISC-V
gpio.write(4, 0)       # TRI = output
gpio.write(0, 0)       # halt

# ---------------------------------------------------------------
# Build a 6-instruction blinky firmware (placed at I-BRAM offset 0):
#
#   0x00: lui   t0, 0xb0040     # t0 = 0xB004_0000  (D-BRAM base)
#   0x04: lw    t1, 0x14(t0)    # t1 = mem[t0 + 0x14]
#   0x08: addi  t1, t1, 1       # t1++
#   0x0C: sw    t1, 0x14(t0)    # mem[t0 + 0x14] = t1
#   0x10: jal   x0, -16         # j 0x04 (loop forever)
# ---------------------------------------------------------------
# RISC-V instruction encodings (RV32I, 32-bit, little-endian):
#   lui t0, 0xb0040       → 0xb00402b7
#   lw t1, 0x14(t0)       → 0x0142a303
#   addi t1, t1, 1        → 0x00130313
#   sw t1, 0x14(t0)       → 0x0062aa23
#   jal x0, -12 (=0xff4)  → 0xff5ff06f   (j .-12 from pc=0x10 to 0x04)
#
prog = [
    0xb00402b7,  # 0x00: lui   t0, 0xb0040
    0x0142a303,  # 0x04: lw    t1, 20(t0)
    0x00130313,  # 0x08: addi  t1, t1, 1
    0x0062aa23,  # 0x0C: sw    t1, 20(t0)
    0xff5ff06f,  # 0x10: jal   x0, -12 → back to 0x04
]
for i, w in enumerate(prog):
    ibram.write(i * 4, w)
# Verify load
print("Loaded blinky firmware into I-BRAM:")
for i in range(len(prog)):
    print(f"  I-BRAM[0x{i*4:02X}] = 0x{ibram.read(i*4):08X}  (expect 0x{prog[i]:08X})")

# Clear counter
dbram.write(0x14, 0)
print(f"\nD-BRAM[0x14] cleared = 0x{dbram.read(0x14):08X}")

# Release fetch_enable
print("\nReleasing fetch_enable → RISC-V should start incrementing D-BRAM[0x14]...")
gpio.write(0, 1)

# Sample 5 times over 1 second
for i in range(5):
    time.sleep(0.2)
    val = dbram.read(0x14)
    print(f"  t={(i+1)*0.2:.1f}s  D-BRAM[0x14] = {val:>10d}  (0x{val:08X})")

# Final summary
final = dbram.read(0x14)
print()
if final == 0:
    print("[FAIL] Counter never incremented — RISC-V is NOT executing.")
    print("       Possible causes: clock gated, rst_ni stuck, fetch_enable not reaching core,")
    print("       cv32e40p stuck in SLEEP state.")
elif final < 1000:
    print(f"[WARN] Counter only at {final} after 1s — RISC-V executing very slowly or hit trap.")
else:
    print(f"[OK]   Counter = {final} → RISC-V IS executing.")
    print("       Problem is elsewhere (firmware logic, startup.s, BSS clear, main, etc.)")
