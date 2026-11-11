#!/bin/bash
# Build the download matrix for the model-library workflow.
#
# Sources of truth (one-to-one registry, all under model-library/):
#   model-library/clusters.json        cluster -> runner + disk caches + endpoint
#   model-library/repos.json           business repo -> machine type -> [clusters]
#   model-library/<cluster>.json       desired model/dataset list per cluster (ledger)
#
# Selection rules:
#   pull_request  -> one entry per changed model-library/<cluster>.json
#   dispatch      -> clusters resolved from repos.json [repo][machine]
#
# Output: matrix=[{cluster, runner, library, hf_cache, ms_cache}, ...] to
# $GITHUB_OUTPUT, plus a human-readable summary step.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
CFG="$ROOT/model-library"
CLUSTERS="$CFG/clusters.json"

entry_for() {  # $1 cluster, $2 library path ("" for dispatch single model)
  local c=$1 lib=$2 runner hf ms ep
  runner=$(jq -r --arg c "$c" '.[$c].runner // empty' "$CLUSTERS")
  hf=$(jq -r --arg c "$c" '.[$c].caches.huggingface // empty' "$CLUSTERS")
  ms=$(jq -r --arg c "$c" '.[$c].caches.modelscope // empty' "$CLUSTERS")
  ep=$(jq -r --arg c "$c" '.[$c].endpoint // "https://hf-mirror.com"' "$CLUSTERS")
  if [ -z "$runner" ] || [ -z "$hf" ] || [ -z "$ms" ]; then
    echo "ERROR: cluster '$c' has no runner or cache paths in clusters.json" >&2
    return 1
  fi
  jq -cn --arg c "$c" --arg r "$runner" --arg l "$lib" --arg hf "$hf" --arg ms "$ms" --arg ep "$ep" \
    '{cluster:$c, runner:$r, library:$l, hf_cache:$hf, ms_cache:$ms, hf_endpoint:$ep}'
}

case "${GITHUB_EVENT_NAME:-}" in
  pull_request)
    BASE="${PR_BASE_SHA:-}"
    if [ -z "$BASE" ] || ! git cat-file -e "$BASE" 2>/dev/null; then
      BASE=$(git merge-base "origin/${GITHUB_BASE_REF:-main}" HEAD 2>/dev/null || echo HEAD~1)
    fi
    FILES=$(git diff --name-only "$BASE"..HEAD -- "$CFG/" | grep -vE '/(clusters|repos)\.json$' || true)
    ENTRIES=""
    for f in $FILES; do
      c=$(basename "$f" .json)
      entry=$(entry_for "$c" "$f") || exit 1
      ENTRIES="$ENTRIES$entry"$'\n'
    done
    ;;
  workflow_dispatch)
    ENTRIES=""
    if [ -n "${INPUT_RUNNER_LABEL:-}" ]; then
      # runner-label mode: union of probe-detected clusters and label-pattern
      # matches from the registry; empty model name = sync whole ledger.
      DETECTED="${INPUT_DETECTED:-[]}"
      [ -z "$DETECTED" ] && DETECTED="[]"
      CANDS=$(jq -rn --arg l "$INPUT_RUNNER_LABEL" --argjson d "$DETECTED" \
        --slurpfile c "$CLUSTERS" '
          ($d + [ $c[0] | to_entries[]
                  | select(.value.match.label_regex as $re | $re != null and ($l | test($re)))
                  | .key ]) | unique')
      LIB_OR_EMPTY=""
      [ -z "${INPUT_MODEL_NAME:-}" ] && LIB_OR_EMPTY="lib"
      for c in $(echo "$CANDS" | jq -r '.[]'); do
        if [ -n "$LIB_OR_EMPTY" ]; then
          entry=$(entry_for "$c" "model-library/$c.json") || exit 1
        else
          entry=$(entry_for "$c" "") || exit 1
        fi
        ENTRIES="$ENTRIES$entry"$'\n'
      done
      [ -n "$ENTRIES" ] || { echo "ERROR: runner label '$INPUT_RUNNER_LABEL' 未匹配任何集群（探针也没识别到）。请改用 仓库+机型 模式或补 registry。" >&2; exit 1; }
    else
      REPO="$INPUT_REPO"; MACHINE="$INPUT_MACHINE"
      CS=$(jq -r --arg r "$REPO" --arg m "$MACHINE" '.[$r][$m] // empty | .[]' "$CFG/repos.json")
      [ -n "$CS" ] || { echo "ERROR: repos.json has no clusters for repo=$REPO machine=$MACHINE" >&2; exit 1; }
      for c in $CS; do
        entry=$(entry_for "$c" "") || exit 1
        ENTRIES="$ENTRIES$entry"$'\n'
      done
    fi
    ;;
  *)
    echo "ERROR: unsupported event ${GITHUB_EVENT_NAME}" >&2; exit 1
    ;;
esac

MATRIX=$(printf '%s' "$ENTRIES" | sed '/^$/d' | jq -sc 'if length==0 then [] else . end')
echo "Matrix: $MATRIX"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "matrix=$MATRIX" >> "$GITHUB_OUTPUT"
fi
