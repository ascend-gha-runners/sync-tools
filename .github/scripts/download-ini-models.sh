#!/bin/bash
# Downloads models/datasets from ModelScope using .ini config (one entry per line)
# Usage: download-ini-models.sh <config-file> <model|dataset>
set -euo pipefail

CONFIG_FILE="$1"
TYPE="$2"  # "model" or "dataset"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: Config file not found: $CONFIG_FILE"
  exit 1
fi

dos2unix "$CONFIG_FILE" 2>/dev/null || true

while IFS= read -r entry; do
  entry=$(echo "$entry" | tr -d '\r' | xargs)
  [[ -z "$entry" || "$entry" =~ ^# ]] && continue

  echo "Downloading $TYPE: $entry"
  if [ "$TYPE" = "model" ]; then
    modelscope download --model "$entry"
  else
    modelscope download --dataset "$entry"
  fi
done < "$CONFIG_FILE"

echo "Completed downloading $TYPE entries from $CONFIG_FILE"
