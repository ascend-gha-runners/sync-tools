#!/bin/bash
# Audit-only mode for push (post-merge) runs: verify entries from the
# prepared /tmp/models.json + /tmp/datasets.json actually exist in this
# cluster's shared cache. NEVER re-downloads (re-download on merge would
# block the per-runner serial queue for large models).
# Env expected: MODELSCOPE_CACHE, HF_HOME (set by the workflow job).
# Exit 1 if anything is missing; job summary lists every entry.
set -uo pipefail
fail=0
rows=""
check() { # $1 kind, $2 json file
  local kind=$1 file=$2
  [ -f "$file" ] || return 0
  while IFS= read -r e; do
    local org name plat found="" sz=0 p
    org=$(echo "$e" | jq -r '.organization')
    name=$(echo "$e" | jq -r '.model_name // .dataset_name // "?"')
    plat=$(echo "$e" | jq -r '.platform')
    if [ "$plat" = "modelscope" ]; then
      local san=${name//./___}
      if [ "$kind" = dataset ]; then
        for p in "$MODELSCOPE_CACHE/hub/datasets/$org/$san" "$MODELSCOPE_CACHE/datasets/$org/$san" "$MODELSCOPE_CACHE/$org/$san"; do
          [ -d "$p" ] && found=$p && break
        done
      else
        for p in "$MODELSCOPE_CACHE/hub/models/$org/$san" "$MODELSCOPE_CACHE/models/$org/$san" "$MODELSCOPE_CACHE/models/${org}--${name}/snapshots"; do
          [ -d "$p" ] && found=$p && break
        done
      fi
    else
      if [ "$kind" = dataset ]; then
        p="$HF_HOME/hub/datasets--${org}--${name}"
      else
        p="$HF_HOME/hub/models--${org}--${name}"
      fi
      [ -d "$p" ] && found=$p
    fi
    [ -n "$found" ] && sz=$(du -sb "$found" 2>/dev/null | cut -f1)
    if [ -n "$found" ] && [ "${sz:-0}" -gt 1000000 ]; then
      rows="${rows}| ${kind} | ${org}/${name} | ✅ ${sz} B |\n"
    else
      rows="${rows}| ${kind} | ${org}/${name} | ❌ 未落盘（请用 model library dispatch 补下） |\n"
      fail=1
    fi
  done < <(jq -c '.[]' "$file")
}
check model /tmp/models.json
check dataset /tmp/datasets.json

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "#### 台账审计（merge 后核对，不重新下载）"
    echo
    echo "| type | repo | result |"
    echo "|--|--|--|"
    printf '%b' "$rows"
  } >> "$GITHUB_STEP_SUMMARY"
fi
[ "$fail" = 0 ] && echo "audit: all entries present"
exit $fail
