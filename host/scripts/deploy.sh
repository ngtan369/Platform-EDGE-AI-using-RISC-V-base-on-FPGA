#!/usr/bin/env bash
# Rsync project artifacts to KV260 board.
#
# Prerequisite (one-time on board):
#   sudo mkdir -p /home/ubuntu/edgeai && sudo chown ubuntu:ubuntu /home/ubuntu/edgeai
#
# Usage:
#   ./deploy.sh                     # uses default BOARD=ubuntu@kv260.local
#   BOARD=ubuntu@192.168.1.42 ./deploy.sh
#   ./deploy.sh --dry-run           # preview without copying
set -euo pipefail

BOARD="${BOARD:-ubuntu@kv260.local}"
REMOTE_ROOT="${REMOTE_ROOT:-/home/ubuntu/edgeai}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "[deploy] from $PROJECT_ROOT"
echo "[deploy] to   $BOARD:$REMOTE_ROOT"

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

echo "[deploy] OK. SSH in and:"
echo "  cd $REMOTE_ROOT/host && jupyter notebook --no-browser --port=9090"
