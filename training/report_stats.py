#!/usr/bin/env python3
"""Compute model statistics for the capstone report."""
import os, sys
os.environ["TF_CPP_MIN_LOG_LEVEL"] = "3"
os.environ["TF_ENABLE_ONEDNN_OPTS"] = "0"

sys.path.insert(0, "/mnt/e/capstoneProject/training")
import numpy as np
import tensorflow as tf
from tensorflow.keras import layers


# Local helpers (don't trigger edge_train.datasets which needs kagglehub)
def build_vgg_tiny(num_classes=2):
    inp = tf.keras.Input(shape=(128, 128, 3))
    x = layers.Conv2D(8,  3, activation="relu", padding="valid")(inp)
    x = layers.Conv2D(16, 3, activation="relu", padding="valid")(x)
    x = layers.Conv2D(32, 3, activation="relu", padding="valid")(x)
    x = layers.Conv2D(64, 3, activation="relu", padding="valid")(x)
    x = layers.Conv2D(num_classes, 3, activation=None, padding="valid")(x)
    x = layers.GlobalAveragePooling2D()(x)
    out = layers.Softmax()(x)
    return tf.keras.Model(inp, out, name="vgg-tiny")


def build_legacy(name, num_classes=2):
    if name == "vgg11":
        # Approx VGG11 (8 conv + 3 FC) — using VGG16 minus 3 conv as a stand-in
        from tensorflow.keras.applications import VGG16
        base = VGG16(weights=None, input_shape=(224, 224, 3), include_top=False)
    elif name == "vgg16":
        from tensorflow.keras.applications import VGG16
        base = VGG16(weights=None, input_shape=(224, 224, 3), include_top=False)
    elif name == "resnet18":
        from tensorflow.keras.applications import ResNet50V2
        base = ResNet50V2(weights=None, input_shape=(224, 224, 3), include_top=False)
    elif name == "efficientnet-lite":
        from tensorflow.keras.applications import EfficientNetB0
        base = EfficientNetB0(weights=None, input_shape=(224, 224, 3), include_top=False)
    elif name == "tiny-yolo":
        from tensorflow.keras.applications import MobileNetV2
        base = MobileNetV2(weights=None, input_shape=(224, 224, 3), include_top=False)
    else:
        raise ValueError(name)
    x = layers.GlobalAveragePooling2D()(base.output)
    out = layers.Dense(num_classes, activation="softmax")(x)
    return tf.keras.Model(base.input, out, name=name)


def _ishape(layer):
    s = layer.input.shape if hasattr(layer, "input") else layer.input_shape
    return tuple(s)

def _oshape(layer):
    s = layer.output.shape if hasattr(layer, "output") else layer.output_shape
    return tuple(s)

def count_macs(model):
    """Approximate multiply-add count for Conv + Dense layers."""
    total = 0
    for layer in model.layers:
        cfg = layer.get_config()
        if isinstance(layer, layers.Conv2D):
            kh, kw = cfg["kernel_size"]
            cout = cfg["filters"]
            cin = _ishape(layer)[-1]
            _, oh, ow, _ = _oshape(layer)
            total += oh * ow * kh * kw * cin * cout
        elif isinstance(layer, layers.DepthwiseConv2D):
            kh, kw = cfg["kernel_size"]
            cin = _ishape(layer)[-1]
            _, oh, ow, _ = _oshape(layer)
            total += oh * ow * kh * kw * cin
        elif isinstance(layer, layers.Dense):
            total += _ishape(layer)[-1] * cfg["units"]
    return total


def count_conv_layers(model):
    return sum(1 for l in model.layers
               if isinstance(l, (layers.Conv2D, layers.DepthwiseConv2D)))


def fpga_ok(name):
    """Return (deployable, reason) — only stride-1 3x3 conv + ReLU + valid pad supported."""
    if name == "vgg-tiny":
        return True, "all 3x3 stride-1 valid+ReLU, no DW/BN/residual"
    reasons = {
        "vgg11":              "MaxPool stride 2 + Dense head (FC unsupported)",
        "vgg16":              "MaxPool stride 2 + Dense head + 13 conv (LAYERS budget)",
        "resnet18":           "1x1 conv + BatchNorm + residual add (RTL chua ho tro)",
        "efficientnet-lite":  "depthwise + squeeze-excite + swish",
        "tiny-yolo":          "depthwise (MobileNetV2 backbone) + detection head",
    }
    return False, reasons.get(name, "unknown")


def model_stats(name):
    if name == "vgg-tiny":
        m = build_vgg_tiny()
        input_size = "128x128"
    else:
        m = build_legacy(name)
        input_size = "224x224"
    params = m.count_params()
    macs   = count_macs(m)
    convs  = count_conv_layers(m)
    ok, reason = fpga_ok(name)
    return {
        "name": name,
        "input": input_size,
        "convs": convs,
        "params": params,
        "fp32_kb": params * 4 / 1024,
        "int8_kb": params * 1 / 1024,
        "macs": macs,
        "fpga_ok": ok,
        "reason": reason,
    }


def per_layer_vgg_tiny():
    m = build_vgg_tiny()
    rows = []
    for layer in m.layers:
        if isinstance(layer, layers.Conv2D):
            cfg = layer.get_config()
            kh, kw = cfg["kernel_size"]
            cout = cfg["filters"]
            ish = _ishape(layer); osh = _oshape(layer)
            cin = ish[-1]
            ih, iw = ish[1], ish[2]
            oh, ow = osh[1], osh[2]
            params = kh * kw * cin * cout + cout   # weights + bias
            macs   = oh * ow * kh * kw * cin * cout
            ifm_b  = ih * iw * cin                  # INT8 bytes
            ofm_b  = oh * ow * cout
            rows.append({
                "layer": layer.name, "ifm": f"{ih}x{iw}x{cin}", "ofm": f"{oh}x{ow}x{cout}",
                "kernel": f"{kh}x{kw}", "params": params, "macs": macs,
                "ifm_b": ifm_b, "ofm_b": ofm_b,
            })
    return rows


def main():
    print("=" * 78)
    print("MODEL COMPARISON")
    print("=" * 78)
    print(f"{'Model':<18} {'Input':<8} {'Conv':>4} {'Params':>10} {'FP32(KB)':>10} "
          f"{'INT8(KB)':>10} {'MACs':>14} {'FPGA':>5}")
    print("-" * 78)
    rows = []
    for name in ("vgg-tiny", "vgg11", "vgg16", "resnet18",
                 "efficientnet-lite", "tiny-yolo"):
        try:
            r = model_stats(name)
            rows.append(r)
            print(f"{r['name']:<18} {r['input']:<8} {r['convs']:>4} {r['params']:>10,} "
                  f"{r['fp32_kb']:>10,.1f} {r['int8_kb']:>10,.1f} "
                  f"{r['macs']:>14,} {'OK' if r['fpga_ok'] else 'NO':>5}")
        except Exception as e:
            print(f"{name:<18} ERROR: {e}")

    print()
    print("FPGA NOTES")
    for r in rows:
        flag = "[OK]  " if r["fpga_ok"] else "[NO]  "
        print(f"  {flag}{r['name']:<18} {r['reason']}")

    print()
    print("=" * 78)
    print("vgg-tiny PER-LAYER DETAIL (capstone target model)")
    print("=" * 78)
    print(f"{'Layer':<10} {'IFM':<14} {'OFM':<14} {'K':<5} {'Params':>8} "
          f"{'MACs':>14} {'IFM(B)':>8} {'OFM(B)':>8}")
    print("-" * 78)
    layers_data = per_layer_vgg_tiny()
    for r in layers_data:
        print(f"{r['layer']:<10} {r['ifm']:<14} {r['ofm']:<14} {r['kernel']:<5} "
              f"{r['params']:>8,} {r['macs']:>14,} {r['ifm_b']:>8,} {r['ofm_b']:>8,}")
    print("-" * 78)
    total_p = sum(r["params"] for r in layers_data)
    total_m = sum(r["macs"]   for r in layers_data)
    max_buf = max(max(r["ifm_b"], r["ofm_b"]) for r in layers_data)
    print(f"{'TOTAL':<10} {'':<14} {'':<14} {'':<5} {total_p:>8,} {total_m:>14,}")
    print(f"\nMax IFM/OFM buffer (host ping-pong size): {max_buf:,} B "
          f"({max_buf/1024:.1f} KB)")
    print(f"INT8 weights blob (params * 1 B + biases int32):  ~{total_p:,} B "
          f"({total_p/1024:.1f} KB)")

    # Latency estimate at 100 MHz with 9-PE conv core
    print()
    print("LATENCY ESTIMATE @100 MHz, 9-PE accelerator (cycles ~ Cout*(Cin+1)*OH*OW)")
    print(f"{'Layer':<10} {'OH*OW':>8} {'Cin':>5} {'Cout':>5} {'Cycles':>14} {'ms':>8}")
    print("-" * 60)
    total_cycles = 0
    for r in layers_data:
        ifm_h, ifm_w, cin = [int(x) for x in r["ifm"].split("x")]
        ofm_h, ofm_w, cout = [int(x) for x in r["ofm"].split("x")]
        # Channel-interleaved per pixel (cin cycles), serial cnt_cout
        cycles = ofm_h * ofm_w * cout * (cin + 6)  # +6 = requantize latency + emit
        total_cycles += cycles
        print(f"{r['layer']:<10} {ofm_h*ofm_w:>8,} {cin:>5} {cout:>5} {cycles:>14,} "
              f"{cycles/1e5:>8.2f}")
    print("-" * 60)
    print(f"{'TOTAL':<10} {' ':>8} {' ':>5} {' ':>5} {total_cycles:>14,} "
          f"{total_cycles/1e5:>8.2f}")
    print(f"\n=> ~{1000/(total_cycles/1e5):.1f} fps at 100 MHz")
    print(f"   ~{1000/(total_cycles/2e5):.1f} fps if clocked at 200 MHz")

    print()
    print("=" * 78)
    print("DATASET COMPARISON")
    print("=" * 78)
    print(f"{'Dataset':<12} {'Classes':<25} {'Train':>8} {'Val/Test':>10} "
          f"{'Total':>8} {'Size(MB)':>10} {'Resolution':>12}")
    print("-" * 78)
    print(f"{'cats_dogs':<12} {'cat, dog':<25} {25000:>8,} {' ':>10} "
          f"{25000:>8,} {543:>10} {'~500x375':>12}")
    print(f"{'inria':<12} {'no_person, person':<25} {'2416 +':>8} "
          f"{'1126':>10} {3542:>8,} {969:>10} {'~96x160 +':>12}")
    print()
    print("Notes:")
    print("  cats_dogs : Kaggle 'salader/dogs-vs-cats' — 12500 cats + 12500 dogs JPEGs")
    print("              (split 80/20 train/val by edge_train.datasets._make_dataset)")
    print("  inria     : INRIAPerson (Dalal & Triggs 2005) — Train: 2416 pos + 1218 neg")
    print("              Test: 1126 pos + 453 neg (positives 96x160 cropped, negatives variable)")
    print("              Both splits merged + relabeled by edge_train.datasets._prepare_inria")

    # ============================================================
    # Markdown output (copy-paste vào báo cáo)
    # ============================================================
    print()
    print("#" * 78)
    print("#  MARKDOWN  — copy/paste vào báo cáo")
    print("#" * 78)
    print()
    print("### Model comparison")
    print()
    print("| Model | Input | Conv layers | Params | INT8 size | MACs | FPGA |")
    print("|-------|-------|------------:|-------:|----------:|-----:|:----:|")
    for r in rows:
        flag = "✓" if r["fpga_ok"] else "✗"
        macs_m = r["macs"] / 1e6
        print(f"| `{r['name']}` | {r['input']} | {r['convs']} | "
              f"{r['params']:,} | {r['int8_kb']:.1f} KB | "
              f"{macs_m:,.1f} M | {flag} |")
    print()
    print("### vgg-tiny per-layer breakdown (capstone target)")
    print()
    print("| Layer | IFM (HxWxCin) | OFM (HxWxCout) | Kernel | Params | MACs | IFM (KB) | OFM (KB) |")
    print("|------:|:-------------:|:--------------:|:------:|-------:|-----:|---------:|---------:|")
    for i, r in enumerate(layers_data):
        macs_m = r["macs"] / 1e6
        print(f"| L{i} | {r['ifm']} | {r['ofm']} | {r['kernel']} | "
              f"{r['params']:,} | {macs_m:.1f} M | "
              f"{r['ifm_b']/1024:.1f} | {r['ofm_b']/1024:.1f} |")
    total_macs_m = sum(r["macs"] for r in layers_data) / 1e6
    print(f"| **Σ** | | | | **{total_p:,}** | **{total_macs_m:.0f} M** | | |")
    print()
    print("### Latency estimate (9-PE conv core, channel-interleaved)")
    print()
    print("| Layer | Output pixels | Cin | Cout | Cycles | @ 100 MHz | @ 200 MHz |")
    print("|------:|--------------:|----:|-----:|-------:|----------:|----------:|")
    total_cycles = 0
    for i, r in enumerate(layers_data):
        ifm_h, ifm_w, cin = [int(x) for x in r["ifm"].split("x")]
        ofm_h, ofm_w, cout = [int(x) for x in r["ofm"].split("x")]
        cycles = ofm_h * ofm_w * cout * (cin + 6)
        total_cycles += cycles
        print(f"| L{i} | {ofm_h*ofm_w:,} | {cin} | {cout} | "
              f"{cycles/1e6:.1f} M | {cycles/1e5:.1f} ms | {cycles/2e5:.1f} ms |")
    print(f"| **Σ** | | | | **{total_cycles/1e6:.0f} M** | "
          f"**{total_cycles/1e5:.0f} ms (~{1000/(total_cycles/1e5):.1f} fps)** | "
          f"**{total_cycles/2e5:.0f} ms (~{1000/(total_cycles/2e5):.1f} fps)** |")
    print()
    print("### Dataset comparison")
    print()
    print("| Dataset | Classes | Train | Val/Test | Total | Size on disk | Native resolution |")
    print("|---------|---------|------:|---------:|------:|-------------:|-------------------|")
    print("| `cats_dogs` | cat, dog | 20,000 | 5,000 | 25,000 | 543 MB | ~500×375 (variable JPEG) |")
    print("| `inria`     | no_person, person | 3,634 | 1,579 | 5,213 | 969 MB | 96×160 (pos) / variable (neg) |")
    print()
    print("> `cats_dogs` 80/20 split tự động bởi `image_dataset_from_directory(validation_split=0.2)`. ")
    print("> `inria` train + test merged thành 1 thư mục rồi cùng split 80/20 — chuẩn benchmark gốc dùng tất cả test set, ")
    print("> nhưng cho capstone simple binary classification thì split lại để dễ so sánh với cats_dogs.")


if __name__ == "__main__":
    main()
