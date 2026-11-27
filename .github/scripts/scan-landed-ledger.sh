#!/bin/bash
# 扫盘：枚举共享盘上实际落位的 models/datasets，输出台账格式 JSON。
# Usage: scan-landed-ledger.sh <cluster> [out-file]      (out 默认 stdout)
#
# Env（与写端/业务端同视角）:
#   HF_HOME            默认 $HOME/.cache/huggingface（hub 在其下）
#   MODELSCOPE_CACHE   默认 $HOME/.cache/modelscope
# arc job 由 workflow 注入 clusters.json 的 caches 路径；host job 走
# /etc/profile.d/model-tools*.sh（同 download-json-models.sh 的视角）。
#
# 规则：
#  - 只收实体目录（find 默认不追软链）：原名软链不会与转义目录重复计数；
#  - 目录内无任何 >1MB 文件即视为 stub/xet 壳跳过（#151 gy001 的 8K 空壳、#138 的
#    13M 指针壳都挡得住；du 全量遍历在 NFS 上太慢，改 find -size +1M 早退）;
#  - 含 *.incomplete（hf_hub 断点续传残留）= 下载未完成，跳过——扫盘语义是
#    "在盘"，不能把半截多文件模型记成已落（请求 PR 的 download checks 才是完整性权威）。
#  - modelscope 目录名 "___" 反解析回 "."；反解析名与目录名不同时只收反解析名
#    （台账按原名记，unique_by 去重）；
#  - 新 SDK 布局 <org>--<name>/snapshots/<rev> 也识别；
#  - 输出 schema 与 model-library/<cluster>.json 完全一致，供 ledger diff。
set -uo pipefail
cluster="${1:?usage: scan-landed-ledger.sh <cluster> [out]}"
out="${2:-/dev/stdout}"
HF_ROOT="${HF_HOME:-$HOME/.cache/huggingface}/hub"
MS_ROOT="${MODELSCOPE_CACHE:-$HOME/.cache/modelscope}"
MIN=1000000

hf_scan() {  # $1=models|datasets
  local kind="$1" dir base key org name sz
  find "$HF_ROOT" -maxdepth 1 -type d -name "${kind}--*" 2>/dev/null | while IFS= read -r dir; do
    base=$(basename "$dir")
    key=${base#${kind}--}
    org=${key%%--*}; name=${key#*--}
    { [ -z "$org" ] || [ "$org" = "$key" ] || [ -z "$name" ]; } && continue
    find "$dir" -name "*.incomplete" -print -quit 2>/dev/null | grep -q . && continue
    find "$dir" -type f -size +1M -print -quit 2>/dev/null | grep -q . || continue
    if [ "$kind" = models ]; then
      jq -cn --arg o "$org" --arg n "$name" '{platform:"huggingface",organization:$o,model_name:$n}'
    else
      jq -cn --arg o "$org" --arg n "$name" '{platform:"huggingface",organization:$o,dataset_name:$n}'
    fi
  done
}

ms_flat_scan() {  # $1=容器目录(<org>/<name> 两层) $2=model|dataset
  local base="$1" t="$2" orgdir org mdir san name sz
  [ -d "$base" ] || return 0
  for orgdir in "$base"/*/; do
    [ -d "$orgdir" ] || continue
    org=$(basename "$orgdir")
    case "$org" in hub|models|datasets|tmp|*--*) continue ;; esac   # 容器名/新布局目录不是 org
    for mdir in "$orgdir"*/; do
      [ -d "$mdir" ] && [ ! -L "${mdir%/}" ] || continue
      san=$(basename "$mdir")
      case "$san" in snapshots|blobs|.no_exist|*.lock|tmp) continue ;; esac
      find "$mdir" -name "*.incomplete" -print -quit 2>/dev/null | grep -q . && continue
    find "$mdir" -type f -size +1M -print -quit 2>/dev/null | grep -q . || continue
      name=${san//___/.}
      if [ "$t" = model ]; then
        jq -cn --arg o "$org" --arg n "$name" '{platform:"modelscope",organization:$o,model_name:$n}'
      else
        jq -cn --arg o "$org" --arg n "$name" '{platform:"modelscope",organization:$o,dataset_name:$n}'
      fi
    done
  done
}

ms_new_scan() {  # 新 SDK 布局：<base>/<org>--<name>/snapshots/<rev>
  local base="$1" t="$2" d b org name sz
  [ -d "$base" ] || return 0
  for d in "$base"/*--*/; do
    b=$(basename "$d")
    case "$b" in *--*) ;; *) continue ;; esac
    [ -d "$d/snapshots" ] || continue
    org=${b%%--*}; name=${b#*--}
    find "$d" -name "*.incomplete" -print -quit 2>/dev/null | grep -q . && continue
    find "$d" -type f -size +1M -print -quit 2>/dev/null | grep -q . || continue
    if [ "$t" = model ]; then
      jq -cn --arg o "$org" --arg n "$name" '{platform:"modelscope",organization:$o,model_name:$n}'
    else
      jq -cn --arg o "$org" --arg n "$name" '{platform:"modelscope",organization:$o,dataset_name:$n}'
    fi
  done
}

models=$( { hf_scan models
            ms_flat_scan "$MS_ROOT/hub/models" model
            ms_flat_scan "$MS_ROOT/models" model
            ms_new_scan "$MS_ROOT/models" model; } | jq -sc 'unique_by(.organization+"/"+.model_name)')
datasets=$( { hf_scan datasets
              ms_flat_scan "$MS_ROOT/hub/datasets" dataset
              ms_flat_scan "$MS_ROOT/datasets" dataset
              ms_new_scan "$MS_ROOT/datasets" dataset; } | jq -sc 'unique_by(.organization+"/"+.dataset_name)')

jq -cn --arg c "$cluster" --argjson m "$models" --argjson d "$datasets" \
  '{cluster:$c, models:$m, datasets:$d, scanned_at:(now|todate)}' > "$out"
echo "scan-landed-ledger: $cluster models=$(jq '.models|length' "$out") datasets=$(jq '.datasets|length' "$out")" >&2
