#!/usr/bin/env bash
# Deploy artifacts to KV260 board via rsync over SSH.
#
# Usage:
#   ./deploy.sh                            # default BOARD=ubuntu@kv260.local
#   BOARD=ubuntu@192.168.1.42 ./deploy.sh
#   ./deploy.sh --dry-run
set -euo pipefail

BOARD="${BOARD:-ubuntu@10.42.0.2}"
REMOTE="${REMOTE:-/home/ubuntu/edgeai}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "[deploy] $ROOT → $BOARD:$REMOTE"

# --- Pre-flight checks -------------------------------------------------------
BIT_SRC="$ROOT/hw/artifacts/kria_soc_wrapper/kria_soc_wrapper.bit"
HWH_SRC="$ROOT/hw/artifacts/kria_soc_wrapper/kria_soc.hwh"

[ -f "$BIT_SRC" ] || { echo "[deploy] ERROR: $BIT_SRC not found — generate bitstream first" >&2; exit 1; }
[ -f "$HWH_SRC" ] || { echo "[deploy] ERROR: $HWH_SRC not found — re-export XSA from Vivado" >&2; exit 1; }
[ -f "$ROOT/firmware/firmware.bin" ] || { echo "[deploy] ERROR: firmware.bin missing — run 'make -C firmware'" >&2; exit 1; }
ls "$ROOT/training/export/"*.weights.bin &>/dev/null || { echo "[deploy] ERROR: no weights.bin — run train.ipynb" >&2; exit 1; }

# --- Rsync -------------------------------------------------------------------
R=(-avzh --info=progress2 --delete-after
   --exclude='__pycache__' --exclude='.ipynb_checkpoints' --exclude='*.swp'
   --exclude='.venv' --exclude='*.tflite')

# .bit and .hwh sent explicitly — hwh renamed to match .bit for PYNQ
rsync "${R[@]}" "$@" "$BIT_SRC" "$BOARD:$REMOTE/hw/artifacts/kria_soc_wrapper.bit"
rsync "${R[@]}" "$@" "$HWH_SRC" "$BOARD:$REMOTE/hw/artifacts/kria_soc_wrapper.hwh"
rsync "${R[@]}" "$@" "$ROOT/firmware/firmware.bin" "$ROOT/firmware/firmware.elf" \
                     "$BOARD:$REMOTE/firmware/" 2>/dev/null || \
rsync "${R[@]}" "$@" "$ROOT/firmware/firmware.bin" "$BOARD:$REMOTE/firmware/"
rsync "${R[@]}" "$@" "$ROOT/training/export/"    "$BOARD:$REMOTE/training/export/"
rsync "${R[@]}" "$@" "$ROOT/host/"               "$BOARD:$REMOTE/host/"
[ -d "$ROOT/samples" ] && rsync "${R[@]}" "$@" "$ROOT/samples/" "$BOARD:$REMOTE/samples/"

echo "[deploy] done — open http://${BOARD##*@}:9090 in browser"
