"""
Training + INT8 quantization + layer-table emitter cho Edge-AI FPGA pipeline.

Pipeline:
  1. Build Keras model (default = `vgg-tiny`: fully-conv, last layer cout=num_classes)
  2. Train (fit) — hiện chỉ stub, cần dataset thật
  3. PTQ INT8 → tflite bytes
  4. Parse TFLite graph → emit:
       firmware/riscv/layer_table.h   (auto-generated, REPLACE stub)
       export/<model>_<dataset>.weights.bin (INT8 weights + INT32 biases packed)
       export/<model>_<dataset>_int8.bin             (TFLite reference)
       export/<model>_<dataset>_int8.bin.meta.json   (ARM runtime metadata)

Sau khi chạy: ARM cần weights.bin + meta.json + bitstream + firmware.bin (re-built).
"""
import os
import json
import math
import struct
import argparse
import textwrap
import numpy as np
import tensorflow as tf
from tensorflow.keras import layers, models, applications

FPGA_INPUT_SIZE = (128, 128)   # ARM resize ảnh tới size này trước khi feed FPGA

LABEL_MAPS = {
    'inria':     ['no_person', 'person'],
    'cats_dogs': ['cat', 'dog'],
}
DATASET_IDS = {'inria': 0, 'cats_dogs': 1}

# ============================================================================
# 1. DATASET (stub — cần thay bằng tf.data.Dataset thật)
# ============================================================================
def load_dataset(dataset_name, batch_size, img_size):
    if dataset_name not in LABEL_MAPS:
        raise ValueError(f"Dataset không hỗ trợ: {dataset_name}")
    print(f"[*] Dataset={dataset_name}, img_size={img_size}, batch={batch_size}")
    num_classes = len(LABEL_MAPS[dataset_name])
    # TODO: implement real tf.data pipeline (read from disk, augment, normalize)
    return None, None, num_classes


def representative_data_gen():
    """100 mẫu ngẫu nhiên cho calibration PTQ (thay bằng val set thật)."""
    H, W = FPGA_INPUT_SIZE
    for _ in range(100):
        yield [np.random.rand(1, H, W, 3).astype(np.float32)]


# ============================================================================
# 2. MODEL FACTORY
# ============================================================================
def build_vgg_tiny(num_classes, input_shape=(128, 128, 3)):
    """
    Fully-convolutional Tiny-VGG cho FPGA accelerator chỉ hỗ trợ 3×3 + ReLU + maxpool.
    Last layer là Conv 3×3 cout=num_classes (KHÔNG có Dense head) — ARM tự GAP + argmax
    sau khi nhận OFM cuối từ DDR.

    Geometry với input 128×128 (valid padding, no padding zero):
       128×128×3 → conv 3×3 cout=8        → 126×126×8
                 → conv 3×3 cout=16, pool → 62×62×16
                 → conv 3×3 cout=32, pool → 30×30×32
                 → conv 3×3 cout=64, pool → 14×14×64
                 → conv 3×3 cout=N (no act) → 12×12×N    ← ARM GAP + argmax
    Tổng: 5 conv layers (vừa với accelerator hiện tại sau P0+P1 fix).
    """
    inputs = tf.keras.Input(shape=input_shape)
    x = layers.Conv2D(8,  3, activation='relu', padding='valid')(inputs)
    x = layers.Conv2D(16, 3, activation='relu', padding='valid')(x)
    x = layers.MaxPooling2D(2)(x)
    x = layers.Conv2D(32, 3, activation='relu', padding='valid')(x)
    x = layers.MaxPooling2D(2)(x)
    x = layers.Conv2D(64, 3, activation='relu', padding='valid')(x)
    x = layers.MaxPooling2D(2)(x)
    # Final conv: no activation (logits), cout = num_classes — fully-conv head
    x = layers.Conv2D(num_classes, 3, activation=None, padding='valid')(x)
    # GAP + softmax đặt ở "post-process" (ARM làm sau khi đọc DDR)
    # Để TFLite biết đầu ra của graph, ta vẫn add GAP+softmax (ARM dùng GAP shape):
    x = layers.GlobalAveragePooling2D()(x)
    outputs = layers.Softmax()(x)
    return models.Model(inputs, outputs, name='vgg_tiny')


def build_legacy_model(model_name, num_classes, input_shape=(224, 224, 3)):
    """
    LEGACY — VGG16/ResNet50V2/EfficientNetB0/MobileNetV2 từ tf.keras.applications.
    Quá lớn cho FPGA accelerator hiện tại + chứa ops chưa hỗ trợ (1×1, DW, BN, ...).
    Giữ lại cho compare / training-only experiments.
    """
    print(f"[!] WARNING: '{model_name}' là model lớn — sẽ KHÔNG export thành công sang layer_table.h.")
    if model_name in ('vgg11', 'vgg16'):
        base = applications.VGG16(weights=None, input_shape=input_shape, include_top=False)
    elif model_name == 'resnet18':
        base = applications.ResNet50V2(weights=None, input_shape=input_shape, include_top=False)
    elif model_name == 'efficientnet-lite':
        base = applications.EfficientNetB0(weights=None, input_shape=input_shape, include_top=False)
    elif model_name in ('tiny-yolo', 'yolo-fastest'):
        base = applications.MobileNetV2(weights=None, input_shape=input_shape, include_top=False)
    else:
        raise ValueError(f"Không hỗ trợ kiến trúc: {model_name}")
    x = layers.GlobalAveragePooling2D()(base.output)
    out = layers.Dense(num_classes, activation='softmax')(x)
    return models.Model(base.input, out)


def build_model(model_name, num_classes):
    if model_name == 'vgg-tiny':
        return build_vgg_tiny(num_classes, input_shape=(*FPGA_INPUT_SIZE, 3))
    return build_legacy_model(model_name, num_classes)


# ============================================================================
# 3. TFLite PTQ + LAYER TABLE EMITTER
# ============================================================================
def quantize_multiplier(M_real: float):
    """
    Convert float multiplier to TFLite (Q31_int, right_shift).
        real_value ≈ (sum * M_q31) >> (31 + right_shift)

    Giả thiết 0 < M_real < 1 (trường hợp typical sau (in_scale*w_scale)/out_scale).
    """
    if M_real <= 0.0:
        return 0, 0
    significand, exponent = math.frexp(M_real)   # M_real = significand * 2^exponent
    q31 = int(round(significand * (1 << 31)))
    if q31 == (1 << 31):
        q31 //= 2
        exponent += 1
    right_shift = -exponent
    if right_shift < 0:
        # M_real >= 1 — chưa hỗ trợ (cần left-shift logic ở RTL requantize)
        print(f"[!] Multiplier >= 1.0 (M={M_real:.4f}) — clip về 31 max shift")
        right_shift = 0
        q31 = (1 << 31) - 1
    return q31, min(right_shift, 31)


# layer_desc_t bytes (must match layer_desc.h __attribute__((packed)))
#   uint32 weight_offset, weight_bytes, bias_offset, bias_bytes      (16 B)
#   uint16 ifm_width, ifm_height, cin, cout                          ( 8 B)
#   uint8  kernel, stride, padding, pool_en, activation, _res[3]     ( 8 B)
#   int32  output_M; int8 output_shift, input_zp, output_zp, w_zp    ( 8 B)
LAYER_DESC_FMT = '<IIII HHHH BBBBB3x i bbbb'   # 40 bytes
assert struct.calcsize(LAYER_DESC_FMT) == 40, "layer_desc_t size mismatch"


def emit_layer_table(tflite_bytes: bytes,
                     header_path: str,
                     blob_path: str):
    """
    Parse TFLite Conv2D ops → pack weights/biases vào blob, emit C header + meta.

    Hạn chế hiện tại:
      - Chỉ hỗ trợ CONV_2D op (3×3 hoặc 1×1) — bỏ qua MAX_POOL_2D, FC, GAP
        (MaxPool fold vào layer trước qua flag pool_en; FC/GAP do ARM xử lý)
      - Dùng per-tensor quantization cho weight (lấy scales[0]) — TFLite mặc định
        per-axis cho weights, nên đây là approx; output có thể lệch ±1 LSB.
        TODO khi RTL hỗ trợ per-channel requant: lưu mảng M cho mỗi cout.
    """
    interp = tf.lite.Interpreter(model_content=tflite_bytes)
    interp.allocate_tensors()
    tensors = interp.get_tensor_details()

    # _get_ops_details là private API nhưng đã ổn định nhiều năm; dễ thay bằng
    # `tflite` package (flatbuffer schema) nếu cần.
    ops = interp._get_ops_details()

    blob = bytearray()
    layer_descs = []
    layer_idx = 0
    pool_pending = False    # MaxPool fold vào layer trước

    final_ofm_tensor = None
    final_ofm_layer  = -1   # index trong layer_descs (0-based)

    for op in ops:
        op_name = op['op_name']

        if op_name == 'MAX_POOL_2D':
            if not layer_descs:
                raise ValueError("MAX_POOL_2D không đứng sau Conv2D — không fold được")
            # Mark layer trước đó với pool_en = 1
            layer_descs[-1]['pool_en'] = 1
            pool_pending = False
            continue

        if op_name != 'CONV_2D':
            continue   # bỏ qua FC, GAP, RESHAPE, QUANTIZE, ...

        in_idx, w_idx, b_idx = op['inputs']
        out_idx = op['outputs'][0]

        in_t  = tensors[in_idx]
        w_t   = tensors[w_idx]
        out_t = tensors[out_idx]
        b_t   = tensors[b_idx] if b_idx >= 0 else None

        in_scale  = float(in_t['quantization_parameters']['scales'][0])
        in_zp     = int(in_t['quantization_parameters']['zero_points'][0])
        out_scale = float(out_t['quantization_parameters']['scales'][0])
        out_zp    = int(out_t['quantization_parameters']['zero_points'][0])
        # Per-axis weight: dùng scales[0] (approx — xem note ở trên)
        w_scales  = w_t['quantization_parameters']['scales']
        w_scale   = float(w_scales[0]) if len(w_scales) > 0 else 1.0
        w_zp      = int(w_t['quantization_parameters']['zero_points'][0])

        # Tensor data
        weights = interp.get_tensor(w_idx)         # int8, shape [cout, kh, kw, cin] (OHWI)
        biases  = interp.get_tensor(b_idx) if b_t else None  # int32, shape [cout]

        cout, kh, kw, cin = weights.shape
        if kh != kw or kh not in (1, 3):
            raise ValueError(f"Layer {layer_idx}: kernel {kh}×{kw} chưa hỗ trợ")

        ih, iw = int(in_t['shape'][1]), int(in_t['shape'][2])

        # Pack weights vào blob (raw bytes, OHWI order)
        weight_offset = len(blob)
        blob.extend(weights.tobytes())
        weight_bytes  = len(weights.tobytes())

        if biases is not None:
            bias_offset = len(blob)
            blob.extend(biases.astype(np.int32).tobytes())
            bias_bytes = biases.size * 4
        else:
            bias_offset = 0xFFFFFFFF
            bias_bytes  = 0

        # Requantize multiplier
        M_real = (in_scale * w_scale) / out_scale if out_scale > 0 else 0.0
        M_q31, shift = quantize_multiplier(M_real)

        # Activation: TFLite fuse activation vào op qua builtin_options.fused_activation_function
        # _get_ops_details không trả về options này → suy luận từ output range:
        #   out_zp = -128 và clip vào [-128, 127] → có ReLU (fused)
        # Heuristic đơn giản: nếu output có signed range [-128, 127] thì ACT_NONE;
        # còn ARM thường thấy [out_zp, 127] với out_zp = -128 thì có ReLU
        # → Để chính xác, parse builtin_options qua flatbuffer (TODO).
        # Tạm thời: ACT_RELU cho mọi conv ngoại trừ layer cuối (heuristic).

        layer_desc = {
            'weight_offset': weight_offset,
            'weight_bytes':  weight_bytes,
            'bias_offset':   bias_offset,
            'bias_bytes':    bias_bytes,
            'ifm_width':     iw,
            'ifm_height':    ih,
            'cin':           cin,
            'cout':          cout,
            'kernel':        kh,
            'stride':        1,         # TODO parse builtin_options
            'padding':       0,         # PAD_VALID — TODO parse padding type
            'pool_en':       0,         # may be set later by MAX_POOL_2D
            'activation':    1,         # ACT_RELU default; layer cuối sẽ override = 0
            'output_M':      M_q31,
            'output_shift':  shift,
            'input_zp':      in_zp,
            'output_zp':     out_zp,
            'weight_zp':     w_zp,
        }
        layer_descs.append(layer_desc)
        final_ofm_tensor = out_t
        final_ofm_layer  = layer_idx
        layer_idx += 1

    if not layer_descs:
        raise ValueError("Không tìm thấy CONV_2D op nào — model không hỗ trợ FPGA pipeline")

    # Layer cuối: tắt activation (logits trước softmax)
    layer_descs[-1]['activation'] = 0  # ACT_NONE

    # Validate sizeof matches between Python pack and C struct
    for L in layer_descs:
        packed = struct.pack(
            LAYER_DESC_FMT,
            L['weight_offset'], L['weight_bytes'], L['bias_offset'], L['bias_bytes'],
            L['ifm_width'], L['ifm_height'], L['cin'], L['cout'],
            L['kernel'], L['stride'], L['padding'], L['pool_en'], L['activation'],
            L['output_M'],
            L['output_shift'], L['input_zp'], L['output_zp'], L['weight_zp'],
        )
        assert len(packed) == 40

    # ---- write weights blob ----
    with open(blob_path, 'wb') as f:
        f.write(blob)
    print(f"[+] Weights blob: {blob_path}  ({len(blob)} bytes, {len(layer_descs)} conv layers)")

    # ---- emit C header ----
    def fmt_layer(L, idx):
        return textwrap.dedent(f"""\
            [{idx}] = {{
                .weight_offset = {L['weight_offset']}u,
                .weight_bytes  = {L['weight_bytes']}u,
                .bias_offset   = {hex(L['bias_offset'])}u,
                .bias_bytes    = {L['bias_bytes']}u,
                .ifm_width     = {L['ifm_width']},
                .ifm_height    = {L['ifm_height']},
                .cin           = {L['cin']},
                .cout          = {L['cout']},
                .kernel        = {L['kernel']},
                .stride        = {L['stride']},
                .padding       = {L['padding']},
                .pool_en       = {L['pool_en']},
                .activation    = {L['activation']},
                ._reserved     = {{0, 0, 0}},
                .output_M      = {L['output_M']},
                .output_shift  = {L['output_shift']},
                .input_zp      = {L['input_zp']},
                .output_zp     = {L['output_zp']},
                .weight_zp     = {L['weight_zp']},
            }}""")

    header = textwrap.dedent(f"""\
        #ifndef LAYER_TABLE_H
        #define LAYER_TABLE_H

        /* AUTO-GENERATED bởi training/main.py — DO NOT EDIT.
         * Re-generate sau mỗi lần re-train. */

        #include "layer_desc.h"

        const uint32_t NUM_LAYERS = {len(layer_descs)};

        const layer_desc_t LAYERS[{len(layer_descs)}] = {{
        """)
    for i, L in enumerate(layer_descs):
        header += textwrap.indent(fmt_layer(L, i), '    ')
        header += ',\n'
    header += '};\n\n#endif /* LAYER_TABLE_H */\n'

    with open(header_path, 'w') as f:
        f.write(header)
    print(f"[+] Layer table:  {header_path}  ({len(layer_descs)} layers)")

    # Tính max tensor size (cho ARM allocate ping-pong buffer)
    max_bytes = 0
    for L in layer_descs:
        ifm = L['ifm_width'] * L['ifm_height'] * L['cin']
        ow  = L['ifm_width']  - L['kernel'] + 1
        oh  = L['ifm_height'] - L['kernel'] + 1
        if L['pool_en']:
            ow //= 2
            oh //= 2
        ofm = ow * oh * L['cout']
        max_bytes = max(max_bytes, ifm, ofm)

    # Ping-pong logic trong firmware/riscv/main.c:
    #   layer i: in=(i&1)?buf_b:buf_a, out=(i&1)?buf_a:buf_b
    #   → out của layer cuối: i chẵn → buf_b (idx=1), i lẻ → buf_a (idx=0)
    final_buf_idx = 1 if (final_ofm_layer % 2) == 0 else 0

    return {
        'num_layers':        len(layer_descs),
        'weights_blob_size': len(blob),
        'final_ofm_layer':   final_ofm_layer,
        'final_ofm_buf_idx': final_buf_idx,
        'final_ofm_shape':   list(final_ofm_tensor['shape']),
        'final_ofm_scale':   float(final_ofm_tensor['quantization_parameters']['scales'][0]),
        'final_ofm_zp':      int(final_ofm_tensor['quantization_parameters']['zero_points'][0]),
        'max_tensor_bytes':  int(max_bytes),
    }


def export_to_int8(keras_model, output_dir, dataset_name, model_name):
    """PTQ → tflite + parse → emit layer_table.h + weights.bin + meta.json"""
    print("[*] Bắt đầu PTQ INT8...")
    converter = tf.lite.TFLiteConverter.from_keras_model(keras_model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    converter.representative_dataset = representative_data_gen
    converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
    converter.inference_input_type  = tf.int8
    converter.inference_output_type = tf.int8
    tflite_bytes = converter.convert()

    base = f"{model_name}_{dataset_name}"
    tflite_path  = os.path.join(output_dir, f"{base}_int8.bin")
    blob_path    = os.path.join(output_dir, f"{base}.weights.bin")
    meta_path    = tflite_path + '.meta.json'
    header_path  = os.path.join(
        os.path.dirname(__file__), '..', 'firmware', 'riscv', 'layer_table.h'
    )
    header_path = os.path.normpath(header_path)

    with open(tflite_path, 'wb') as f:
        f.write(tflite_bytes)
    print(f"[+] TFLite reference: {tflite_path}")

    # Emit layer table + weights blob
    emit_summary = emit_layer_table(tflite_bytes, header_path, blob_path)

    # Pull input/output quant params for ARM
    interp = tf.lite.Interpreter(model_content=tflite_bytes)
    interp.allocate_tensors()
    in_d  = interp.get_input_details()[0]
    out_d = interp.get_output_details()[0]

    meta = {
        'model':      model_name,
        'dataset':    dataset_name,
        'dataset_id': DATASET_IDS[dataset_name],
        'labels':     LABEL_MAPS[dataset_name],
        'input': {
            'shape':      list(in_d['shape']),
            'dtype':      str(np.dtype(in_d['dtype'])),
            'scale':      float(in_d['quantization'][0]),
            'zero_point': int(in_d['quantization'][1]),
            'fpga_size':  list(FPGA_INPUT_SIZE),
        },
        'output': {        # final TFLite graph output (sau softmax — REFERENCE only)
            'shape':      list(out_d['shape']),
            'dtype':      str(np.dtype(out_d['dtype'])),
            'scale':      float(out_d['quantization'][0]),
            'zero_point': int(out_d['quantization'][1]),
        },
        # Thông tin ARM cần để chạy: ping-pong buffer, last conv OFM (làm GAP+argmax)
        'fpga': emit_summary,
        'weights_file': os.path.basename(blob_path),
    }
    with open(meta_path, 'w') as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)
    print(f"[+] Metadata: {meta_path}")
    print(f"    num_layers={emit_summary['num_layers']}  "
          f"final_ofm_buf_idx={emit_summary['final_ofm_buf_idx']}  "
          f"final_ofm_shape={emit_summary['final_ofm_shape']}")


# ============================================================================
# 4. MAIN
# ============================================================================
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Edge-AI Training & FPGA-Compile Pipeline")
    parser.add_argument('--model', type=str, default='vgg-tiny',
                        choices=['vgg-tiny',
                                 'vgg11', 'vgg16', 'resnet18',
                                 'tiny-yolo', 'yolo-fastest', 'efficientnet-lite'],
                        help="Kiến trúc CNN. Khuyến nghị 'vgg-tiny' (only one supported on FPGA).")
    parser.add_argument('--dataset', type=str, default='cats_dogs',
                        choices=['inria', 'cats_dogs'])
    parser.add_argument('--epochs', type=int, default=10)
    parser.add_argument('--export_dir', type=str, default='./export')
    args = parser.parse_args()

    os.makedirs(args.export_dir, exist_ok=True)

    print("=" * 60)
    print("  Edge-AI Training → FPGA Compile Pipeline")
    print("=" * 60)

    _, _, num_classes = load_dataset(args.dataset, batch_size=32, img_size=FPGA_INPUT_SIZE)
    model = build_model(args.model, num_classes)
    model.compile(optimizer='adam',
                  loss='sparse_categorical_crossentropy',
                  metrics=['accuracy'])
    print(f"[*] Model summary: {model.name}, {model.count_params()} params")

    print(f"[*] (TODO) Training {args.epochs} epochs — currently skipped, weights random")
    # model.fit(train_data, validation_data=val_data, epochs=args.epochs)

    export_to_int8(model, args.export_dir,
                   dataset_name=args.dataset,
                   model_name=args.model)

    print("\n[!!!] Pipeline xong. Cần copy sang KV260:")
    print(f"      - {args.export_dir}/{args.model}_{args.dataset}.weights.bin")
    print(f"      - {args.export_dir}/{args.model}_{args.dataset}_int8.bin.meta.json")
    print(f"      - firmware/riscv/firmware.bin (re-build sau khi layer_table.h thay đổi)")
    print(f"      - bitstream + ARM main.py")
