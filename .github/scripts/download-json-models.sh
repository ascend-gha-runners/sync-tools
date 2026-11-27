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

# CI 日志节流（不牺牲可观测性）：进度帧（\r 或 \n 分帧，取最新）最多每
# PROGRESS_INTERVAL 秒放行一行，非进度行（ERROR/traceback/结果行）立即透传。
# 旧 bash `read -d $'\r'` 实现对 \n 分帧流（多文件并发 bar、modelscope 逐行进度）
# 会把多行攒成一个 blob 在开闸时整段吐出，"一行/间隔"的承诺不兑现（2026-11-27
# 用户反馈日志仍偏多）。PROGRESS_INTERVAL=0 关闭节流看全量；想彻底静默进度可
# 自行导出 HF_HUB_DISABLE_PROGRESS_BARS=1。
export PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-30}"

throttle() {  # 全局限频进度输出(stdin 即进度流;脚本走 -c,不占 stdin)
  python3 -u -c '
import sys, time
iv = float(sys.argv[1] or 0)
due = 0.0
buf = b""
def emit(b):
    global due
    s = b.decode("utf-8", "replace").strip()
    if not s:
        return
    if "%" in s and iv > 0:
        t = time.time()
        if t < due:
            return
        sys.stdout.write(s + "\n"); sys.stdout.flush(); due = t + iv
    else:
        sys.stdout.write(s + "\n"); sys.stdout.flush()
while True:
    ch = sys.stdin.buffer.read(1)
    if not ch:
        break
    if ch in (b"\r", b"\n"):
        emit(buf); buf = b""
    else:
        buf += ch
emit(buf)
' "${PROGRESS_INTERVAL:-30}"
}

failures=0
successes=0
rows=""

# 瞬时故障自动重试：镜像站 429/503、网络超时等按指数退避重试（默认 3 次尝试，
# 间隔 60s/120s/240s）；永久性错误（仓库不存在/无权限，401/404）一次即失败，
# 不浪费配额。判定靠每次尝试的错误输出（stderr 副本 + ERROR 行）匹配
# DL_TRANSIENT_RE。可调：DL_ATTEMPTS=1 关闭重试，DL_BACKOFF_BASE=秒数。
export DL_ATTEMPTS="${DL_ATTEMPTS:-3}"
export DL_BACKOFF_BASE="${DL_BACKOFF_BASE:-60}"
DL_TRANSIENT_RE='429|50[0-4]|Too Many|Service Unavailable|Bad Gateway|Gateway Tim|timed out|timeout|Temporary failure|Connection|RemoteDisconnected|Network is unreachable|getaddrinfo|SSL|Max retries'

report() {  # repo platform result landed
  rows="${rows}| ${TYPE} | $1 | $2 | $3 | $4 |
"
}

legacy_materialize() {  # org name revision
  local org=$1 name=$2 rev=${3:-}
  local cache=${MODELSCOPE_CACHE:-$HOME/.cache/modelscope}
  # modelscope >=1.38: content lives in models/<org>--<name>/snapshots/<rev> and
  # needs flattening into the classic hub/models/<org>/<name> layout.
  # <=1.37 (同步机钉版) already writes the classic layout directly under
  # $cache/models/. 旧判定只看顶层 config.json / *.safetensors，权重放子目录
  # （EAGLE3 的 full//compressed/）或名字含点（→___ 转义）时误判"不在位"，
  # 把已成功的下载翻转成 FAILURE（run 44283208990）。改为"目录存在且任意层级
  # 有文件"即在位。
  local classic="$cache/models/$org/${name//./___}"
  if [ -d "$classic" ] && [ -n "$(find "$classic" -type f -print -quit 2>/dev/null)" ]; then
    echo "classic layout already in place: $classic"
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

  # 平台校验前置（未知平台不参与重试）
  case "$platform" in modelscope|huggingface) ;; *)
    echo "Unknown platform: $platform. Skipping $repo"
    report "$repo" "$platform" "skipped (unknown platform)" "-"
    continue ;;
  esac

  # 尝试循环：瞬时错误（DL_TRANSIENT_RE 命中 stderr 副本/ERROR 行）指数退避重试，
  # 其余一次即败。ok/landed 每次重置；dl_err 为 stderr 副本 + ERROR 协议行。
  dl_err=$(mktemp /tmp/dl-err.XXXXXX)
  attempt=0
  while [ "$attempt" -lt "$DL_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 1 ]; then
      sl=$(( DL_BACKOFF_BASE * 2 ** (attempt - 2) ))
      echo "RETRY $TYPE $repo: transient error; attempt $attempt/$DL_ATTEMPTS in ${sl}s"
      sleep "$sl"
    fi
    : > "$dl_err"
    ok=0
    landed=""
  if [ "$platform" = "modelscope" ]; then
    ms_args=(--"$TYPE" "$repo")
    [ -n "$revision" ] && ms_args+=(--revision "$revision")
    [ -n "$local_dir" ] && ms_args+=(--local_dir "$local_dir")
    if modelscope download "${ms_args[@]}" 2> >(throttle | tee -a "$dl_err" >&2); then
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
      hf_model=$(python3 - "$repo" "$revision" "$local_dir" 2> >(throttle | tee -a "$dl_err" >&2) <<'PY'
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
          echo "ERROR $repo: ${hf_model#*$'\t'}" >&2
          printf '%s\n' "${hf_model#*$'\t'}" >> "$dl_err" ;;
      esac
    else
      hf_args=("$repo" --repo-type=dataset)
      [ -n "$local_dir" ] && hf_args+=(--local-dir="$local_dir")
      [ -n "$revision" ] && hf_args+=(--revision="$revision")
      if hf download "${hf_args[@]}" 2> >(throttle | tee -a "$dl_err" >&2); then
        ok=1
        landed="${local_dir:-(SDK cache)}"
      fi
    fi
  fi

    # 失败分类：命中瞬时特征且未到尝试上限 → continue（外层退避），否则终止
    if [ "$ok" = 1 ]; then
      break
    fi
    sleep 0.5  # 等 throttle|tee 异步写入落盘
    if [ "$attempt" -lt "$DL_ATTEMPTS" ] && grep -qE "$DL_TRANSIENT_RE" "$dl_err"; then
      continue
    fi
    break
  done

  if [ "$ok" = 1 ]; then
    echo "OK $TYPE $repo${landed:+ -> $landed}"
    report "$repo" "$platform" "✅ ok" "${landed:--}"
    successes=$((successes + 1))
  else
    echo "FAILURE $TYPE $repo (attempts: $attempt/$DL_ATTEMPTS)"
    echo "::error::$TYPE $repo ($platform) failed after $attempt attempt(s); one-line reason on stderr above, traceback: ${RUNNER_TEMP:-/tmp}/dl-tracebacks/"
    report "$repo" "$platform" "❌ failed (${attempt}x)" "-"
    failures=$((failures + 1))
  fi
  echo "---"
done < <(jq -c '.[]' "$CONFIG_FILE")

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "#### model/dataset sync ($TYPE batch)"
    echo
    echo "**本批合计:✅ ${successes} 成功 / ❌ ${failures} 失败**"
    echo
    echo "| type | repo | platform | result | landed |"
    echo "|--|--|--|--|--|"
    printf '%s' "$rows"
    echo
  } >> "$GITHUB_STEP_SUMMARY"
fi

# 供 job 末尾汇总步骤统计（models/datasets 两批各写一份）
printf 'ok=%s\nfail=%s\n' "$successes" "$failures" > "${DL_COUNTS_FILE:-/tmp/dl-counts-$TYPE.txt}"

echo "Completed downloading $TYPE entries from $CONFIG_FILE (successes: $successes, failures: $failures)"
[ "$failures" -eq 0 ]
