#!/usr/bin/env bash
# Push this folder to the A100 box. See README.md.
set -euo pipefail

REMOTE="${REMOTE:-donatoy@142.55.34.202}"
DEST="${DEST:-/raid/userdata/donatoy/hyworld/}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/"

# No --delete: the cloned hyworld2/ source, the venvs and out/ live in $DEST too.
exec rsync -avz \
  --exclude '__pycache__' \
  --exclude '.venv*' \
  --exclude 'out/' \
  "$SRC" "$REMOTE:$DEST"
