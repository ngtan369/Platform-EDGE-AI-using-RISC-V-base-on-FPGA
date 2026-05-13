#!/usr/bin/env bash
# Deploy artifacts to KV260 board via rsync over SSH.
#
# Usage:
#   ./deploy.sh                            # default BOARD=ubuntu@kv260.local
#   BOARD=ubuntu@192.168.1.42 ./deploy.sh
#   ./deploy.sh --dry-run
set -euo pipefail

BOARD="${BOARD:-ubuntu@192.168.137.100}"
REMOTE="${REMOTE:-/home/ubuntu/edgeai}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "[deploy] $ROOT → $BOARD:$REMOTE"

# --- Pre-flight checks -------------------------------------------------------
if [ ! -f "$ROOT/hw/artifacts/kria_soc_wrapper.bit" ]; then
    echo "[deploy] ERROR: hw/artifacts/kria_soc_wrapper.bit not found — generate bitstream first" >&2; exit 1
fi
if [ ! -f "$ROOT/hw/artifacts/kria_soc_wrapper.hwh" ] && [ -f "$ROOT/hw/artifacts/kria_soc_wrapper.xsa" ]; then
    echo "[deploy] extracting .hwh from .xsa..."
    TMPD="$(mktemp -d)"
    unzip -q -j "$ROOT/hw/artifacts/kria_soc_wrapper.xsa" '*.hwh' -d "$TMPD"
    SRC="$(ls -S "$TMPD"/*.hwh 2>/dev/null | grep -v smartconnect | head -1)"
    [ -n "$SRC" ] || { echo "[deploy] ERROR: no .hwh in .xsa" >&2; rm -rf "$TMPD"; exit 1; }
    cp "$SRC" "$ROOT/hw/artifacts/kria_soc_wrapper.hwh"
    rm -rf "$TMPD"
fi
[ -f "$ROOT/firmware/firmware.bin" ] || { echo "[deploy] ERROR: firmware.bin missing — run 'make -C firmware'" >&2; exit 1; }
ls "$ROOT/training/export/"*.weights.bin &>/dev/null || { echo "[deploy] ERROR: no weights.bin — run train.ipynb" >&2; exit 1; }

# --- Rsync -------------------------------------------------------------------
R=(-avzh --info=progress2 --delete-after
   --exclude='__pycache__' --exclude='.ipynb_checkpoints' --exclude='*.swp'
   --exclude='.venv' --exclude='*.tflite')

rsync "${R[@]}" "$@" "$ROOT/hw/artifacts/"       "$BOARD:$REMOTE/hw/artifacts/"
rsync "${R[@]}" "$@" "$ROOT/firmware/firmware.bin" "$ROOT/firmware/firmware.elf" \
                     "$BOARD:$REMOTE/firmware/" 2>/dev/null || \
rsync "${R[@]}" "$@" "$ROOT/firmware/firmware.bin" "$BOARD:$REMOTE/firmware/"
rsync "${R[@]}" "$@" "$ROOT/training/export/"    "$BOARD:$REMOTE/training/export/"
rsync "${R[@]}" "$@" "$ROOT/host/"               "$BOARD:$REMOTE/host/"
[ -d "$ROOT/samples" ] && rsync "${R[@]}" "$@" "$ROOT/samples/" "$BOARD:$REMOTE/samples/"

echo "[deploy] done — ssh $BOARD 'cd $REMOTE/host && sudo -E jupyter notebook --no-browser --ip=0.0.0.0 --port=9090'"
