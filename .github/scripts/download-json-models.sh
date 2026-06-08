#!/bin/bash
# Downloads models/datasets from ModelScope or HuggingFace using .json config
# Usage: download-json-models.sh <config-file> <model|dataset>
#
# Each entry may set "local_dir" to override the download location. When the
# field is missing or empty, the underlying SDK's default cache is used
# (huggingface_hub -> ~/.cache/huggingface, modelscope -> ~/.cache/modelscope).
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
  local_dir=$(echo "$entry" | jq -r '.local_dir // ""')

  if [ -n "$local_dir" ]; then
    echo "Processing $TYPE: $organization/$name from $platform -> $local_dir"
    mkdir -p "$local_dir"
  else
    echo "Processing $TYPE: $organization/$name from $platform -> (SDK default cache)"
  fi

  if [ "$platform" = "modelscope" ]; then
    ms_args=(--"$TYPE" "$organization/$name")
    [ -n "$local_dir" ] && ms_args+=(--local_dir "$local_dir")
    modelscope download "${ms_args[@]}" || echo "WARNING: Failed to download $TYPE $organization/$name from ModelScope"
  elif [ "$platform" = "huggingface" ]; then
    export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
    if [ "$TYPE" = "model" ]; then
      if [ -n "$local_dir" ]; then
        python -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='$organization/$name', local_dir='$local_dir')" || echo "WARNING: Failed to download model $organization/$name from HuggingFace"
      else
        python -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='$organization/$name')" || echo "WARNING: Failed to download model $organization/$name from HuggingFace"
      fi
    else
      hf_args=("$organization/$name" --repo-type=dataset)
      [ -n "$local_dir" ] && hf_args+=(--local-dir="$local_dir")
      hf download "${hf_args[@]}" || echo "WARNING: Failed to download dataset $organization/$name from HuggingFace"
    fi
  else
    echo "Unknown platform: $platform. Skipping $organization/$name"
  fi

  echo "---"
done

echo "Completed downloading $TYPE entries from $CONFIG_FILE"
