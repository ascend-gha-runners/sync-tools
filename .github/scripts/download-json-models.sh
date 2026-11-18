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

# CI 日志节流（不牺牲可观测性）：进度条保留，但 tqdm 在 CI 非 TTY 下每个刷新
# 都是一行日志，大仓库动辄数千行，会把真正的错误挤出 annotation 的 "Last
# output"。throttle() 把 stderr 的 \r 进度帧聚合成最多每 PROGRESS_INTERVAL 秒
# 一行（默认 30，3 小时的大文件下载 ≈ 360 行）；非进度行原样直通。
# PROGRESS_INTERVAL=0 关闭节流看全量；想彻底静默进度可自行导出
# HF_HUB_DISABLE_PROGRESS_BARS=1。
export PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-30}"

throttle() {  # 聚合 \r 进度帧：含 % 的行按间隔放行最新一帧，其余立即透传
  local iv="${PROGRESS_INTERVAL:-30}" line frame="" due=0
  while IFS= read -r -d $'\r' line || [ -n "$line" ]; do
    line="${line%$'\n'}"
    case "$line" in
      *%*)
        frame="${line##*$'\r'}"
        if [ "$iv" -le 0 ] || [ "$SECONDS" -ge "$due" ]; then
          printf '%s\n' "$frame"; due=$((SECONDS + iv))
        fi ;;
      *)
        if [ -n "$frame" ]; then printf '%s\n' "$frame"; frame=""; due=$((SECONDS + iv)); fi
        printf '%s\n' "$line" ;;
    esac
  done
  [ -n "$frame" ] && printf '%s\n' "$frame"
}

failures=0
rows=""

report() {  # repo platform result landed
  rows="${rows}| ${TYPE} | $1 | $2 | $3 | $4 |
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
  landed=""
  if [ "$platform" = "modelscope" ]; then
    ms_args=(--"$TYPE" "$repo")
    [ -n "$revision" ] && ms_args+=(--revision "$revision")
    [ -n "$local_dir" ] && ms_args+=(--local_dir "$local_dir")
    if modelscope download "${ms_args[@]}" 2> >(throttle >&2); then
      if [ "$legacy" = "true" ] && [ -z "$local_dir" ]; then
        legacy_materialize "$organization" "$name" "$revision" && ok=1 || ok=0
      else
        ok=1
      fi
      [ "$ok" = 1 ] && landed="${local_dir:-(SDK cache)}"
    fi
  elif [ "$platform" = "huggingface" ]; then
    if [ "$TYPE" = "model" ]; then
      # 结果行（LANDED/ERROR）走 stdout 由 bash 结构化处理；进度等 stderr 一律
      # 过 throttle。完整 traceback 落 $RUNNER_TEMP/dl-tracebacks/ 供排查。
      hf_model=$(python3 - "$repo" "$revision" "$local_dir" 2> >(throttle >&2) <<'PY'
import os, sys, traceback
from huggingface_hub import snapshot_download

repo, rev, local = sys.argv[1], sys.argv[2] or None, sys.argv[3] or None
try:
    path = snapshot_download(repo_id=repo, revision=rev,
                             **({"local_dir": local} if local else {}))
    size = sum(os.path.getsize(os.path.join(dp, f))
               for dp, _, fs in os.walk(path) for f in fs)
    print(f"LANDED\t{path}\t{size}")
except Exception as e:
    tbdir = os.path.join(os.environ.get("RUNNER_TEMP", "/tmp"), "dl-tracebacks")
    os.makedirs(tbdir, exist_ok=True)
    with open(os.path.join(tbdir, repo.replace("/", "__") + ".trace"), "w") as fh:
        traceback.print_exc(file=fh)
    msg = " ".join(str(e).split())
    print(f"ERROR\t{type(e).__name__}: {msg[:200]}")
    sys.exit(1)
PY
)
      sleep 0.3  # 等 throttle 子进程写完（stderr 帧落序早于结果行）
      case "${hf_model%%$'\t'*}" in
        LANDED)
          ok=1
          landed=$(printf '%s' "$hf_model" | awk -F'\t' '{print $2" · "$3"B"}') ;;
        ERROR)
          echo "ERROR $repo: ${hf_model#*$'\t'}" >&2 ;;
      esac
    else
      hf_args=("$repo" --repo-type=dataset)
      [ -n "$local_dir" ] && hf_args+=(--local-dir="$local_dir")
      [ -n "$revision" ] && hf_args+=(--revision="$revision")
      if hf download "${hf_args[@]}" 2> >(throttle >&2); then
        ok=1
        landed="${local_dir:-(SDK cache)}"
      fi
    fi
  else
    echo "Unknown platform: $platform. Skipping $repo"
    report "$repo" "$platform" "skipped (unknown platform)"
    continue
  fi

  if [ "$ok" = 1 ]; then
    echo "OK $TYPE $repo${landed:+ -> $landed}"
    report "$repo" "$platform" "✅ ok" "${landed:--}"
  else
    echo "FAILURE $TYPE $repo"
    echo "::error::$TYPE $repo ($platform) failed; one-line reason on stderr above, traceback: ${RUNNER_TEMP:-/tmp}/dl-tracebacks/"
    report "$repo" "$platform" "❌ failed" "-"
    failures=$((failures + 1))
  fi
  echo "---"
done < <(jq -c '.[]' "$CONFIG_FILE")

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "#### model/dataset sync ($TYPE batch)"
    echo
    echo "| type | repo | platform | result | landed |"
    echo "|--|--|--|--|--|"
    printf '%s' "$rows"
    echo
  } >> "$GITHUB_STEP_SUMMARY"
fi

echo "Completed downloading $TYPE entries from $CONFIG_FILE (failures: $failures)"
[ "$failures" -eq 0 ]
