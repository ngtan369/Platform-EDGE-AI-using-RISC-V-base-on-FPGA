"""Debug — after CMD_START times out, read DMA + conv_cnn state to localize the hang."""
import sys, time
sys.path.insert(0, '/home/ubuntu/edgeai/host')
import numpy as np
from pynq import Overlay, allocate, MMIO
from edge_ai import EdgeAIOverlay, load_meta, load_weights_blob, preprocess_image
from edge_ai import constants as C

BIT         = "/home/ubuntu/edgeai/hw/artifacts/kria_soc_wrapper.bit"
FW          = "/home/ubuntu/edgeai/firmware/firmware.bin"
WEIGHTS     = "/home/ubuntu/edgeai/training/export/vgg-tiny_cats_dogs.weights.bin"
LAYER_TABLE = "/home/ubuntu/edgeai/training/export/vgg-tiny_cats_dogs.layer_table.bin"
IMAGE       = "/home/ubuntu/edgeai/samples/cat_01.jpg"

# ---- Setup ----
ov   = EdgeAIOverlay(BIT)
meta = load_meta(WEIGHTS)
fpga = meta["fpga"]

ov.clear_shared_regs()
ov.load_firmware(FW)
ov.load_layer_table(LAYER_TABLE)   # populate D-BRAM @ 0x800 with LAYERS data
time.sleep(0.5)

# Sanity print: confirm layer 0 readable from D-BRAM
dbg = MMIO(0xB0040800, 0x40)
print(f"LAYERS[0] D-BRAM dump (first 24 B):")
for off in range(0, 24, 4):
    print(f"  +{off:#04x}: 0x{dbg.read(off):08X}")
print()

# DDR buffers
wbytes = load_weights_blob(WEIGHTS)
wbuf = allocate(shape=(len(wbytes),), dtype=np.uint8)
wbuf[:] = np.frombuffer(wbytes, dtype=np.uint8); wbuf.flush()
pp_size = fpga["max_tensor_bytes"]
buf_a = allocate(shape=(pp_size,), dtype=np.int8)
buf_b = allocate(shape=(pp_size,), dtype=np.int8)
ifm = preprocess_image(IMAGE, meta)
buf_a[:ifm.size] = ifm.reshape(-1); buf_a.flush()
ov.set_weights_addr(wbuf.physical_address)
ov.set_io_buffers(buf_a.physical_address, buf_b.physical_address)
ov.set_dataset_id(meta["dataset_id"])

print(f"weights phys = 0x{wbuf.physical_address:08X}  ({len(wbytes)} B)")
print(f"buf_a   phys = 0x{buf_a.physical_address:08X}")
print(f"buf_b   phys = 0x{buf_b.physical_address:08X}")
print(f"DMA address width = 32-bit — buffers MUST be < 0x1_0000_0000")
print()

# MMIO handles for direct register access
dma_mmio  = MMIO(0xB0000000, 0x10000)   # axi_dma_0
cnn_mmio  = MMIO(0xB0010000, 0x10000)   # conv_cnn_0
dbram     = MMIO(0xB0040000, 0x40000)   # D-BRAM Port B

def dump_state(tag):
    cmd    = dbram.read(0x00)
    status = dbram.read(0x04)
    dbg_layer = dbram.read(0x24)
    dbg_phase = dbram.read(0x28)
    cnn_geom = cnn_mmio.read(0x00)
    cnn_ctrl = cnn_mmio.read(0x04)
    cnn_stat = cnn_mmio.read(0x08)
    cnn_chan = cnn_mmio.read(0x0C)
    dma_mm2s_cr = dma_mmio.read(0x00)
    dma_mm2s_sr = dma_mmio.read(0x04)
    dma_mm2s_sa = dma_mmio.read(0x18)
    dma_mm2s_len= dma_mmio.read(0x28)
    dma_s2mm_cr = dma_mmio.read(0x30)
    dma_s2mm_sr = dma_mmio.read(0x34)
    dma_s2mm_da = dma_mmio.read(0x48)
    dma_s2mm_len= dma_mmio.read(0x58)
    PHASE_NAMES = {0:"init", 1:"config_regs", 2:"kick_LOAD", 3:"poll_LOAD",
                   4:"LOAD_done_clear", 5:"kick_INFER", 6:"poll_INFER",
                   7:"INFER_done_drain", 8:"layer_complete"}
    print(f"--- {tag} ---")
    print(f"  FIRMWARE @ layer={dbg_layer}  phase={dbg_phase} ({PHASE_NAMES.get(dbg_phase,'?')})")
    print(f"  D-BRAM   CMD={cmd:#010x}  STATUS={status:#010x}  (0=IDLE 1=BUSY 2=DONE)")
    print(f"  conv_cnn GEOM={cnn_geom:#010x}  CTRL={cnn_ctrl:#010x}  STATUS={cnn_stat:#010x}  CHAN={cnn_chan:#010x}")
    print(f"  DMA MM2S CR={dma_mm2s_cr:#010x}  SR={dma_mm2s_sr:#010x}  SA={dma_mm2s_sa:#010x}  LEN={dma_mm2s_len}")
    print(f"  DMA S2MM CR={dma_s2mm_cr:#010x}  SR={dma_s2mm_sr:#010x}  DA={dma_s2mm_da:#010x}  LEN={dma_s2mm_len}")
    print()

dump_state("BEFORE kick")
ov.kick()

# Sample 5x over 5s
for i in range(5):
    time.sleep(1.0)
    dump_state(f"t={i+1}s after kick")

ov.reset_cmd()
print("DONE — reset CMD")
