#!/usr/bin/env python3
"""Generate model-library/runner-map.json — purely from ascend-ci-deployment code:

  1. runner chart values.yaml  -> nodeSelector liqo.io/remote-cluster-id=X (硬落点)
     or hostname=X (钉节点)
  2. karmada  manifests/arc-fedsched/prod-cp-*/propagation-policies.yaml clusterNames
     (a2 / a3-800i / a3-800t / a3-n 四组成员)
  3. argocd Application destinations (chart 部署的 host 集群，无 selector 时落本地)
  4. cluster_disks 读 model-library/clusters.json 的 node_cache
Output runner-map.json:
  map:            label -> [clusters]                (全局并集)
  map_by_repo:    repo -> {label -> [clusters]}
  cluster_disks:  cluster -> {alias, export, write}  (业务可读：盘在哪、谁能写)
"""
import yaml, glob, os, re, json, collections, argparse

ap = argparse.ArgumentParser(); ap.add_argument("--acd", default=".")
a = ap.parse_args(); ACD = a.acd

CN = {"aiframework": "aiframe", "mind-third-ci": "mind3", "openmerlin-guiyang-004": "gy004",
      "openmerlin-guiyang-005": "gy005", "openmerlin-guiyang-001": "gy001", "gy-001": "gy001",
      "gy-004": "gy004", "gy-005": "gy005", "ascend-hk-001": "hk001", "cn12-001": "cn12-001",
      "wlcb-001": "wlcb001", "sz-lab": "szlab", "gluster": None}
def norm(c): return CN.get(c, c)
PLACEMENT = {  # karmada 组 -> 成员（去掉 karc 控制面），来源 prod-cp-*/propagation-policies.yaml
}
for f in glob.glob(f"{ACD}/manifests/arc-fedsched/prod-cp-*/propagation-policies.yaml"):
    grp = os.path.basename(os.path.dirname(f)).replace("prod-cp-", "")
    txt = open(f).read()
    members = set()
    for m in re.finditer(r"clusterNames:\s*\n((?:\s+-\s+\S+\n)+)", txt):
        for line in m.group(1).splitlines():
            c = line.strip("- ").strip()
            if c and c != "karc":
                members.add(c)
    PLACEMENT[grp] = sorted({norm(m) for m in members if norm(m)})


# ---- 1: chart selectors ----
SEL = {}   # (repo,label) -> clusters
for f in sorted(glob.glob(f"{ACD}/projects/*/*/linux-*/values.yaml") + glob.glob(f"{ACD}/other/*/*/linux-*/values.yaml")):
    rel = os.path.relpath(f, ACD).split("/")
    repo, lbl = "/".join(rel[1:3]), rel[3]
    try: v = yaml.safe_load(open(f))
    except Exception: continue
    found = []
    def deep(x):
        if isinstance(x, dict):
            ns = x.get("nodeSelector")
            if isinstance(ns, dict):
                for k, val in ns.items():
                    if "remote-cluster-id" in k: found.append(norm(str(val)))
                    elif "hostname" in k: found.append(f"host:{val}")
            for y in x.values(): deep(y)
        elif isinstance(x, list):
            for y in x: deep(y)
    deep(v)
    if found:
        SEL[(repo, lbl)] = [x for x in dict.fromkeys(found) if x]

# ---- 2: fed groups by label pattern ----
def fed_clusters(lbl):
    l = lbl.lower()
    if "800i" in l: g = "a3-800i"
    elif "800t" in l: g = "a3-800t"
    elif re.search(r"a2b|910b|-a2|-cpu", l): g = "a2"
    elif re.search(r"a3-n|ascend-910c", l): g = "a3-n"
    elif "a3" in l: g = "a3-800i"
    else: return []
    return PLACEMENT.get(g, [])

# ---- 3: argocd hosts per (repo,label) ----
HOSTS = collections.defaultdict(set)
DEST = {"ascend-cn12-001-cluster": "cn12-001", "ascend-hk-001-cluster": "hk001",
        "openmerlin-guiyang-003-cluster": "gy003", "openmerlin-guiyang-004-cluster": "gy004",
        "openmerlin-guiyang-005-cluster": "gy005", "ascend-aiframework": "aiframe",
        "ascend-mind-third-ci": "mind3", "ascend-infra-guiyang-cluster-001": "gy001",
        "ascend-infra-wlcb-cluster-001": "wlcb001"}
for app in glob.glob(f"{ACD}/argocd/clusters/*/*.yaml"):
    for d in (yaml.safe_load_all(open(app)) or []):
        if not isinstance(d, dict) or d.get("kind") != "Application": continue
        sp = d.get("spec", {})
        dst = norm(DEST.get((sp.get("destination") or {}).get("name", ""), ""))
        if not dst: continue
        srcs = ([sp.get("source")] if sp.get("source") else []) + (sp.get("sources") or [])
        for src in srcs:
            path = (src or {}).get("path") or ""
            p = path.split("/")
            if len(p) < 4 or p[0] not in ("projects", "other"): continue  # path 本身是相对路径
            lbl = (src.get("helm") or {}).get("releaseName") or os.path.basename(path)
            if lbl.startswith("linux-"):
                HOSTS[("/".join(p[1:3]), lbl)].add(dst)

# ---- 4: cluster disk table ----
CLUSTER_FIX = {"ascend-cn12-001-cluster": "cn12-001", "openmerlin-guiyang-003-cluster": "gy003",
               "openmerlin-guiyang-004-cluster": "gy004", "openmerlin-guiyang-005-cluster": "gy005",
               "ascend-mind-third-ci": "mind3", "aiframework": "aiframe",
               "ascend-infra-wlcb-cluster-001": "wlcb001", "ascend-hk-001-cluster": "hk001",
               "ascend-infra-guiyang-cluster-001": "gy001"}
# disk table lives in model-library/clusters.json -> node_cache (single source)
disk = {c: v["node_cache"] for c, v in json.load(open(os.path.join(
    os.path.dirname(__file__), "..", "..", "model-library", "clusters.json"))).items()
    if v.get("node_cache")}

# ---- assemble ----
repos = {r for r, _ in HOSTS} | {r for r, _ in SEL}
map_by_repo, gmap = {}, collections.defaultdict(set)
for repo in sorted(repos):
    labels = {}
    for (r, lbl) in list(HOSTS) + list(SEL):
        if r != repo: continue
        if SEL.get((r, lbl)):
            cl = [c for c in SEL[(r, lbl)] if not c.startswith("host:")]
            if not cl:
                cl = sorted(HOSTS.get((r, lbl), []))
        else:
            base = sorted(HOSTS.get((r, lbl), []))
            grp = "a3-800i" if "800i" in lbl else "a3-800t" if "800t" in lbl \
                  else "a2" if re.search(r"a2b|910b|-a2", lbl) else None
            if "fed" in lbl and grp:
                cl = fed_clusters(lbl) or base
            elif grp and base:
                # karmada 组成员并入 host（800i: cn12+ aiframe+mind3；a2: hk001+gy001+wlcb001）
                cl = sorted(set(base) | {c for c in fed_clusters(lbl) if c})
            else:
                cl = base
        if not cl: continue
        labels[lbl] = sorted(set(cl))
        for c in cl: gmap[lbl].add(c)
    if labels: map_by_repo[repo] = labels

out = {"_generated_by": "gen-runner-map.py (chart nodeSelector + karmada placement + argocd dest)",
       "map": {k: sorted(v) for k, v in sorted(gmap.items())},
       "map_by_repo": map_by_repo,
       "cluster_disks": {c: disk[c] for c in sorted(disk)}}
print(json.dumps(out, ensure_ascii=False, indent=1))
