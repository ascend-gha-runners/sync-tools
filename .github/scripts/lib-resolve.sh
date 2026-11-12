#!/bin/bash
# Resolve a runner label to the list of clusters it lands on.
# Usage: lib-resolve.sh <runner_label>  -> prints JSON array; exit 2 if unroutable.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/../../model-library" && pwd)"
label="${1:?usage: lib-resolve.sh <runner_label>}"

out=$(jq -cn --arg l "$label" --slurpfile g "$DIR/groups.json" --slurpfile c "$DIR/clusters.json" '
  ($g[0].label_rules | map(select(. as $r | $l | test($r[0]))) | .[0][1] // null) as $group |
  (if $group == null then [] else ($g[0].groups[$group] // []) end) as $raw |
  {group: $group, clusters: ($raw | map(select(($c[0][.].runner // null) != null))), skipped: ($raw - ($raw | map(select(($c[0][.].runner // null) != null))))}')
clusters=$(echo "$out" | jq -c '.clusters')
group=$(echo "$out" | jq -r '.group // "null"')
skipped=$(echo "$out" | jq -r '.skipped | join(",")')

if [ "$group" = "null" ] || [ "$clusters" = "[]" ]; then
  echo "无法从 runner 标签 '$label' 路由到集群。" >&2
  [ -n "$skipped" ] && echo "命中的集群尚未接入 runner: $skipped（请先接入或联系管理员）" >&2
  echo "支持的标签模式见 model-library/groups.json" >&2
  echo '[]'
  exit 2
fi
[ -n "$skipped" ] && echo "WARN: 跳过未接入 runner 的集群: $skipped" >&2
echo "$clusters"
