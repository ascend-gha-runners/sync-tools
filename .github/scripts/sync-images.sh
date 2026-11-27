set -eo pipefail

get_creds() {
  case "$1" in
    quay.io/atlas_inference/*) echo "${QUAY_ATLAS_INFERENCE_USER}:${QUAY_ATLAS_INFERENCE_PWD}" ;;
    quay.io/*)              echo "${QUAY_ASCEND_USER}:${QUAY_ASCEND_PWD}" ;;
    docker.io/*)            echo "${DOCKERHUB_USER}:${DOCKERHUB_PWD}" ;;
    swr.cn-southwest-2.*)   echo "${HWCLOUD_USER}:${HWCLOUD_PWD}" ;;
    swr.cn-east-3.*)        echo "${SWR_EAST3_USER}:${SWR_EAST3_SECRET}" ;;
    swr.ap-southeast-1.*)   echo "${SWR_HK_USER}:${SWR_HK_SECRET}" ;;
    swr.cn-north-12.*)      echo "${SWR_NORTH12_USER}:${SWR_NORTH12_SECRET}" ;;
    swr.cn-north-4.*)       echo "${SWR_NORTH4_USER}:${SWR_NORTH4_SECRET}" ;;
    *)                      echo "" ;;
  esac
}

build_inspect_args() {
  local var="$1" creds="$2"
  [ -n "$creds" ] && eval "${var}=(--creds \"$creds\")" || eval "${var}=(--no-creds)"
}

build_copy_src_args() {
  local var="$1" creds="$2"
  [ -n "$creds" ] && eval "${var}=(--src-creds \"$creds\")" || eval "${var}=(--src-no-creds)"
}

build_copy_dest_args() {
  local var="$1" creds="$2"
  [ -n "$creds" ] && eval "${var}=(--dest-creds \"$creds\")" || eval "${var}=(--dest-no-creds)"
}

# 比较各平台子 manifest digest 列表（content-addressed，跨 registry 稳定）
# 避免 Docker Hub 重新序列化 manifest list 导致顶层 digest 不一致。
#
# 返回码：
#   0 = 成功，stdout 是 manifest id
#   3 = registry 明确返回 MANIFEST_UNKNOWN / NAME_UNKNOWN（确认 tag 不存在）
#   4 = 重试后仍然失败（网络/5xx/超时/未知），调用方禁止 copy
#   5 = 鉴权/权限/配置错误，调用方禁止 copy，并让 job 失败
#   6 = 限速（429 / toomanyrequests）：Docker Hub 拉取配额 200/h（实测 header
#       200;w=3600，全仓库共享，还要留给 docker.io 源头的 tag 拉取）。配额按
#       时间窗恢复，重试纯属浪费时间（旧逻辑每个限速 tag 磨 5×35s≈3min，
#       一次 run 白烧几十分钟），立即返回并让调用方熔断该目的地。
INSPECT_ATTEMPTS="${INSPECT_ATTEMPTS:-5}"
INSPECT_DELAY="${INSPECT_DELAY:-5}"
INSPECT_TIMEOUT="${INSPECT_TIMEOUT:-60s}"
export INSPECT_ATTEMPTS INSPECT_DELAY INSPECT_TIMEOUT

get_manifest_id() {
  local image="${!#}"
  local attempt=1 raw err msg id status
  while [ "$attempt" -le "$INSPECT_ATTEMPTS" ]; do
    err=$(mktemp)
    if raw=$(skopeo --command-timeout "$INSPECT_TIMEOUT" inspect --raw "$@" 2>"$err"); then
      id=$(printf '%s' "$raw" | jq -r '
        if .manifests then
          [.manifests[].digest] | sort | join(",")
        else
          .config.digest // empty
        end
      ' 2>/dev/null) || id=""
      if [ -n "$id" ]; then
        rm -f "$err"
        printf '%s' "$id"
        return 0
      fi
      msg="manifest 解析后 digest 为空"
    else
      msg=$(tr '\n' ' ' < "$err")
    fi
    rm -f "$err"

    status=$(printf '%s' "$msg" | grep -oE 'unexpected HTTP status: [0-9]{3}' | grep -oE '[0-9]{3}' | head -n1 || true)

    # 限速：配额耗尽，立即失败，不重试。调用方见到 rc=6 会熔断该目的地，
    # 避免后续 tag 继续无意义地打 API。
    if [ "$status" = "429" ] || printf '%s' "$msg" | grep -qiE 'toomanyrequests|too many requests|rate ?limit'; then
      echo "::error title=Inspect rate limited::$image: $msg" >&2
      return 6
    fi

    # 鉴权/权限/配置错误：重试没有意义，直接失败（禁止 copy）
    if [ "$status" = "401" ] || [ "$status" = "403" ] \
       || printf '%s' "$msg" | grep -qiE 'unauthorized|authentication required|denied|invalid username/password|forbidden|not authorized'; then
      echo "::error title=Inspect auth failed::$image: $msg" >&2
      return 5
    fi

    # registry 明确返回 MANIFEST_UNKNOWN / NAME_UNKNOWN：确认不存在
    if printf '%s' "$msg" | grep -qiE 'manifest unknown|name unknown'; then
      echo "inspect: $image not found" >&2
      return 3
    fi

    # 只有 HTTP 404、没有 registry 错误码：可能是代理/路径问题，按未知处理（禁止 copy）
    if [ "$status" = "404" ]; then
      echo "::warning title=Inspect ambiguous 404::$image: $msg" >&2
    fi

    echo "::warning title=Inspect failed::attempt $attempt/$INSPECT_ATTEMPTS for $image: $msg" >&2
    attempt=$((attempt + 1))
    if [ "$attempt" -le "$INSPECT_ATTEMPTS" ]; then
      sleep "$INSPECT_DELAY"
    fi
  done
  echo "::warning title=Inspect failed::giving up on $image after $INSPECT_ATTEMPTS attempts; no sync" >&2
  return 4
}

# list-tags 失败时直接让 job 失败；不能把“查不到 tag”当成“没有 tag”。
list_tags() {
  skopeo --command-timeout "$INSPECT_TIMEOUT" list-tags \
    --retry-times "$INSPECT_ATTEMPTS" "$@"
}

CONFIG=".github/workflows/config/image-sync.json"
SRC="$CURRENT_SRC"
CACHE_FILE="/tmp/digest-cache/$(echo "$SRC" | tr '/:' '__').json"
mkdir -p /tmp/digest-cache
[ -f "$CACHE_FILE" ] || echo '{}' > "$CACHE_FILE"

# 获取该 src 的所有 dest 和 tag_filter（取第一个 tag_filter，同一 src 应一致）
DESTS=$(jq -r --arg src "$SRC" '.[] | select(.src == $src) | .dest' "$CONFIG")
TAG_FILTER=$(jq -r --arg src "$SRC" 'first(.[] | select(.src == $src) | .tag_filter // empty)' "$CONFIG")

SRC_CREDS=$(get_creds "$SRC")
SRC_INSPECT_ARGS_ARRAY=()
build_inspect_args SRC_INSPECT_ARGS_ARRAY "$SRC_CREDS"

# 获取 tag 列表（只做一次）
if [ -n "$TAG_FILTER" ]; then
  if [[ "$SRC" == docker.io/* ]]; then
    # Docker Hub 源：走分页 API 过滤，避免触发拉取限速。
    # 匿名分页最多 10 页（1000 tag），超过返回 403
    # "pagination offset too large for anonymous requests"，
    # 带 DOCKERHUB 登录 token 后可继续翻页。
    repo=$(echo "$SRC" | sed 's|docker\.io/||')
    DH_PAGE_CAP=10
    DH_AUTH_MODE=anonymous
    DH_AUTH_ARGS=()
    if [ -n "$DOCKERHUB_USER" ] && [ -n "$DOCKERHUB_PWD" ]; then
      login_body=$(jq -cn --arg u "$DOCKERHUB_USER" --arg p "$DOCKERHUB_PWD" '{username:$u,password:$p}')
      if dh_token=$(curl -sf --retry 3 --retry-delay 3 \
          -H "Content-Type: application/json" -d "$login_body" \
          "https://hub.docker.com/v2/users/login" | jq -r '.token // empty') \
         && [ -n "$dh_token" ]; then
        DH_AUTH_ARGS=(-H "Authorization: Bearer ${dh_token}")
        DH_AUTH_MODE=bearer
        DH_PAGE_CAP="${DOCKERHUB_PAGE_CAP:-50}"
      else
        echo "::warning title=Docker Hub auth failed::failed to obtain Docker Hub token; anonymous pagination capped at ${DH_PAGE_CAP} pages"
      fi
    else
      echo "::warning title=Docker Hub anonymous::DOCKERHUB_USER/DOCKERHUB_PWD not set; anonymous pagination capped at ${DH_PAGE_CAP} pages"
    fi
    TAGS="" next_url="https://hub.docker.com/v2/repositories/${repo}/tags/?page_size=100" page=1
    while [ "$next_url" != "null" ] && [ "$page" -le "$DH_PAGE_CAP" ]; do
      if ! resp=$(curl -sf --retry 5 --retry-delay 5 "${DH_AUTH_ARGS[@]}" "$next_url"); then
        echo "::error title=List tags failed::Docker Hub API request failed: $next_url (page=$page, auth=$DH_AUTH_MODE)"
        exit 1
      fi
      page_tags=$(echo "$resp" | jq -r --arg f "$TAG_FILTER" '.results[] | select(.name | test($f; "i")) | .name' 2>/dev/null || true)
      [ -n "$page_tags" ] && TAGS="$TAGS"$'\n'"$page_tags"
      if ! next_url=$(echo "$resp" | jq -r '.next // "null"'); then
        echo "::error title=List tags failed::invalid Docker Hub API response: $next_url"
        exit 1
      fi
      page=$((page + 1))
    done
    if [ "$next_url" != "null" ]; then
      if [ "$DH_AUTH_MODE" = "bearer" ]; then
        echo "::warning title=Tag list truncated::stopped at page ${DH_PAGE_CAP} for $SRC; more tags exist, raise DOCKERHUB_PAGE_CAP to include them"
      else
        echo "::warning title=Tag list truncated::stopped at page ${DH_PAGE_CAP} for $SRC; more tags exist, but pagination is anonymous (capped at 10 pages). Set valid DOCKERHUB_USER/DOCKERHUB_PWD to lift the cap"
      fi
    fi
    TAGS=$(echo "$TAGS" | sed '/^$/d' | sort -u)
  else
    # 非 Docker Hub 源（如 quay.io）：list-tags 后按关键词过滤
    if ! TAGS_RAW=$(list_tags "${SRC_INSPECT_ARGS_ARRAY[@]}" docker://"$SRC" 2>/tmp/list_tags_err); then
      echo "::error title=List tags failed::$SRC: $(tr '\n' ' ' < /tmp/list_tags_err)"
      exit 1
    fi
    if ! TAGS=$(printf '%s' "$TAGS_RAW" | jq -r --arg f "$TAG_FILTER" '.Tags[] | select(test($f; "i"))'); then
      echo "::error title=List tags failed::cannot parse list-tags output for $SRC"
      exit 1
    fi
    TAGS=$(printf '%s\n' "$TAGS" | sed '/^$/d' | sort -u)
  fi
else
  if ! TAGS_RAW=$(list_tags "${SRC_INSPECT_ARGS_ARRAY[@]}" docker://"$SRC" 2>/tmp/list_tags_err); then
    echo "::error title=List tags failed::$SRC: $(tr '\n' ' ' < /tmp/list_tags_err)"
    exit 1
  fi
  if ! TAGS=$(printf '%s' "$TAGS_RAW" | jq -r '.Tags[]'); then
    echo "::error title=List tags failed::cannot parse list-tags output for $SRC"
    exit 1
  fi
fi

if [ -z "$TAGS" ]; then
  echo "No tags found for $SRC"
  exit 0
fi

TAG_COUNT=$(echo "$TAGS" | wc -l)
echo "Found $TAG_COUNT tags for $SRC"

# ---------------------------------------------------------------------------
# 两段式结构（替代原来的「dest 外层 × tag 内层」纯串行双循环）：
#
# 1) pre-pass：每个 tag 只做一次源 inspect。旧实现对每个 dest 都重复查源
#    （API 量 = tags × dests × 2 次 inspect，注释声称“src inspect 复用”但
#    从未实现）；源 digest 是 tag 的属性、与 dest 无关，算一次就够。
# 2) per-dest：tag 级并行（skip 路径是纯 I/O 延迟等待，串行是耗时大头——
#    实测 1328 tag 全 skip 也要 78 分钟）。docker.io 走缓存（#154 语义保留：
#    未命中才实时 inspect 兜底，digest 一致回写缓存自愈）；其它 dest 实时
#    inspect 比对；确实变化的才 copy。
#
# docker.io 兜底 inspect 的单轮配额预算（#154 分支 fbe3e57 的机制，并行化
# 移植）：Docker Hub 拉取配额是**账号级共享、200/6h**（官方文档口径；匿名
# 100/6h），还要留给 docker.io 源头的 tag 拉取。超出预算的 tag 本轮不验证
# 也不 copy，计为 deferred（不是失败，job 保持绿），下一轮继续——缓存跨轮
# 增量自愈，全程不重推。并行下用追加计数文件实现（check-then-append 有
# ≤ 并行度的轻微超额，可接受）。
# 默认上限取保守值（40/轮）：6 小时窗口内跑 ~6 轮，40×6=240 接近 200 上限，
# 留不出 docker.io 源头的量；真实额度以运行时读 remaining 为准（见下）。
DEST_INSPECT_BUDGET="${DEST_INSPECT_BUDGET:-40}"
SAFETY_MARGIN="${SAFETY_MARGIN:-60}"
export DEST_INSPECT_BUDGET
TAG_PARALLELISM="${TAG_PARALLELISM:-8}"
MAX_INSPECT_FAILURES="${MAX_INSPECT_FAILURES:-10}"
export TAG_PARALLELISM MAX_INSPECT_FAILURES

SRC_MAP=$(mktemp)         # "tag <TAB> rc <TAB> digest"
CACHE_UPDATES=$(mktemp)   # "DEST:tag <TAB> digest"
BUDGET_FILE=$(mktemp)     # docker.io 兜底 inspect 配额：一行一次

# 自适应预算：真实额度以运行时 Docker Hub 返回的 ratelimit-remaining 为准
# （账号级共享、200/6h）。budget = min(上限, remaining - SAFETY_MARGIN)，
# SAFETY_MARGIN 留给 docker.io 源头（sglang 等）与同窗口内的后续 run。
# 读不到 remaining（网络/token 失败）时退回固定上限（40，保守）。
EFFECTIVE_BUDGET="$DEST_INSPECT_BUDGET"
if printf '%s\n' "$DESTS" | grep -q '^docker\.io/'; then
  _rt=$(curl -sf "https://auth.docker.io/token?service=registry.docker.io&scope=repository:ratelimitpreview/test:pull" \
    -u "${DOCKERHUB_USER}:${DOCKERHUB_PWD}" 2>/dev/null | jq -r '.token // empty' 2>/dev/null || true)
  if [ -n "$_rt" ]; then
    _rem=$(curl -sf -I -H "Authorization: Bearer ${_rt}" \
      "https://registry-1.docker.io/v2/ratelimitpreview/test/manifests/latest" 2>/dev/null \
      | tr -d '\r' | grep -i '^ratelimit-remaining:' | grep -oE '[0-9]+' | head -n1 || true)
    if [ -n "$_rem" ]; then
      _b=$((_rem - SAFETY_MARGIN))
      [ "$_b" -lt 0 ] && _b=0
      [ "$_b" -lt "$EFFECTIVE_BUDGET" ] && EFFECTIVE_BUDGET="$_b"
      echo "Docker Hub pull quota remaining: $_rem → adaptive dest-inspect budget: $EFFECTIVE_BUDGET"
    fi
  fi
fi
export EFFECTIVE_BUDGET

# 每个缓存键写回 CACHE_FILE（顺序执行，主 shell 独占，无并发写）。
# 缓存只是性能优化（#154 确立的不变式），合并失败不致命，告警后继续。
merge_cache_updates() {
  [ -s "$CACHE_UPDATES" ] || return 0
  local key val tmp
  while IFS=$'\t' read -r key val; do
    [ -n "$key" ] && [ -n "$val" ] || continue
    tmp=$(mktemp)
    if jq --arg key "$key" --arg val "$val" '.[$key] = $val' "$CACHE_FILE" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$CACHE_FILE"
    else
      rm -f "$tmp"
      echo "::warning title=Cache merge failed::cannot write cache entry $key"
    fi
  done < "$CACHE_UPDATES"
  : > "$CACHE_UPDATES"
}
# timeout/取消兜底：步骤被 timeout-minutes 杀掉时尽力把已完成的 dest 的
# 缓存增量合并掉（save 步骤 if: always() 仍会执行，别让进度白跑）。
# handler 里必须带退出动作，否则被中断的脚本会继续跑到 runner 升级 SIGKILL。
trap 'merge_cache_updates 2>/dev/null || true; exit 130' INT
trap 'merge_cache_updates 2>/dev/null || true; exit 143' TERM
trap 'merge_cache_updates 2>/dev/null || true' EXIT

src_tag_worker() {
  local tag="$1" args=() digest rc
  build_inspect_args args "$SRC_CREDS"
  digest=$(get_manifest_id "${args[@]}" "docker://$SRC:$tag")
  rc=$?
  printf '%s\t%s\t%s\n' "$tag" "$rc" "$digest" >> "$SRC_MAP"
}

# dest 级熔断：限速（配额是账号级的，同 dest 继续 query 毫无意义）
quota_abort_dest() {
  echo "⏭️  Skip $1 (destination rate-limited; aborting this destination)"
  printf 'inspect_failed\t%s\n' "$1" >> "$EVENTS"
  echo "::error::$SRC → $DEST: destination inspect hit rate limit; aborting this destination" >&2
  : > "$ABORT_FILE" || true
}

# dest 级熔断：失败总数超过预算（并行下替代旧的“连续失败”计数）
check_failure_budget() {
  local n
  n=$(awk -F'\t' '$1=="inspect_failed"' "$EVENTS" 2>/dev/null | wc -l)
  if [ "${n:-0}" -ge "$MAX_INSPECT_FAILURES" ]; then
    echo "::error::$SRC → $DEST: too many inspect failures ($n >= $MAX_INSPECT_FAILURES); aborting this destination" >&2
    : > "$ABORT_FILE" || true
  fi
}

dest_tag_worker() {
  local tag="$1"
  # dest 已熔断：速退，不再打 API（不写事件——由 aborted 计数兜底）
  [ -e "$ABORT_FILE" ] && return 0

  local row rc src_digest
  row=$(awk -F'\t' -v t="$tag" '$1==t{print; exit}' "$SRC_MAP" 2>/dev/null)
  if [ -z "$row" ]; then
    printf 'inspect_failed\t%s\n' "$tag" >> "$EVENTS"
    echo "⏭️  Skip $tag (source digest missing from pre-pass, no sync)"
    check_failure_budget
    return 0
  fi
  rc=${row#*$'\t'}
  rc=${rc%%$'\t'*}
  src_digest=${row##*$'\t'}

  local src_img="docker://$SRC:$tag" dest_img="docker://$DEST:$tag"
  echo "from=\"$src_img\" to=\"$dest_img\""

  if [ "$rc" -eq 3 ]; then
    echo "⏭️  Skip $tag (source tag not found)"
    printf 'skipped\t%s\n' "$tag" >> "$EVENTS"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    echo "⏭️  Skip $tag (source inspect failed, no sync)"
    printf 'inspect_failed\t%s\n' "$tag" >> "$EVENTS"
    check_failure_budget
    return 0
  fi

  local dest_args=()
  build_inspect_args dest_args "$DEST_CREDS"
  local copy_src_args=() copy_dest_args=()
  build_copy_src_args copy_src_args "$SRC_CREDS"
  build_copy_dest_args copy_dest_args "$DEST_CREDS"

  local d_digest d_rc
  if [[ "$DEST" == docker.io/* ]]; then
    # docker.io 目的地：优先信缓存（不消耗 Docker Hub 拉取配额）。
    # 缓存存的是上次同步成功时的源 digest，命中即证明未变更，不查 dest。
    local cached
    cached=$(jq -r --arg key "$DEST:$tag" '.[$key] // empty' "$CACHE_FILE" 2>/dev/null)
    if [ -n "$cached" ] && [ "$src_digest" = "$cached" ]; then
      echo "⏭️  Skip $tag (cache)"
      printf 'skipped\t%s\n' "$tag" >> "$EVENTS"
      # skip 时也回写，确保本次 run 的 cache 是完整的
      printf '%s:%s\t%s\n' "$DEST" "$tag" "$src_digest" >> "$CACHE_UPDATES"
      return 0
    fi
    # 缓存未命中（冷启动/淘汰/格式迁移）：实时 inspect dest 兜底。
    # 硬保证（#154）：内容未变的 tag 绝不重 PUT manifest——重推会刷新
    # Docker Hub 的 last_updated 时间戳。缓存只是省 API 调用的优化，
    # 不作为正确性依据。digest 一致 → 跳过并回写缓存自愈。
    # 每 tag 1 次 GET（计入 200/h 拉取配额），因此有预算上限，跨轮收敛。
    local used
    used=$(wc -l < "$BUDGET_FILE")
    if [ "$used" -ge "$EFFECTIVE_BUDGET" ]; then
      echo "⏭️  Skip $tag (dest inspect budget exhausted this run; retry next run)"
      printf 'deferred\t%s\n' "$tag" >> "$EVENTS"
      return 0
    fi
    printf 'x\n' >> "$BUDGET_FILE"
    d_digest=$(get_manifest_id "${dest_args[@]}" "$dest_img")
    d_rc=$?
    if [ "$d_rc" -eq 6 ]; then
      quota_abort_dest "$tag"
      return 0
    fi
    if [ "$d_rc" -ne 0 ] && [ "$d_rc" -ne 3 ]; then
      echo "⏭️  Skip $tag (destination inspect failed, no sync)"
      printf 'inspect_failed\t%s\n' "$tag" >> "$EVENTS"
      check_failure_budget
      return 0
    fi
    if [ "$d_rc" -eq 0 ] && [ "$src_digest" = "$d_digest" ]; then
      echo "⏭️  Skip $tag (dest digest match; cache healed)"
      printf 'skipped\t%s\n' "$tag" >> "$EVENTS"
      printf '%s:%s\t%s\n' "$DEST" "$tag" "$src_digest" >> "$CACHE_UPDATES"
      return 0
    fi
    # d_rc == 3（dest 无此 tag）或 digest 不同（源真变了）→ 走 copy
  else
    # 其它目的地：实时 inspect 比对（不依赖缓存）
    d_digest=$(get_manifest_id "${dest_args[@]}" "$dest_img")
    d_rc=$?
    if [ "$d_rc" -eq 6 ]; then
      quota_abort_dest "$tag"
      return 0
    fi
    if [ "$d_rc" -ne 0 ] && [ "$d_rc" -ne 3 ]; then
      echo "⏭️  Skip $tag (destination inspect failed, no sync)"
      printf 'inspect_failed\t%s\n' "$tag" >> "$EVENTS"
      check_failure_budget
      return 0
    fi
    if [ "$d_rc" -eq 0 ] && [ "$src_digest" = "$d_digest" ]; then
      echo "⏭️  Skip $tag"
      printf 'skipped\t%s\n' "$tag" >> "$EVENTS"
      return 0
    fi
    # d_rc == 3 表示 registry 明确返回 tag 不存在，继续走 copy
  fi

  echo "Syncing $tag..."
  skopeo copy --all \
    --retry-times 3 \
    --retry-delay 5s \
    "${copy_src_args[@]}" \
    "${copy_dest_args[@]}" \
    "$src_img" "$dest_img"
  local copy_rc=$?
  if [ $copy_rc -eq 0 ]; then
    echo "✅ Synced $tag"
    printf 'synced\t%s\n' "$tag" >> "$EVENTS"
    if [[ "$DEST" == docker.io/* ]] && [ -n "$src_digest" ]; then
      printf '%s:%s\t%s\n' "$DEST" "$tag" "$src_digest" >> "$CACHE_UPDATES"
    fi
  elif [ $copy_rc -eq 2 ]; then
    # skopeo 退出码 2 无公开语义（#155 遗留项，源自 #80）：不能直接当成功——
    # 若为假成功且写缓存，缓存会永久掩盖缺 tag。live inspect 校验 digest
    # 真的落位后才计数/写缓存，否则按失败处理（下一轮重试）。
    local verify v_rc
    verify=$(get_manifest_id "${dest_args[@]}" "$dest_img")
    v_rc=$?
    if [ "$v_rc" -eq 0 ] && [ "$verify" = "$src_digest" ]; then
      echo "✅ Synced $tag (copy exit 2, verified by dest inspect)"
      printf 'synced\t%s\n' "$tag" >> "$EVENTS"
      if [[ "$DEST" == docker.io/* ]] && [ -n "$src_digest" ]; then
        printf '%s:%s\t%s\n' "$DEST" "$tag" "$src_digest" >> "$CACHE_UPDATES"
      fi
    else
      echo "❌ Failed $tag (exit 2, dest verify rc=$v_rc, digest mismatch)"
      printf 'copy_failed\t%s\n' "$tag" >> "$EVENTS"
    fi
  else
    echo "❌ Failed $tag (exit $copy_rc)"
    printf 'copy_failed\t%s\n' "$tag" >> "$EVENTS"
  fi
}

export -f get_manifest_id list_tags build_inspect_args build_copy_src_args build_copy_dest_args
export -f src_tag_worker dest_tag_worker quota_abort_dest check_failure_budget
export SRC SRC_CREDS SRC_MAP CACHE_FILE CACHE_UPDATES BUDGET_FILE

# ---- 1) pre-pass：并行取全部源 digest（一次）----
echo "Pre-pass: inspecting source digests for $TAG_COUNT tags (parallelism=$TAG_PARALLELISM)..."
printf '%s\n' "$TAGS" | xargs -P "$TAG_PARALLELISM" -n 1 bash -c 'src_tag_worker "$1"' _ || true

# ---- 2) per-dest：tag 级并行同步 ----
for DEST in $DESTS; do
  echo ""
  echo "--- $SRC → $DEST ---"
  DEST_CREDS=$(get_creds "$DEST")
  EVENTS=$(mktemp)
  ABORT_FILE=$(mktemp)
  rm -f "$ABORT_FILE"

  export DEST DEST_CREDS EVENTS ABORT_FILE
  printf '%s\n' "$TAGS" | xargs -P "$TAG_PARALLELISM" -n 1 bash -c 'dest_tag_worker "$1"' _ || true

  SYNCED=$(awk -F'\t' '$1=="synced"' "$EVENTS" | wc -l)
  SKIPPED=$(awk -F'\t' '$1=="skipped"' "$EVENTS" | wc -l)
  INSPECT_FAILED=$(awk -F'\t' '$1=="inspect_failed"' "$EVENTS" | wc -l)
  FAILED=$(awk -F'\t' '$1=="copy_failed"' "$EVENTS" | wc -l)
  DEFERRED=$(awk -F'\t' '$1=="deferred"' "$EVENTS" | wc -l)
  echo "Done [$SRC → $DEST]: $SYNCED synced, $SKIPPED skipped, $INSPECT_FAILED inspect-failed, $FAILED failed"

  if [ "$DEFERRED" -gt 0 ]; then
    echo "Dest inspect budget: used $(wc -l < "$BUDGET_FILE")/$EFFECTIVE_BUDGET; $DEFERRED tag(s) deferred to next run (no copy, no re-push)"
  fi
  # 熔断/速退的 tag 不写事件，五项之和 < TAG_COUNT 时显式对账，避免计数不闭合
  ABORTED=$((TAG_COUNT - SYNCED - SKIPPED - INSPECT_FAILED - FAILED - DEFERRED))
  if [ "$ABORTED" -gt 0 ]; then
    echo "Circuit breaker: $ABORTED tag(s) skipped without processing (aborted)"
  fi

  merge_cache_updates

  if [[ "$DEST" == docker.io/* ]]; then
    rate_token=$(curl -sf "https://auth.docker.io/token?service=registry.docker.io&scope=repository:ratelimitpreview/test:pull" \
      -u "${DOCKERHUB_USER}:${DOCKERHUB_PWD}" 2>/dev/null | jq -r '.token // empty' 2>/dev/null || true)
    rate=$(curl -sf -I -H "Authorization: Bearer ${rate_token}" \
      "https://registry-1.docker.io/v2/ratelimitpreview/test/manifests/latest" 2>/dev/null \
      | grep -i ratelimit-remaining | tr -d '\r' || echo "unknown")
    echo "Docker Hub rate limit remaining: $rate"
  fi

  rm -f "$EVENTS" "$ABORT_FILE"
  unset EVENTS ABORT_FILE DEST DEST_CREDS

  # 与旧逻辑一致：任一 dest 出现失败即中止本 job（剩余 dest 留给下一轮）。
  # deferred 不算失败——配额预算跨轮收敛是设计行为，不是事故。
  if [ "$FAILED" -ne 0 ] || [ "$INSPECT_FAILED" -ne 0 ]; then
    exit 1
  fi
done
