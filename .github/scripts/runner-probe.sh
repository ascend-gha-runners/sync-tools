#!/bin/bash
# Probe the environment of whatever runner executes it and detect which
# registered cluster(s) it belongs to, based on SFS share ids visible in
# /proc/mounts (both ECS host runners and ARC job pods show sfsturbo mounts).
# Writes clusters=[...] to $GITHUB_OUTPUT.
set -uo pipefail
CFG="${1:-model-library/clusters.json}"

shares=$(grep -oE '[0-9a-f]{8}-[0-9a-f-]+\.sfsturbo' /proc/mounts 2>/dev/null | cut -d- -f1 | sort -u | tr '\n' ' ')
host=$(hostname)
ip=$(hostname -I 2>/dev/null | awk '{print $1}')

clusters=$(jq -rcn --arg s "$shares" --slurpfile c "$CFG" '
  ($s | split(" ") | map(select(length>0))) as $ids |
  [ $c[0] | to_entries[]
    | select( any(.value.match.share_ids[]?; . as $sid | ($ids | index($sid)) != null) )
    | .key ] | unique')

echo "probe@${host} (${ip}) shares: ${shares:-none}"
echo "detected clusters: $clusters"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "clusters=$clusters" >> "$GITHUB_OUTPUT"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "#### Runner 环境识别"
    echo
    echo "- 主机: \`$host\` ($ip)"
    echo "- 可见 SFS share: \`${shares:-无}\`"
    echo "- 匹配集群: \`$clusters\`"
    [ "$clusters" = "[]" ] && echo -e "\n未匹配到任何集群：请把 registry 的 share_ids 补齐，或改用 仓库+机型 模式。"
  } >> "$GITHUB_STEP_SUMMARY"
fi
[ "$clusters" != "[]" ] || exit 1
