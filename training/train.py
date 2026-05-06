"""
Thin CLI wrapper around `edge_train` package.

For interactive workflow (Colab or local Jupyter), see train.ipynb instead —
it shares the same `edge_train` library, with visualization + plots.

Usage:
    python3 train.py --model vgg-tiny --dataset cats_dogs --epochs 10
"""
import argparse
import os
import sys

# Allow running as `python train.py` from training/
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from edge_train import (
    DATASET_IDS, LABEL_MAPS,
    build_model, load_dataset, representative_samples,
    export_to_int8, export_dir,
)


def main() -> int:
    p = argparse.ArgumentParser(description="Edge-AI training + FPGA-compile pipeline")
    p.add_argument("--model",   default="vgg-tiny",
                   choices=["vgg-tiny", "vgg11", "vgg16", "resnet18",
                            "tiny-yolo", "yolo-fastest", "efficientnet-lite"],
                   help="Only 'vgg-tiny' deploys to the FPGA accelerator currently.")
    p.add_argument("--dataset", default="cats_dogs", choices=list(LABEL_MAPS))
    p.add_argument("--epochs",  type=int, default=10)
    p.add_argument("--batch",   type=int, default=32)
    p.add_argument("--export-dir", default=None,
                   help="Default: <project>/training/export/")
    p.add_argument("--no-train", action="store_true",
                   help="Skip fit() — emit FPGA artifacts from random weights "
                        "(useful for hardware bring-up before model is ready).")
    args = p.parse_args()

    out_dir = args.export_dir or str(export_dir())
    os.makedirs(out_dir, exist_ok=True)

    print("=" * 60)
    print(f"  model={args.model}  dataset={args.dataset}  epochs={args.epochs}")
    print("=" * 60)

    train_ds, val_ds, num_classes = load_dataset(args.dataset, batch_size=args.batch)
    model = build_model(args.model, num_classes)
    model.compile(optimizer="adam",
                  loss="sparse_categorical_crossentropy",
                  metrics=["accuracy"])
    print(f"[*] {model.name}: {model.count_params()} params")

    if args.no_train:
        print("[!] --no-train: skipping fit(), exporting random weights")
    else:
        model.fit(train_ds, validation_data=val_ds, epochs=args.epochs)

    # Real calibration set beats random uniform — pulls 100 batches from val_ds.
    rep_ds = lambda: representative_samples(val_ds, n=100)

    export_to_int8(model, out_dir,
                   dataset_name=args.dataset,
                   model_name=args.model,
                   representative_dataset=rep_ds)

    print("\n[done] Artifacts ready:")
    print(f"  {out_dir}/{args.model}_{args.dataset}.weights.bin")
    print(f"  {out_dir}/{args.model}_{args.dataset}_int8.bin.meta.json")
    print(f"  firmware/layer_table.h  -> rebuild firmware (make -C firmware)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
