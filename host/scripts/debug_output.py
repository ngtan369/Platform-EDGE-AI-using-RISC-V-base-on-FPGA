"""Verify whether OFM actually varies per image — no TFLite needed."""
import sys, time
sys.path.insert(0, '/home/ubuntu/edgeai/host')
import numpy as np
from pynq import allocate
from edge_ai import EdgeAIOverlay, load_meta, load_weights_blob, preprocess_image, gap_argmax

BIT     = "/home/ubuntu/edgeai/hw/artifacts/kria_soc_wrapper.bit"
FW      = "/home/ubuntu/edgeai/firmware/firmware.bin"
WEIGHTS = "/home/ubuntu/edgeai/training/export/vgg-tiny_cats_dogs.weights.bin"
LTABLE  = "/home/ubuntu/edgeai/training/export/vgg-tiny_cats_dogs.layer_table.bin"
SAMPLES = ["/home/ubuntu/edgeai/samples/cat_01.jpg",
           "/home/ubuntu/edgeai/samples/cat_02.jpg",
           "/home/ubuntu/edgeai/samples/dog_01.jpg"]

ov = EdgeAIOverlay(BIT)
meta = load_meta(WEIGHTS)
fpga = meta["fpga"]

ov.clear_shared_regs()
ov.load_firmware(FW)
ov.load_layer_table(LTABLE)
time.sleep(0.3)

wbytes = load_weights_blob(WEIGHTS)
wbuf = allocate(shape=(len(wbytes),), dtype=np.uint8)
wbuf[:] = np.frombuffer(wbytes, dtype=np.uint8); wbuf.flush()
pp = fpga["max_tensor_bytes"]
buf_a = allocate(shape=(pp,), dtype=np.int8)
buf_b = allocate(shape=(pp,), dtype=np.int8)
ov.set_weights_addr(wbuf.physical_address)
ov.set_io_buffers(buf_a.physical_address, buf_b.physical_address)
ov.set_dataset_id(meta["dataset_id"])

H, W, C_ = fpga["final_ofm_shape"][-3:]
print(f"Final OFM shape = ({H}, {W}, {C_}), scale={fpga['final_ofm_scale']:.6f}, zp={fpga['final_ofm_zp']}")
print(f"final_ofm_buf_idx = {fpga['final_ofm_buf_idx']} ({'buf_a' if fpga['final_ofm_buf_idx']==0 else 'buf_b'})")
print(f"Input quant: scale={meta['input']['scale']:.6f}, zp={meta['input']['zero_point']}")
print()

ofm_dumps = []
for img_path in SAMPLES:
    name = img_path.split('/')[-1]
    ifm = preprocess_image(img_path, meta)
    print(f"=== {name} ===")
    print(f"  IFM shape={ifm.shape}, dtype={ifm.dtype}")
    print(f"  IFM min={ifm.min()}, max={ifm.max()}, mean={ifm.astype(float).mean():.2f}")
    print(f"  IFM first 16 bytes: {ifm.reshape(-1)[:16].tolist()}")
    flat = ifm.reshape(-1)
    buf_a[:flat.size] = flat; buf_a.flush()

    # Sanity: read back buf_a to verify write
    buf_a.invalidate()
    print(f"  buf_a readback first 16: {bytes(buf_a[:16]).hex()}")

    t0 = time.perf_counter()
    ov.kick()
    ov.poll_done(timeout_s=10.0)
    lat = (time.perf_counter() - t0) * 1000
    ov.reset_cmd()

    final_buf = buf_a if fpga["final_ofm_buf_idx"] == 0 else buf_b
    final_buf.invalidate()
    ofm = np.frombuffer(final_buf[:H*W*C_], dtype=np.int8).reshape(H, W, C_)
    ofm_dumps.append(ofm.copy())

    print(f"  FPGA OFM min={ofm.min()}, max={ofm.max()}, mean={ofm.astype(float).mean():.2f}")
    print(f"  FPGA OFM[0,0,:]   = {ofm[0,0,:].tolist()}")
    print(f"  FPGA OFM[59,59,:] = {ofm[H//2,W//2,:].tolist()}")
    print(f"  FPGA OFM[117,117,:] = {ofm[H-1,W-1,:].tolist()}")
    print(f"  Unique values per channel: ch0={len(np.unique(ofm[:,:,0]))}, ch1={len(np.unique(ofm[:,:,1]))}")
    cls, conf, logits = gap_argmax(ofm, fpga["final_ofm_scale"], fpga["final_ofm_zp"])
    print(f"  GAP+softmax: logits={logits}, class={cls}, conf={conf:.1f}%  ({lat:.1f}ms)")
    print()

# Cross-image diff
print("=== Cross-image OFM diff ===")
if len(ofm_dumps) >= 2:
    diff_01 = np.abs(ofm_dumps[0].astype(int) - ofm_dumps[1].astype(int))
    diff_02 = np.abs(ofm_dumps[0].astype(int) - ofm_dumps[2].astype(int))
    print(f"  |cat_01 - cat_02|: mean={diff_01.mean():.2f}, max={diff_01.max()}, nonzero={np.count_nonzero(diff_01)}/{diff_01.size}")
    print(f"  |cat_01 - dog_01|: mean={diff_02.mean():.2f}, max={diff_02.max()}, nonzero={np.count_nonzero(diff_02)}/{diff_02.size}")
    if diff_01.max() == 0 and diff_02.max() == 0:
        print("  → OFM identical for all images! Datapath bug (constant output)")
    elif diff_02.mean() < 0.5:
        print("  → OFM barely changes → conv saturating or weights wrong")
