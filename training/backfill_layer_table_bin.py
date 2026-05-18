"""One-shot backfill: regenerate layer_table.bin for models trained before the
emit.py fix landed (when layer_table.bin was only written to firmware/ and not
bundled into the Colab zip download).

Run this ONCE on Colab or any environment with tensorflow installed:

    cd /content/capstoneProject/training
    python3 backfill_layer_table_bin.py

It walks training/artifacts/*/training/export/ folders, finds each
<model>_<dataset>_int8.bin (TFLite reference), and re-runs emit_layer_table()
to produce the missing <model>_<dataset>.layer_table.bin next to it.

Idempotent — skips folders that already have the .bin file.
"""
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from edge_train.emit import emit_layer_table

ARTIFACTS = HERE / "artifacts"

# Walk every <model>_<dataset>/ folder under training/artifacts/
# Layouts seen in the wild:
#   <folder>/training/<files>          (older local builds)
#   <folder>/training/export/<files>   (newer Colab bundles)
def find_export_dir(folder: Path) -> Path | None:
    for cand in (folder / "training" / "export", folder / "training"):
        if cand.is_dir() and any(cand.glob("*_int8.bin")):
            return cand
    return None


def main() -> int:
    if not ARTIFACTS.is_dir():
        print(f"[ERR] {ARTIFACTS} not found")
        return 1

    n_done = n_skip = n_err = 0
    for folder in sorted(ARTIFACTS.iterdir()):
        if not folder.is_dir() or folder.name.startswith("."):
            continue
        art_dir = find_export_dir(folder)
        if art_dir is None:
            print(f"[SKIP] {folder.name}: no _int8.bin found")
            n_skip += 1
            continue

        # Discover the <model>_<dataset> prefix from the tflite filename
        tflite = next(art_dir.glob("*_int8.bin"), None)
        prefix = tflite.name.removesuffix("_int8.bin")
        out_bin = art_dir / f"{prefix}.layer_table.bin"

        if out_bin.exists():
            print(f"[OK]   {folder.name}: {out_bin.name} already exists ({out_bin.stat().st_size} B)")
            n_skip += 1
            continue

        print(f"[GEN]  {folder.name}: deriving {out_bin.name} from {tflite.name}")
        try:
            tflite_bytes = tflite.read_bytes()
            with tempfile.TemporaryDirectory() as tmp:
                tmp_blob = Path(tmp) / f"{prefix}.weights.bin"
                tmp_header = Path(tmp) / "layer_table.h"
                emit_layer_table(tflite_bytes, tmp_header, tmp_blob)
                src_bin = tmp_blob.parent / f"{prefix}.layer_table.bin"
                if not src_bin.exists():
                    src_bin = tmp_header.with_suffix(".bin")
                out_bin.write_bytes(src_bin.read_bytes())
            print(f"       → wrote {out_bin} ({out_bin.stat().st_size} B)")
            n_done += 1
        except Exception as e:
            print(f"[ERR]  {folder.name}: {e}")
            n_err += 1

    print(f"\nSummary: {n_done} generated, {n_skip} skipped, {n_err} errors")
    return 0 if n_err == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
