"""Keras model factory — only `vgg-tiny` is FPGA-deployable (stride-1 3x3 conv, no DW/BN/residual)."""
from __future__ import annotations

import tensorflow as tf
from tensorflow.keras import layers, models, applications

from .config import FPGA_INPUT_SIZE


def build_vgg_tiny(num_classes: int, input_shape=(*FPGA_INPUT_SIZE, 3)) -> tf.keras.Model:
    """
    Fully-convolutional Tiny-VGG. No Dense head — last conv emits `num_classes` channels,
    ARM does GAP + softmax + argmax post-RTL.

    Geometry (input 128x128, valid padding, stride 1):
        128x128x3
          -> Conv 3x3 cout=8  ReLU         -> 126x126x8
          -> Conv 3x3 cout=16 ReLU         -> 124x124x16
          -> Conv 3x3 cout=32 ReLU         -> 122x122x32
          -> Conv 3x3 cout=64 ReLU         -> 120x120x64
          -> Conv 3x3 cout=N  (no act)     -> 118x118xN     (N=num_classes)
        ARM: GAP -> softmax -> argmax
    """
    inputs = tf.keras.Input(shape=input_shape)
    x = layers.Conv2D(8,  3, activation="relu", padding="valid")(inputs)
    x = layers.Conv2D(16, 3, activation="relu", padding="valid")(x)
    x = layers.Conv2D(32, 3, activation="relu", padding="valid")(x)
    x = layers.Conv2D(64, 3, activation="relu", padding="valid")(x)
    x = layers.Conv2D(num_classes, 3, activation=None, padding="valid")(x)
    x = layers.GlobalAveragePooling2D()(x)
    outputs = layers.Softmax()(x)
    return models.Model(inputs, outputs, name="vgg_tiny")


def build_legacy(model_name: str, num_classes: int,
                 input_shape=(224, 224, 3)) -> tf.keras.Model:
    """
    Legacy Keras Applications models — train OK but **export sang layer_table.h sẽ FAIL**
    do chứa op chưa hỗ trợ (1x1 conv, depthwise, residual, BN). Giữ lại cho experiments.
    """
    print(f"[!] '{model_name}' không deploy được lên FPGA hiện tại — chỉ train/eval.")
    if model_name in ("vgg11", "vgg16"):
        base = applications.VGG16(weights=None, input_shape=input_shape, include_top=False)
    elif model_name == "resnet18":
        base = applications.ResNet50V2(weights=None, input_shape=input_shape, include_top=False)
    elif model_name == "efficientnet-lite":
        base = applications.EfficientNetB0(weights=None, input_shape=input_shape, include_top=False)
    elif model_name in ("tiny-yolo", "yolo-fastest"):
        base = applications.MobileNetV2(weights=None, input_shape=input_shape, include_top=False)
    else:
        raise ValueError(f"Không hỗ trợ model: {model_name}")
    x = layers.GlobalAveragePooling2D()(base.output)
    out = layers.Dense(num_classes, activation="softmax")(x)
    return models.Model(base.input, out, name=model_name)


def build_model(model_name: str, num_classes: int) -> tf.keras.Model:
    if model_name == "vgg-tiny":
        return build_vgg_tiny(num_classes)
    return build_legacy(model_name, num_classes)
