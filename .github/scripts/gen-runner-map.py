#!/usr/bin/env python3
"""Generate model-library/runner-map.json from ascend-ci-deployment ground truth.

Sources scanned (repo = ascend-ci-deployment checkout):
  argocd/clusters/*/ + Application spec.destination.name / source.path ->
  runner charts (linux-* releaseName/path basename) give the authoritative
  (host-cluster, repo, runner-label) triples.

Mapping policy (confirmed by owners):
  *800i*   -> disk clusters: cn12-001 + mind3 + aiframe (800i hardware pool)
  *800t*   -> gy004 + gy005                              (800t hardware pool)
  a3/other -> from label suffix: -gy004 -> gy004, -cn12-001 -> cn12-001,
              -aiframe -> aiframe, -gy005 -> gy005, hk/a2 -> hk001, 310p -> gy003;
              no cluster suffix -> host cluster of the Application.
Outputs exact "label -> [clusters]" map + rule fallback file.
"""
import yaml, glob, os, re, json, sys

ROOT = os.environ.get("ACD_ROOT", ".")
DEST2CLUSTER = {
    "ascend-cn12-001-cluster": "cn12-001",
    "ascend-hk-001-cluster": "hk001",
    "openmerlin-guiyang-004-cluster": "gy004",
    "openmerlin-guiyang-005-cluster": "gy005",
    "openmerlin-guiyang-003-cluster": "gy003",
    "ascend-aiframework": "aiframe",
    "ascend-mind-third-ci": "mind3",
}
SUFFIX = {  # label token -> disk cluster (a3 等无 800 标记时)
    "cn12": "cn12-001", "gy004": "gy004", "gy005": "gy005",
    "gy003": "gy003", "aiframe": "aiframe", "hk": "hk001",
}

# 物理实证（runner pod 的 /root/.cache hostPath 在各 provider 节点的实际 export）：
#   vllm-ascend 800i fed  -> cn12(37cbefa6:/ascend-ci-share) + mind3(cc8060b8:/) + aiframe(c461cb6e:/)
#   vllm-ascend 800t      -> pod 实测跑在 gy005 节点(b46afb97 benchmark 盘)；namespace 在 cn12
#   sglang 系 800i/800t   -> gy004(1b51fb58 pkking 盘) + gy005
REPO_RULES = {
    "vllm-project/vllm-ascend": {"800i": ["cn12-001", "mind3", "aiframe"], "800t": ["cn12-001", "gy005"]},
    "sgl-project/sglang":       {"800i": ["cn12-001", "mind3", "aiframe", "gy004"], "800t": ["gy004", "gy005"]},
    "Ascend/sglang":            {"800i": ["cn12-001", "mind3", "aiframe", "gy004"], "800t": ["gy004", "gy005"]},
    "sgl-project/sgl-kernel-npu": {"800i": ["gy004"], "800t": ["gy004", "gy005"]},
}

# repo -> cluster set, authoritative source: disk-map.json (built from full
# ci-deployment survey: argocd apps + liqo providers + node alias mounts)
_DISK = {}
try:
    _DM = os.path.join(os.path.dirname(__file__), "..", "..", "model-library", "disk-map.json")
    _DISK = json.load(open(_DM))
except Exception:
    pass

def map_label(label, host_cluster, repo=""):
    l = label.lower()
    # per-repo physical clusters win
    if repo in _DISK:
        lc = _DISK[repo].get("label_clusters", {})
        key = re.sub(r"-[0-9]+$", "", label) if label.endswith(tuple("0123456789")) else label
        for cand in (label, key, os.path.basename(label)):
            if cand in lc:
                return [c for c in lc[cand] if c not in ("sh001", "sh002")] or list(lc[cand])
        cl = _DISK[repo]["clusters"]
        return [c for c in cl if c not in ("sh001", "sh002")] or cl
    rr = REPO_RULES.get(repo, {})
    if "800i" in l and "800i" in rr:
        return rr["800i"]
    if "800t" in l and "800t" in rr:
        return rr["800t"]
    if "800i" in l:
        return ["cn12-001", "mind3", "aiframe"]
    if "800t" in l:
        return ["gy004", "gy005"]
    for tok, c in SUFFIX.items():
        if re.search(rf"(^|-){tok}", l):
            return [c]
    if "310p" in l:
        return ["gy003"]
    if re.search(r"(-|^)a2(b\d)?(-|$)", l):
        return ["hk001"]
    if "hk" in l:
        return ["hk001"]
    return [host_cluster] if host_cluster else []

out = {}          # label -> set(clusters)
out_repo = {}     # repo -> {label -> set(clusters)}
for app in sorted(glob.glob(f"{ROOT}/argocd/clusters/*/*.yaml")):
    try:
        docs = list(yaml.safe_load_all(open(app)))
    except Exception:
        continue
    for d in docs:
        if not isinstance(d, dict) or d.get("kind") != "Application":
            continue
        spec = d.get("spec", {})
        host = DEST2CLUSTER.get((spec.get("destination") or {}).get("name") or "")
        srcs = ([spec.get("source")] if spec.get("source") else []) + (spec.get("sources") or [])
        for src in srcs:
            path = (src or {}).get("path") or ""
            label = ((src or {}).get("helm") or {}).get("releaseName") or os.path.basename(path)
            if not label.startswith("linux-") or "/linux-" not in "/" + path:
                continue
            # normalize repo for non-projects paths (other/ascend-gha-runners/<x>)
            parts = path.split("/")
            repo = "/".join(parts[1:3]) if parts[0] in ("projects", "other") and len(parts) > 3 else "?"
            clusters = map_label(label, host, repo)
            # (repo 变量在 map_label 调用前已解析，见下)
            if not clusters:
                continue
            out.setdefault(label, set()).update(clusters)
            out_repo.setdefault(repo, {}).setdefault(label, set()).update(clusters)

merged = {k: sorted(v) for k, v in sorted(out.items())}
merged_repo = {r: {k: sorted(v) for k, v in sorted(ls.items())} for r, ls in sorted(out_repo.items())}
print(json.dumps({"_generated": "from ascend-ci-deployment argocd apps (gen-runner-map.py)",
                  "count": len(merged), "map": merged, "map_by_repo": merged_repo}, ensure_ascii=False, indent=1))
