#!/bin/bash
# 落位断言：缓存根必须物理落在 node_cache.export 声明的盘/目录上（写端==读端）。
# 背景：#132 的 hk001 job 全绿但数据落 nv-sync-tools（同 share 的兄弟 export），
# 业务读 nvbench 为空——caches(写端)与 node_cache(读端)分裂时旧 audit 查自己必然绿。
# Env: MODELSCOPE_CACHE, HF_HOME, NODE_CACHE_EXPORT("<share-id>:<export-dir>" | 其他)
# 仅对 share-id 形式断言；sh001 hostPath / sh002 静态 PV / TODO 占位 → 跳过。
set -uo pipefail
exp="${NODE_CACHE_EXPORT:-}"
if [ -z "$exp" ] || [[ "$exp" != *:* ]]; then
  echo "assert-landing-mount: no '<share-id>:<dir>' export contract for this cluster, skip"; exit 0
fi
sid="${exp%%:*}"; dir="${exp#*:}"
# share-id 需形如 uuid/短 hex（含 '-' 或全 hex）；否则视为非 SFS 描述文本，跳过
case "$sid" in
  *[!0-9a-fA-F-]*|"") echo "assert-landing-mount: export sid '$sid' not share-id form, skip"; exit 0;;
esac

fail=0
for v in "${MODELSCOPE_CACHE:-}" "${HF_HOME:-}"; do
  [ -n "$v" ] || continue
  [ -d "$v" ] || { echo "assert-landing-mount: cache root $v not a directory yet"; continue; }
  src=$(df -P "$v" 2>/dev/null | awk 'NR==2{print $1}')
  echo "cache root: $v  <- $src"
  same_share=0
  case "$src" in *"$sid"*) same_share=1;; esac
  under_export=0
  # 整 share 挂载（host）：靠目录路径段命中；export 直挂（arc）：靠 mount source 命中
  case "$src" in *"$dir"*) under_export=1;; esac
  case "$v" in *"$dir"/*) under_export=1;; esac
  if [ "$same_share" = 1 ] && [ "$under_export" = 1 ]; then
    echo "  ✓ on $exp"
  else
    echo "  ✗ MISMATCH: expected $exp (same_share=$same_share under_export=$under_export)"
    fail=1
  fi
done
if [ "$fail" != 0 ]; then
  echo "::error::落位断言失败：写端 caches 与业务读端 node_cache.export ('$exp') 不同盘/目录——下载即使全绿业务也读不到（见上方 cache root 行）"
  exit 1
fi
echo "assert-landing-mount: all cache roots match $exp"
