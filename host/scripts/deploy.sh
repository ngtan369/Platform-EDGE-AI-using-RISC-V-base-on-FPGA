#!/usr/bin/env bash
# Rsync project artifacts to KV260 board.
#
# Prerequisite (one-time on board):
#   sudo mkdir -p /home/ubuntu/edgeai && sudo chown ubuntu:ubuntu /home/ubuntu/edgeai
#
# Usage:
#   ./deploy.sh                          # default BOARD=ubuntu@kv260.local (mDNS)
#   BOARD=ubuntu@192.168.1.42 ./deploy.sh # use direct IP if mDNS not working
#   ./deploy.sh --dry-run                # preview without copying
set -euo pipefail

BOARD="${BOARD:-ubuntu@kv260.local}"
REMOTE_ROOT="${REMOTE_ROOT:-/home/ubuntu/edgeai}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "[deploy] from $PROJECT_ROOT"
echo "[deploy] to   $BOARD:$REMOTE_ROOT"

# --- Pre-flight: extract .hwh from .xsa if missing ---------------------------
# PYNQ Overlay() loads <name>.bit + <name>.hwh from the same directory with the
# same basename. Vivado puts the .hwh INSIDE the .xsa (as kria_soc.hwh, no
# _wrapper suffix) — extract and rename so PYNQ can find it.
BIT="$PROJECT_ROOT/hw/artifacts/kria_soc_wrapper.bit"
XSA="$PROJECT_ROOT/hw/artifacts/kria_soc_wrapper.xsa"
HWH="$PROJECT_ROOT/hw/artifacts/kria_soc_wrapper.hwh"

if [ ! -f "$BIT" ]; then
    echo "[deploy] ERROR: $BIT not found — generate bitstream in Vivado first" >&2
    exit 1
fi
if [ ! -f "$HWH" ]; then
    if [ -f "$XSA" ]; then
        echo "[deploy] extracting .hwh from .xsa (PYNQ requires it co-located with .bit)"
        # The BD hwh inside the XSA is named after the BD instance (kria_soc.hwh),
        # not the wrapper. Extract whichever .hwh is in the archive.
        TMPDIR="$(mktemp -d)"
        unzip -q -j "$XSA" '*.hwh' -d "$TMPDIR"
        # Pick the top-level BD hwh (largest one usually, or the first non-smartconnect)
        SRC_HWH=$(ls -S "$TMPDIR"/*.hwh 2>/dev/null | grep -v smartconnect | head -1)
        if [ -z "$SRC_HWH" ]; then
            echo "[deploy] ERROR: no .hwh found inside $XSA" >&2
            rm -rf "$TMPDIR"
            exit 1
        fi
        cp "$SRC_HWH" "$HWH"
        rm -rf "$TMPDIR"
        echo "[deploy] -> $HWH"
    else
        echo "[deploy] ERROR: neither $HWH nor $XSA found" >&2
        exit 1
    fi
fi

# --- Pre-flight: verify firmware + training artifacts exist ------------------
for f in "$PROJECT_ROOT/firmware/firmware.bin" \
         "$PROJECT_ROOT/firmware/layer_table.h"; do
    [ -f "$f" ] || { echo "[deploy] ERROR: missing $f — run 'make -C firmware'" >&2; exit 1; }
done
ls "$PROJECT_ROOT/training/export/"*.weights.bin >/dev/null 2>&1 || {
    echo "[deploy] ERROR: no weights.bin in training/export/ — run train.ipynb" >&2; exit 1;
}

# --- Connectivity check ------------------------------------------------------
HOST_PART="${BOARD#*@}"
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$BOARD" 'true' 2>/dev/null; then
    echo "[deploy] WARN: cannot SSH to $BOARD (timeout/auth)."
    echo "[deploy]   - if mDNS fails, try:  BOARD=ubuntu@<board-ip> $0"
    echo "[deploy]   - on board, check:     sudo systemctl status ssh"
    echo "[deploy]   - first connection requires password (will cache key after)"
fi

# --- Rsync 4 branches --------------------------------------------------------
RSYNC_OPTS=(-avzh --info=progress2 --delete-after)
RSYNC_OPTS+=(--exclude='.git' --exclude='**/__pycache__' --exclude='**/.ipynb_checkpoints'
             --exclude='**/.venv' --exclude='hw/vivado_pj' --exclude='hw/cnn_standard'
             --exclude='hw/cv32e40p' --exclude='hw/ip_repo/**/component_*'
             --exclude='training/.venv' --exclude='**/*.tflite' --exclude='*.swp')

# Forward any extra flags (e.g. --dry-run)
rsync "${RSYNC_OPTS[@]}" "$@" \
    "$PROJECT_ROOT/hw/artifacts/" \
    "$BOARD:$REMOTE_ROOT/hw/artifacts/"

rsync "${RSYNC_OPTS[@]}" "$@" \
    "$PROJECT_ROOT/firmware/firmware.bin" \
    "$PROJECT_ROOT/firmware/firmware.elf" \
    "$BOARD:$REMOTE_ROOT/firmware/"

rsync "${RSYNC_OPTS[@]}" "$@" \
    "$PROJECT_ROOT/training/export/" \
    "$BOARD:$REMOTE_ROOT/training/export/"

rsync "${RSYNC_OPTS[@]}" "$@" \
    "$PROJECT_ROOT/host/" \
    "$BOARD:$REMOTE_ROOT/host/"

# samples/ -- test images consumed by inference_demo.ipynb + benchmark.ipynb
if [ -d "$PROJECT_ROOT/samples" ] && [ "$(ls -A "$PROJECT_ROOT/samples" 2>/dev/null | grep -v '^README' | head -1)" ]; then
    rsync "${RSYNC_OPTS[@]}" "$@" \
        "$PROJECT_ROOT/samples/" \
        "$BOARD:$REMOTE_ROOT/samples/"
else
    echo "[deploy] WARN: samples/ empty — drop a few cat_*.jpg / dog_*.jpg before re-running"
fi

cat <<EOF
[deploy] OK. Next steps on the board:
  ssh $BOARD
  cd $REMOTE_ROOT/host
  sudo -E env "PATH=\$PATH" jupyter notebook --no-browser --ip=0.0.0.0 --port=9090
  # then open http://${HOST_PART}:9090/?token=<from-stdout> in browser

  # Or CLI (faster for scripted runs):
  sudo python3 scripts/infer.py --image samples/cat.jpg
EOF
