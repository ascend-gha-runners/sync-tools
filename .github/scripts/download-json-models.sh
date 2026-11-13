#!/bin/bash
# Downloads models/datasets from ModelScope or HuggingFace using .json config
# Usage: download-json-models.sh <config-file> <model|dataset>
#
# Each entry may set:
#   "local_dir"      download location override; when missing/empty the SDK's
#                    default cache is used (huggingface_hub -> ~/.cache/huggingface,
#                    modelscope -> ~/.cache/modelscope)
#   "revision"       optional revision/branch (default branch if omitted)
#   "legacy_layout"  modelscope only: after downloading into the SDK's new
#                    layout (models/<org>--<name>/snapshots/<rev>), also
#                    materialize a flat copy at hub/models/<org>/<name>/
#                    for consumers that expect the classic layout.
#
# Exit status: every entry is attempted (failures never abort the batch),
# but the script exits 1 if at least one entry failed, so CI checks turn
# red. A per-entry table is appended to $GITHUB_STEP_SUMMARY when present.
set -uo pipefail

CONFIG_FILE="$1"
TYPE="$2"  # "model" or "dataset"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: Config file not found: $CONFIG_FILE"
  exit 1
fi

NAME_KEY="${TYPE}_name"

# default to the mirror when the caller (host profile / ARC template) has no
# preference set; mainland hosts cannot reach huggingface.co directly
export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"

# 同步机产物会被 CI 以 HF_HUB_OFFLINE=1 直读，blob 必须实体完整：
# 1) hf-mirror 不代理 Xet CAS（401）；
# 2) 实测直连 huggingface.co 的 xet materialize 弱网下会留下 80B 截断
#    safetensors 却 0 退出。故一律禁用 xet，走经典 LFS + sha256 校验。
export HF_HUB_DISABLE_XET=1

failures=0
rows=""

report() {  # repo platform result
  rows="${rows}| ${TYPE} | $1 | $2 | $3 |
"
}

legacy_materialize() {  # org name revision
  local org=$1 name=$2 rev=${3:-}
  local cache=${MODELSCOPE_CACHE:-$HOME/.cache/modelscope}
  # modelscope >=1.38: content lives in models/<org>--<name>/snapshots/<rev> and
  # needs flattening into the classic hub/models/<org>/<name> layout.
  # <=1.37 already writes the classic layout directly under $MODELSCOPE_CACHE/models/
  # (set MODELSCOPE_CACHE to .../modelscope/hub so the result is hub/models/<org>/<name>)
  if [ -f "$cache/models/$org/${name//./___}/config.json" ] || ls "$cache/models/$org/${name//./___}/"*.safetensors >/dev/null 2>&1; then
    echo "classic layout already in place: $cache/models/$org"
    return 0
  fi
  local srcroot="$cache/models/${org}--${name}/snapshots"
  [ -d "$srcroot" ] || { echo "WARNING: legacy_layout: no classic dir nor $srcroot"; return 1; }
  local src
  if [ -n "$rev" ] && [ -d "$srcroot/$rev" ]; then
    src="$srcroot/$rev"
  else
    src=$(ls -d "$srcroot"/*/ 2>/dev/null | head -1)
  fi
  [ -n "$src" ] || { echo "WARNING: legacy_layout: no snapshot dir"; return 1; }
  local dst="$cache/hub/models/$org/${name//./___}"
  mkdir -p "$dst"
  cp -a "$src/." "$dst/" || return 1
  local sb db
  sb=$(du -sb "$src" | cut -f1); db=$(du -sb "$dst" | cut -f1)
  echo "legacy_layout: $dst ($db bytes, src $sb bytes)"
  [ "$sb" -gt 0 ] && [ "$sb" = "$db" ]
}

while IFS= read -r entry; do
  platform=$(echo "$entry" | jq -r '.platform')
  organization=$(echo "$entry" | jq -r '.organization')
  name=$(echo "$entry" | jq -r ".$NAME_KEY")
  local_dir=$(echo "$entry" | jq -r '.local_dir // ""')
  revision=$(echo "$entry" | jq -r '.revision // ""')
  legacy=$(echo "$entry" | jq -r '.legacy_layout // false')
  repo="$organization/$name"

  if [ -n "$local_dir" ]; then
    echo "Processing $TYPE: $repo from $platform -> $local_dir"
    mkdir -p "$local_dir"
  else
    echo "Processing $TYPE: $repo from $platform -> (SDK default cache)"
  fi

  ok=0
  if [ "$platform" = "modelscope" ]; then
    ms_args=(--"$TYPE" "$repo")
    [ -n "$revision" ] && ms_args+=(--revision "$revision")
    [ -n "$local_dir" ] && ms_args+=(--local_dir "$local_dir")
    if modelscope download "${ms_args[@]}"; then
      if [ "$legacy" = "true" ] && [ -z "$local_dir" ]; then
        legacy_materialize "$organization" "$name" "$revision" && ok=1 || ok=0
      else
        ok=1
      fi
    fi
  elif [ "$platform" = "huggingface" ]; then
    rev_arg=""; [ -n "$revision" ] && rev_arg="revision='$revision',"
    if [ "$TYPE" = "model" ]; then
      if [ -n "$local_dir" ]; then
        python3 -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='$repo', local_dir='$local_dir', $rev_arg)" && ok=1
      else
        python3 -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='$repo', $rev_arg)" && ok=1
      fi
    else
      hf_args=("$repo" --repo-type=dataset)
      [ -n "$local_dir" ] && hf_args+=(--local-dir="$local_dir")
      [ -n "$revision" ] && hf_args+=(--revision="$revision")
      hf download "${hf_args[@]}" && ok=1
    fi
  else
    echo "Unknown platform: $platform. Skipping $repo"
    report "$repo" "$platform" "skipped (unknown platform)"
    continue
  fi

  if [ "$ok" = 1 ]; then
    echo "OK $TYPE $repo"
    report "$repo" "$platform" "✅ ok"
  else
    echo "FAILURE $TYPE $repo"
    report "$repo" "$platform" "❌ failed"
    failures=$((failures + 1))
  fi
  echo "---"
done < <(jq -c '.[]' "$CONFIG_FILE")

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "#### model/dataset sync ($TYPE batch)"
    echo
    echo "| type | repo | platform | result |"
    echo "|--|--|--|--|"
    printf '%s' "$rows"
    echo
  } >> "$GITHUB_STEP_SUMMARY"
fi

echo "Completed downloading $TYPE entries from $CONFIG_FILE (failures: $failures)"
[ "$failures" -eq 0 ]
