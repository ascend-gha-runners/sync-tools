#!/bin/bash
# Build the download matrix for the model-library workflow.
#
# A "request" is the single unit of work, provided by either entry:
#   - pull_request : files under model-requests/*.json (repo + runner_label +
#                    models[]/datasets[] + optional auth_secret)
#   - dispatch     : form fields (repo, runner_label, platform, org, name...)
#
# Routing is automatic: runner_label -> model-library/groups.json -> cluster
# list (e.g. "*800i*" -> cn12-001 + mind3 + aiframe), clusters without a
# registered runner are skipped with a warning.
#
# Matrix element: {cluster, runner, hf_cache, ms_cache, hf_endpoint,
#                  request: "<file path>" or "dispatch", payload: "<json>"}
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
CFG="$ROOT/model-library"
CLUSTERS="$CFG/clusters.json"
REQUESTS_DIR="model-requests"
RESOLVE="$ROOT/.github/scripts/lib-resolve.sh"

entry_for() {  # $1 cluster, $2 request-source, $3 payload, $4 auth-secret-mode
  local c=$1 req=$2 payload=$3 auth=${4:-none} runner hf ms ep
  runner=$(jq -r --arg c "$c" '.[$c].runner // empty' "$CLUSTERS")
  hf=$(jq -r --arg c "$c" '.[$c].caches.huggingface // empty' "$CLUSTERS")
  ms=$(jq -r --arg c "$c" '.[$c].caches.modelscope // empty' "$CLUSTERS")
  ep=$(jq -r --arg c "$c" '.[$c].endpoint // "https://hf-mirror.com"' "$CLUSTERS")
  [ -n "$runner" ] && [ -n "$hf" ] && [ -n "$ms" ] || { echo "ERROR: cluster '$c' incomplete in clusters.json" >&2; return 1; }
  jq -cn --arg c "$c" --arg r "$runner" --arg req "$req" --arg hf "$hf" --arg ms "$ms" --arg ep "$ep" --arg p "$payload" --arg a "$auth" \
    '{cluster:$c, runner:$r, request:$req, hf_cache:$hf, ms_cache:$ms, hf_endpoint:$ep, payload:$p, auth:$a}'
}

emit_for_request() {  # $1 source-desc, $2 request-json, $3 payload(for dispatch only)
  local src=$1 reqjson=$2 payload=$3 label repo clusters
  echo "$reqjson" | jq -e '(.models // []) | length > 0 or ((.datasets // []) | length > 0)' >/dev/null || {
    echo "ERROR: $src has no models/datasets" >&2; return 1; }
  label=$(echo "$reqjson" | jq -r '.runner_label // empty')
  repo=$(echo "$reqjson" | jq -r '.repo // empty')
  if echo "$reqjson" | jq -e '(.clusters // []) | length > 0' >/dev/null; then
    clusters=$(echo "$reqjson" | jq -c '.clusters')
    for c in $(echo "$clusters" | jq -r '.[]'); do
      [ -n "$(jq -r --arg c "$c" '.[$c].runner // empty' "$CLUSTERS")" ] || { echo "ERROR: $src requests unregistered/unready cluster '$c'" >&2; return 1; }
    done
  else
    [ -n "$label" ] || { echo "ERROR: $src needs runner_label (or explicit clusters)" >&2; return 1; }
    clusters=$(bash "$RESOLVE" "$label" "$repo") || return 1
  fi
  auth=$(echo "$reqjson" | jq -r '.auth_secret // "none"')
  case "$auth" in none|hf|modelscope) ;; *) echo "ERROR: $src auth_secret must be none|hf|modelscope" >&2; return 1;; esac
  for c in $(echo "$clusters" | jq -r '.[]'); do
    entry_for "$c" "$src" "$payload" "$auth" || return 1
    printf '\n'
  done
}

ENTRIES=""
case "${GITHUB_EVENT_NAME:-}" in
  pull_request|pull_request_target)
    BASE="${PR_BASE_SHA:-}"
    if [ -z "$BASE" ] || ! git cat-file -e "$BASE" 2>/dev/null; then
      BASE=$(git merge-base "origin/${GITHUB_BASE_REF:-main}" HEAD 2>/dev/null || echo HEAD~1)
    fi
    REQFILE="$REQUESTS_DIR/requests.json"
    # head 内容来源：pull_request_target 时 plan checkout 固定在 base(main) 脚本，
    # PR 提议的 requests.json 从 refs/pull/<N>/head 读（base 仓库自带该 ref，
    # 不依赖 fork 仓库可见性；只当数据读，绝不执行 head 代码）。
    HEADREF="HEAD"
    if [ -n "${PR_NUMBER:-}" ] && git fetch -q origin "+refs/pull/${PR_NUMBER}/head" 2>/dev/null; then
      HEADREF=FETCH_HEAD
    fi
    git show "$HEADREF:$REQFILE" > /tmp/requests-head.json 2>/dev/null || {
      echo "no $REQFILE in PR head"; echo "matrix=[]" >> "${GITHUB_OUTPUT:-/dev/null}"; exit 0; }
    git show "$BASE:$REQFILE" > /tmp/requests-base.json 2>/dev/null || echo '[]' > /tmp/requests-base.json
    if cmp -s /tmp/requests-base.json /tmp/requests-head.json; then
      echo "no changes to $REQFILE"; echo "matrix=[]" >> "${GITHUB_OUTPUT:-/dev/null}"; exit 0
    fi
    python3 "$ROOT/.github/scripts/lib-extract-new-requests.py" /tmp/requests-base.json /tmp/requests-head.json > /tmp/new-requests.jsonl
    n=0
    while IFS= read -r req; do
      [ -n "$req" ] || continue
      n=$((n+1))
      # fork 安全：字符串字段白名单（拒绝引号/shell 元字符/非 ASCII）
      echo "$req" | jq -e --arg x "^[A-Za-z0-9][A-Za-z0-9 .:/_-]*$" '
        ([.repo, .runner_label, ((.clusters // [ ])[ ]?),
          ((.models // [ ])[ ] | (.organization, .model_name, (.revision // ""))),
          ((.datasets // [ ])[ ] | (.organization, .dataset_name, (.revision // "")))]
         | map(select(type=="string" and length>0)) | all(test($x)))' >/dev/null || {
        echo "ERROR: request #$n 含白名单外字符（[A-Za-z0-9 .:/_-]），已拒绝" >&2; exit 1; }
      echo "== new request #$n: $(echo "$req" | jq -r '.repo + " @ " + .runner_label') (+$(echo "$req" | jq -r '((.models|length)+(.datasets|length))')) entries"
      ENTRIES="$ENTRIES$(emit_for_request "requests.json#$n" "$req" "$req")"$'\n'
    done < /tmp/new-requests.jsonl
    ;;
  workflow_dispatch)
    REQ=$(jq -n \
      --arg repo "${INPUT_REPO:-}" \
      --arg lbl "${INPUT_RUNNER_LABEL:-}" \
      --arg platform "${INPUT_PLATFORM:-modelscope}" \
      --arg org "${INPUT_ORGANIZATION:-}" \
      --arg name "${INPUT_MODEL_NAME:-}" \
      --arg rev "${INPUT_REVISION:-}" \
      --argjson legacy "${INPUT_FLATTEN_LEGACY:-false}" \
      --arg auth "${INPUT_AUTH_SECRET:-none}" \
      '{repo:$repo, runner_label:$lbl, auth_secret:$auth,
        models: [({platform:$platform, organization:$org, model_name:$name}
                  + (if $rev == "" then {} else {revision:$rev} end)
                  + (if $platform == "modelscope" and $legacy then {legacy_layout:true} else {} end))],
        datasets: []}')
    ENTRIES="$(emit_for_request "dispatch" "$REQ" "$REQ")"$'\n'
    ;;
  *)
    echo "ERROR: unsupported event ${GITHUB_EVENT_NAME}" >&2; exit 1
    ;;
esac

MATRIX=$(printf '%s' "$ENTRIES" | sed '/^$/d' | jq -sc '.')
echo "Selected requests:"; echo "$ENTRIES" | sed '/^$/d' | jq -r '.cluster + " <- " + .request' 2>/dev/null || true
echo "Matrix: $MATRIX"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "matrix=$MATRIX" >> "$GITHUB_OUTPUT"
fi
