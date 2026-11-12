#!/bin/bash
# Resolve a runner label / GHA-log runner name to the cluster list.
# Usage: lib-resolve.sh <runner-string> [repo]
#   <runner-string> may be a bare label (linux-aarch64-a3-800i-8-cn12-001)
#   or the ARC pod name seen in workflow logs (label + "-abcde-12345" hash
#   suffixes) - matching is substring-based, hash tails are ignored.
# Resolution order:
#   1. label_rules -> machine token
#   2. repos.json[repo][machine]  (同一标签不同仓库 provider 集群不同)
#   3. groups.json groups[machine] (兜底)
#   clusters without a registered runner are filtered out (WARN on stderr).
# Prints JSON array; exit 2 when unroutable.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/../../model-library" && pwd)"
label="${1:?usage: lib-resolve.sh <runner-string> [repo]}"
repo="${2:-}"

out=$(jq -cn --arg l "$label" --arg repo "$repo" \
      --slurpfile g "$DIR/groups.json" --slurpfile c "$DIR/clusters.json" --slurpfile rp "$DIR/repos.json" '
  ($g[0].label_rules | map(select(. as $r | $l | test($r[0]))) | .[0][1] // null) as $machine |
  (if $machine == null then [] else
     ( ($rp[0][$repo][$machine] // null) as $byrepo |
       if $byrepo != null then $byrepo else ($g[0].groups[$machine] // []) end )
   end) as $raw |
  {machine: $machine, source: (if $repo != null and $rp[0][$repo] and $machine and ($rp[0][$repo][$machine] != null) then "repos.json" else "groups.json" end),
   clusters: ($raw | map(select(($c[0][.].runner // null) != null))),
   skipped:  ($raw - ($raw | map(select(($c[0][.].runner // null) != null))))}')

machine=$(echo "$out" | jq -r '.machine // "null"')
clusters=$(echo "$out" | jq -c '.clusters')
skipped=$(echo "$out" | jq -r '.skipped | join(",")')
source=$(echo "$out" | jq -r '.source')

echo "runner=\"$label\" repo=\"$repo\" -> machine=$machine via=$source clusters=$clusters" >&2
if [ "$machine" = "null" ] || [ "$clusters" = "[]" ]; then
  [ -n "$skipped" ] && echo "命中的集群尚未接入 runner: $skipped" >&2
  echo "无法从该 runner 名称/标签路由到已接入的集群。已知模式见 model-library/groups.json；" >&2
  echo "也可在请求里显式写 \"clusters\": [\"cn12-001\", ...] 跳过推断。" >&2
  echo '[]'
  exit 2
fi
[ -n "$skipped" ] && echo "WARN: 跳过未接入 runner 的集群: $skipped" >&2
echo "$clusters"
