"""TFLite parsing -> firmware/layer_table.h + weights.bin + meta.json."""
from __future__ import annotations

import json
import os
import struct
import textwrap
from pathlib import Path
from typing import Iterable

import numpy as np
import tensorflow as tf

from .config import DATASET_IDS, FPGA_INPUT_SIZE, LABEL_MAPS, firmware_dir
from .quantize import quantize_multiplier, random_representative_dataset


# layer_desc_t bytes (must match firmware/layer_desc.h __attribute__((packed)))
#   uint32 weight_offset, weight_bytes, bias_offset, bias_bytes      (16 B)
#   uint16 ifm_width, ifm_height, cin, cout                          ( 8 B)
#   uint8  kernel, stride, padding, pool_en, activation, _res[3]     ( 8 B)
#   int32  output_M; int8 output_shift, input_zp, output_zp, w_zp    ( 8 B)
LAYER_DESC_FMT = "<IIII HHHH BBBBB3x i bbbb"
assert struct.calcsize(LAYER_DESC_FMT) == 40, "layer_desc_t size mismatch"


def emit_layer_table(tflite_bytes: bytes,
                     header_path: str | Path,
                     blob_path: str | Path) -> dict:
    """
    Parse TFLite Conv2D ops -> pack weights/biases into blob, emit C header.

    Returns a dict suitable for embedding under meta.json["fpga"] (num_layers,
    final_ofm_buf_idx, max_tensor_bytes, ...).

    Limits today:
      - CONV_2D 3x3 / 1x1 only (MAX_POOL_2D folded onto previous layer; FC/GAP
        executed on ARM)
      - Per-tensor weight quant (uses scales[0]); per-axis would need RTL changes
    """
    interp = tf.lite.Interpreter(model_content=tflite_bytes)
    interp.allocate_tensors()
    tensors = interp.get_tensor_details()
    ops = interp._get_ops_details()  # private API, stable for years

    blob = bytearray()
    layer_descs: list[dict] = []
    layer_idx = 0

    final_ofm_tensor = None
    final_ofm_layer  = -1

    for op in ops:
        op_name = op["op_name"]

        if op_name == "MAX_POOL_2D":
            if not layer_descs:
                raise ValueError("MAX_POOL_2D before any Conv2D — cannot fold")
            layer_descs[-1]["pool_en"] = 1
            continue

        if op_name != "CONV_2D":
            continue

        in_idx, w_idx, b_idx = op["inputs"]
        out_idx = op["outputs"][0]
        in_t  = tensors[in_idx]
        w_t   = tensors[w_idx]
        out_t = tensors[out_idx]
        b_t   = tensors[b_idx] if b_idx >= 0 else None

        in_scale  = float(in_t["quantization_parameters"]["scales"][0])
        in_zp     = int(in_t["quantization_parameters"]["zero_points"][0])
        out_scale = float(out_t["quantization_parameters"]["scales"][0])
        out_zp    = int(out_t["quantization_parameters"]["zero_points"][0])
        w_scales  = w_t["quantization_parameters"]["scales"]
        w_scale   = float(w_scales[0]) if len(w_scales) > 0 else 1.0
        w_zp      = int(w_t["quantization_parameters"]["zero_points"][0])

        weights = interp.get_tensor(w_idx)            # int8, [cout, kh, kw, cin]
        biases  = interp.get_tensor(b_idx) if b_t else None

        cout, kh, kw, cin = weights.shape
        if kh != kw or kh not in (1, 3):
            raise ValueError(f"Layer {layer_idx}: kernel {kh}x{kw} unsupported")
        ih, iw = int(in_t["shape"][1]), int(in_t["shape"][2])

        weight_offset = len(blob)
        blob.extend(weights.tobytes())
        weight_bytes = len(weights.tobytes())

        if biases is not None:
            bias_offset = len(blob)
            blob.extend(biases.astype(np.int32).tobytes())
            bias_bytes = biases.size * 4
        else:
            bias_offset = 0xFFFFFFFF
            bias_bytes  = 0

        M_real = (in_scale * w_scale) / out_scale if out_scale > 0 else 0.0
        M_q31, shift = quantize_multiplier(M_real)

        layer_descs.append({
            "weight_offset": weight_offset, "weight_bytes": weight_bytes,
            "bias_offset":   bias_offset,   "bias_bytes":   bias_bytes,
            "ifm_width": iw, "ifm_height": ih, "cin": cin, "cout": cout,
            "kernel": kh, "stride": 1, "padding": 0, "pool_en": 0,
            "activation": 1,        # ACT_RELU default; last layer overridden below
            "output_M": M_q31, "output_shift": shift,
            "input_zp": in_zp, "output_zp": out_zp, "weight_zp": w_zp,
        })
        final_ofm_tensor = out_t
        final_ofm_layer  = layer_idx
        layer_idx += 1

    if not layer_descs:
        raise ValueError("No CONV_2D ops found — model not FPGA-deployable")

    layer_descs[-1]["activation"] = 0   # final logits — no ReLU

    # Verify packed size matches C struct
    for L in layer_descs:
        packed = struct.pack(
            LAYER_DESC_FMT,
            L["weight_offset"], L["weight_bytes"], L["bias_offset"], L["bias_bytes"],
            L["ifm_width"], L["ifm_height"], L["cin"], L["cout"],
            L["kernel"], L["stride"], L["padding"], L["pool_en"], L["activation"],
            L["output_M"], L["output_shift"], L["input_zp"], L["output_zp"], L["weight_zp"],
        )
        assert len(packed) == 40

    blob_path = Path(blob_path)
    blob_path.parent.mkdir(parents=True, exist_ok=True)
    blob_path.write_bytes(blob)
    print(f"[+] Weights blob : {blob_path}  ({len(blob)} B, {len(layer_descs)} conv layers)")

    # ---- emit C header ----
    def fmt(L: dict, idx: int) -> str:
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

        /* AUTO-GENERATED by training/train.py — DO NOT EDIT.
         * Re-generate after every re-train. */

        #include "layer_desc.h"

        const uint32_t NUM_LAYERS = {len(layer_descs)};

        const layer_desc_t LAYERS[{len(layer_descs)}] = {{
        """)
    for i, L in enumerate(layer_descs):
        header += textwrap.indent(fmt(L, i), "    ") + ",\n"
    header += "};\n\n#endif /* LAYER_TABLE_H */\n"

    header_path = Path(header_path)
    header_path.parent.mkdir(parents=True, exist_ok=True)
    header_path.write_text(header)
    print(f"[+] Layer table  : {header_path}  ({len(layer_descs)} layers)")

    # max IFM/OFM bytes -> ARM ping-pong buffer size
    max_bytes = 0
    for L in layer_descs:
        ifm = L["ifm_width"] * L["ifm_height"] * L["cin"]
        ow = L["ifm_width"]  - L["kernel"] + 1
        oh = L["ifm_height"] - L["kernel"] + 1
        if L["pool_en"]:
            ow //= 2
            oh //= 2
        ofm = ow * oh * L["cout"]
        max_bytes = max(max_bytes, ifm, ofm)

    # Ping-pong indexing: layer i reads (i&1)?buf_b:buf_a, writes the other.
    # Final OFM ends up in buf_b if final_ofm_layer is even (0,2,...), buf_a if odd.
    final_buf_idx = 1 if (final_ofm_layer % 2) == 0 else 0

    return {
        "num_layers":        len(layer_descs),
        "weights_blob_size": len(blob),
        "final_ofm_layer":   final_ofm_layer,
        "final_ofm_buf_idx": final_buf_idx,
        "final_ofm_shape":   list(final_ofm_tensor["shape"]),
        "final_ofm_scale":   float(final_ofm_tensor["quantization_parameters"]["scales"][0]),
        "final_ofm_zp":      int(final_ofm_tensor["quantization_parameters"]["zero_points"][0]),
        "max_tensor_bytes":  int(max_bytes),
    }


def convert_to_tflite_int8(keras_model: tf.keras.Model,
                           representative_dataset: Iterable | None = None) -> bytes:
    """Run TFLite PTQ INT8 conversion. If `representative_dataset` is None, uses random."""
    converter = tf.lite.TFLiteConverter.from_keras_model(keras_model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    converter.representative_dataset = (
        representative_dataset if representative_dataset is not None
        else random_representative_dataset
    )
    converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
    converter.inference_input_type  = tf.int8
    converter.inference_output_type = tf.int8
    return converter.convert()


def export_to_int8(keras_model: tf.keras.Model,
                   output_dir: str | Path,
                   *,
                   dataset_name: str,
                   model_name: str,
                   representative_dataset: Iterable | None = None,
                   header_path: str | Path | None = None) -> dict:
    """
    Full pipeline:
      Keras -> TFLite INT8 -> emit firmware header + weights.bin -> meta.json.

    Returns the meta dict that was written. `header_path` defaults to
    `<project_root>/firmware/layer_table.h`.
    """
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    print("[*] Running PTQ INT8 conversion...")
    tflite_bytes = convert_to_tflite_int8(keras_model, representative_dataset)

    base = f"{model_name}_{dataset_name}"
    tflite_path = output_dir / f"{base}_int8.bin"
    blob_path   = output_dir / f"{base}.weights.bin"
    meta_path   = output_dir / f"{base}_int8.bin.meta.json"

    if header_path is None:
        header_path = firmware_dir() / "layer_table.h"

    tflite_path.write_bytes(tflite_bytes)
    print(f"[+] TFLite ref   : {tflite_path}")

    emit_summary = emit_layer_table(tflite_bytes, header_path, blob_path)

    interp = tf.lite.Interpreter(model_content=tflite_bytes)
    interp.allocate_tensors()
    in_d  = interp.get_input_details()[0]
    out_d = interp.get_output_details()[0]

    meta = {
        "model":      model_name,
        "dataset":    dataset_name,
        "dataset_id": DATASET_IDS[dataset_name],
        "labels":     LABEL_MAPS[dataset_name],
        "input": {
            "shape":      list(in_d["shape"]),
            "dtype":      str(np.dtype(in_d["dtype"])),
            "scale":      float(in_d["quantization"][0]),
            "zero_point": int(in_d["quantization"][1]),
            "fpga_size":  list(FPGA_INPUT_SIZE),
        },
        "output": {
            "shape":      list(out_d["shape"]),
            "dtype":      str(np.dtype(out_d["dtype"])),
            "scale":      float(out_d["quantization"][0]),
            "zero_point": int(out_d["quantization"][1]),
        },
        "fpga": emit_summary,
        "weights_file": blob_path.name,
        "header_path":  str(header_path),
    }
    meta_path.write_text(json.dumps(meta, indent=2, ensure_ascii=False))
    print(f"[+] Metadata     : {meta_path}")
    print(f"    num_layers={emit_summary['num_layers']}  "
          f"final_ofm_buf_idx={emit_summary['final_ofm_buf_idx']}  "
          f"max_tensor_bytes={emit_summary['max_tensor_bytes']}")
    return meta
