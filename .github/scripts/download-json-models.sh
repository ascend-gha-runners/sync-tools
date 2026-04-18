#!/bin/bash
# Downloads models/datasets from ModelScope or HuggingFace using .json config
# Usage: download-json-models.sh <config-file> <model|dataset>
set -euo pipefail

CONFIG_FILE="$1"
TYPE="$2"  # "model" or "dataset"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: Config file not found: $CONFIG_FILE"
  exit 1
fi

NAME_KEY="${TYPE}_name"

jq -c '.[]' "$CONFIG_FILE" | while IFS= read -r entry; do
  platform=$(echo "$entry" | jq -r '.platform')
  organization=$(echo "$entry" | jq -r '.organization')
  name=$(echo "$entry" | jq -r ".$NAME_KEY")

  echo "Processing $TYPE: $organization/$name from $platform"

  if [ "$platform" = "modelscope" ]; then
    if [ "$TYPE" = "model" ]; then
      modelscope download --model "$organization/$name" || echo "WARNING: Failed to download model $organization/$name from ModelScope"
    else
      modelscope download --dataset "$organization/$name" || echo "WARNING: Failed to download dataset $organization/$name from ModelScope"
    fi
  elif [ "$platform" = "huggingface" ]; then
    if [ "$TYPE" = "model" ]; then
      download_path="/root/.cache/models/$organization/$name"
      mkdir -p "$download_path"
      python -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='$organization/$name', local_dir='$download_path', local_dir_use_symlinks=False)" || echo "WARNING: Failed to download model $organization/$name from HuggingFace"
    else
      download_path="/root/.cache/datasets/$organization/$name"
      mkdir -p "$download_path"
      hf download "$organization/$name" --repo-type=dataset --local-dir="$download_path" || echo "WARNING: Failed to download dataset $organization/$name from HuggingFace"
    fi
  else
    echo "Unknown platform: $platform. Skipping $organization/$name"
  fi

  echo "---"
done

echo "Completed downloading $TYPE entries from $CONFIG_FILE"
