#!/bin/bash
# Resolve a runner label / GHA-log runner (pod) name to disk clusters.
# Usage: lib-resolve.sh <runner-string> [repo]
#
# Sources, in priority order:
#   1. model-library/runner-map.json  (generated from ascend-ci-deployment
#      argocd Applications; exact label -> disk-cluster mapping.
#      Longest-key match also handles ARC pod names with hash suffixes,
#      e.g. linux-aarch64-a3-800t-8-cn12-001-7f9d8b6c5d-x2kqz)
#   2. groups.json label_rules (fallback for labels not yet in the map)
# Clusters without a registered runner are dropped with a WARN.
# Prints JSON array; exit 2 when unroutable.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/../../model-library" && pwd)"
label="${1:?usage: lib-resolve.sh <runner-string> [repo]}"
repo="${2:-}"

out=$(jq -cn --arg l "$label" --arg repo "$repo" \
      --slurpfile m "$DIR/runner-map.json" --slurpfile g "$DIR/groups.json" --slurpfile c "$DIR/clusters.json" '
  def longest($map): ($map // {} | keys | map(select($l == . or ($l | startswith(. + "-")))) | sort_by(-length) | .[0] // null);
  longest(($m[0].map_by_repo[$repo] // null)) as $krepo |
  longest($m[0].map) as $kglobal |
  (if $krepo != null then {clusters: $m[0].map_by_repo[$repo][$krepo], via: "runner-map[repo]", key: $krepo}
   elif $kglobal != null then {clusters: $m[0].map[$kglobal], via: "runner-map", key: $kglobal}
   else
     ($g[0].label_rules | map(select(. as $r | $l | test($r[0]))) | .[0][1] // null) as $machine |
     (if $machine == null then [] else
        (($m[0].map_by_repo[$repo][$machine] // null) // ($g[0].groups[$machine] // []))
      end) as $cs |
     {clusters: $cs, via: (if $machine == null then "none" else "groups" end), key: $machine}
   end) as $res |
  {clusters: ($res.clusters // [] | map(select(($c[0][.].runner // null) != null))),
   skipped: (($res.clusters // []) - ($res.clusters // [] | map(select(($c[0][.].runner // null) != null)))),
   via: $res.via, key: $res.key}')

via=$(echo "$out" | jq -r '.via')
clusters=$(echo "$out" | jq -c '.clusters')
skipped=$(echo "$out" | jq -r '.skipped | join(",")')
key=$(echo "$out" | jq -r '.key // "null"')

echo "runner=\"$label\" repo=\"$repo\" -> match=\"$key\" via=$via clusters=$clusters" >&2
# ambiguity hint: same label lives on different clusters across repos
if [ "$via" = "runner-map" ] && [ -z "$repo" ]; then
  amb=$(jq -r --arg k "$key" '[.map_by_repo[] | select(has($k)) | .[$k] | join("+")] | unique | length' "$DIR/runner-map.json" 2>/dev/null)
  [ "${amb:-1}" -gt 1 ] && echo "提示: 该标签在多个仓库下分属不同集群，请求里补 repo 可精确消歧（当前按并集）" >&2
fi
if [ "$clusters" = "[]" ]; then
  [ -n "$skipped" ] && echo "命中的集群尚未接入 runner: $skipped（接入后自动生效）" >&2
  echo "无法从该 runner 名称路由到已接入集群。精确表: model-library/runner-map.json；规则: groups.json。" >&2
  echo "也可显式传 \"clusters\": [...] 或换用 ci-deployment 里的完整 runner 标签。" >&2
  echo '[]'
  exit 2
fi
[ -n "$skipped" ] && echo "WARN: 跳过未接入 runner 的集群: $skipped" >&2
echo "$clusters"
