"""tf.data pipelines for cats_dogs (kagglehub) + INRIA Person.

Both return (train_ds, val_ds, num_classes) — caller compiles + fit.
Images are resized to FPGA_INPUT_SIZE and normalized to [0, 1] float32.
Labels are integer class ids matching `LABEL_MAPS[dataset]` order.
"""
from __future__ import annotations

import os
import shutil
import tarfile
import urllib.request
from pathlib import Path

import numpy as np
import tensorflow as tf

from .config import FPGA_INPUT_SIZE, LABEL_MAPS


def _make_dataset(image_dir: str | Path, batch_size: int, img_size: tuple[int, int],
                  val_split: float = 0.2, seed: int = 42):
    """Wrapper around `image_dataset_from_directory` with normalize + prefetch."""
    train_ds = tf.keras.utils.image_dataset_from_directory(
        image_dir, validation_split=val_split, subset="training",
        seed=seed, image_size=img_size, batch_size=batch_size, label_mode="int")
    val_ds = tf.keras.utils.image_dataset_from_directory(
        image_dir, validation_split=val_split, subset="validation",
        seed=seed, image_size=img_size, batch_size=batch_size, label_mode="int")

    norm = tf.keras.layers.Rescaling(1.0 / 255.0)
    train_ds = train_ds.map(lambda x, y: (norm(x), y), num_parallel_calls=tf.data.AUTOTUNE)
    val_ds   = val_ds.map(  lambda x, y: (norm(x), y), num_parallel_calls=tf.data.AUTOTUNE)

    train_ds = train_ds.cache().shuffle(1024).prefetch(tf.data.AUTOTUNE)
    val_ds   = val_ds.cache().prefetch(tf.data.AUTOTUNE)
    return train_ds, val_ds


# --------------------------------------------------------------------------- #
#  Cats vs Dogs — Kaggle "salader/dogs-vs-cats" via kagglehub
# --------------------------------------------------------------------------- #
def load_cats_dogs(batch_size: int = 32, img_size=FPGA_INPUT_SIZE):
    """
    Download (cached) salader/dogs-vs-cats from Kaggle. Uses kagglehub which
    transparently caches in ~/.cache/kagglehub.
    Folder layout after download:
        <root>/train/cats/*.jpg
        <root>/train/dogs/*.jpg

    Class order is alphabetical → ['cats','dogs'] which matches LABEL_MAPS['cats_dogs'].
    """
    import kagglehub
    root = kagglehub.dataset_download("salader/dogs-vs-cats")
    train_dir = Path(root) / "train"
    if not train_dir.exists():
        # Some kagglehub versions extract to a different layout; pick the only subdir
        subdirs = [p for p in Path(root).iterdir() if p.is_dir()]
        train_dir = next((s for s in subdirs if any(s.iterdir())), Path(root))
    print(f"[*] cats_dogs root : {train_dir}")
    return _make_dataset(train_dir, batch_size, img_size)


# --------------------------------------------------------------------------- #
#  INRIA Person — auto-download from a public mirror
# --------------------------------------------------------------------------- #
INRIA_URL = "https://dlib.net/files/data/INRIAPerson.tar"  # public mirror; ~969 MB
INRIA_LOCAL = Path.home() / ".cache" / "edgeai_datasets" / "INRIAPerson"


def _prepare_inria(target_dir: Path = INRIA_LOCAL) -> Path:
    """
    Download + extract INRIAPerson if not present, then build a 2-class folder layout:
        target_dir/processed/no_person/*.png   (← Train/neg)
        target_dir/processed/person/*.png      (← Train/pos)
    Returns the `processed/` path.
    """
    target_dir = Path(target_dir)
    processed = target_dir / "processed"
    if processed.exists() and any((processed / "person").glob("*.png")):
        return processed

    target_dir.mkdir(parents=True, exist_ok=True)
    tar_path = target_dir / "INRIAPerson.tar"
    if not tar_path.exists():
        print(f"[*] Downloading INRIAPerson (~969 MB) -> {tar_path}")
        urllib.request.urlretrieve(INRIA_URL, tar_path)
    extracted = target_dir / "INRIAPerson"
    if not extracted.exists():
        print(f"[*] Extracting {tar_path}")
        with tarfile.open(tar_path) as t:
            t.extractall(target_dir)

    # Build flat 2-class layout. INRIA's "Train/pos" + "Test/pos" merged → person/
    processed.mkdir(exist_ok=True)
    (processed / "person").mkdir(exist_ok=True)
    (processed / "no_person").mkdir(exist_ok=True)
    for split in ("Train", "Test"):
        for src_cls, dst_cls in (("pos", "person"), ("neg", "no_person")):
            src = extracted / split / src_cls
            if not src.exists():
                continue
            for f in src.iterdir():
                if f.is_file():
                    shutil.copy(f, processed / dst_cls / f"{split}_{f.name}")
    return processed


def load_inria(batch_size: int = 32, img_size=FPGA_INPUT_SIZE):
    folder = _prepare_inria()
    print(f"[*] INRIA processed root: {folder}")
    return _make_dataset(folder, batch_size, img_size)


# --------------------------------------------------------------------------- #
#  Top-level dispatch
# --------------------------------------------------------------------------- #
def load_dataset(name: str, batch_size: int = 32, img_size=FPGA_INPUT_SIZE):
    if name not in LABEL_MAPS:
        raise ValueError(f"Unknown dataset: {name!r} (have: {list(LABEL_MAPS)})")
    if name == "cats_dogs":
        train_ds, val_ds = load_cats_dogs(batch_size, img_size)
    elif name == "inria":
        train_ds, val_ds = load_inria(batch_size, img_size)
    else:
        raise NotImplementedError(name)
    return train_ds, val_ds, len(LABEL_MAPS[name])


def representative_samples(val_ds, n: int = 100):
    """Yield up to `n` single-image batches for TFLite representative_dataset."""
    count = 0
    for batch_x, _ in val_ds.unbatch().batch(1):
        if count >= n:
            return
        yield [tf.cast(batch_x, tf.float32).numpy()]
        count += 1
