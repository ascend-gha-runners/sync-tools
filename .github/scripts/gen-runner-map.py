#!/usr/bin/env python3
"""Generate model-library/runner-map.json — purely from ascend-ci-deployment code:

  1. runner chart values.yaml  -> nodeSelector liqo.io/remote-cluster-id=X (硬落点)
     or hostname=X (钉节点)
  2. karmada  manifests/arc-fedsched/prod-cp-*/propagation-policies.yaml clusterNames
     (a2 / a3-800i / a3-800t / a3-n / a5 五组成员)
  3. argocd Application destinations (chart 部署的 host 集群，无 selector 时落本地)
     argocd app 的 helm.releaseName 与 chart 目录名（带 -<host集群> 后缀）是两个 key，
     用 ALIAS 打通：releaseName 形式的 label 优先继承目录名形式的 nodeSelector 硬落点，
     避免 liqo 卸载部署被误记成 host 集群（二维匹配：每 (repo,label) 独立解析，
     全局 map 仅作跨 repo 并集兜底）
  4. cluster_disks 读 model-library/clusters.json 的 node_cache
   5. agent-stack-k8s (Buildkite) charts：queue 名作为路由键（业务请求的
      runner_label 即队列名），落点 = argocd dest + liqo NamespaceOffloading
      providers，不做 karmada 机型推断（Buildkite 池不经 ARC/karmada）
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
      "wlcb-001": "wlcb001", "sz-lab": "szlab", "gluster": None,
      "sh-001": "sh001", "sh-002": "sh002"}
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


# ---- 1: chart selectors + registered runner labels ----
SEL = {}     # (repo, chart 目录名) -> 硬落点 clusters（nodeSelector）
DIRSET = collections.defaultdict(set)           # repo -> {chart 目录名}
LBLDIR = collections.defaultdict(set)           # (repo, scaleSetLabel / Buildkite queue) -> {chart 目录名}
QKEYS = set()                                   # (repo, key)：agent-stack-k8s（Buildkite）chart，
                                                #   落点只走证据链（dest+queue / liqo 卸载），不做 karmada 推断
for f in sorted(glob.glob(f"{ACD}/projects/*/*/linux-*/values.yaml") + glob.glob(f"{ACD}/other/*/*/linux-*/values.yaml")):
    rel = os.path.relpath(f, ACD).split("/")
    repo, lbl = "/".join(rel[1:3]), rel[3]
    DIRSET[repo].add(lbl)
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
    # 二维锚点：chart 实际注册的 runner 标签（runs-on 用的就是它），
    # 而非 releaseName/目录名；同一标签多 chart 时并集
    sset = (v or {}).get("gha-runner-scale-set") or {}
    for lab in sset.get("scaleSetLabels") or []:
        if isinstance(lab, str) and lab.startswith("linux-"):
            LBLDIR[(repo, lab)].add(lbl)
    # agent-stack-k8s（Buildkite）chart：queue 名即业务侧的路由键（相当于 runs-on），
    # 与 chart 目录名互为锚点；这类 chart 没有 scaleSetLabels，落点 = argocd dest
    # 集群 + liqo namespace 卸载 providers，不做 karmada 组成员推断。
    ak = (v or {}).get("agent-stack-k8s") or {}
    queue = (ak.get("config") or {}).get("queue") or ""
    if queue:
        LBLDIR[(repo, queue)].add(lbl)
        QKEYS.add((repo, queue))
        QKEYS.add((repo, lbl))

# ---- 2: fed groups by label pattern ----
def fed_clusters(lbl):
    l = lbl.lower()
    if "800i" in l: g = "a3-800i"
    elif "800t" in l: g = "a3-800t"
    elif re.search(r"-a5\b|-a5-|-a5$", l): g = "a5"
    elif re.search(r"a2b|910b|-a2|-cpu", l): g = "a2"
    elif re.search(r"a3-n|ascend-910c", l): g = "a3-n"
    elif "a3" in l: g = "a3-800i"
    else: return []
    return PLACEMENT.get(g, [])

# ---- 2b: liqo namespace 卸载（consumer ns -> provider 集群），Buildkite 池的
# job pod 经 NamespaceOffloading 溢出到 provider，落点盘要算上 provider ----
OFFLOAD = collections.defaultdict(set)
for f in glob.glob(f"{ACD}/manifests/liqo/consumer-*/**/namespace-offloading.yaml", recursive=True):
    rel = os.path.relpath(f, ACD).split(os.sep)
    if len(rel) < 5 or not rel[2].startswith("consumer-"): continue
    cons = norm(rel[2][len("consumer-"):])
    try: doc = yaml.safe_load(open(f))
    except Exception: continue
    for d in (doc if isinstance(doc, list) else [doc]):
        if not isinstance(d, dict) or d.get("kind") != "NamespaceOffloading": continue
        ns = (d.get("metadata") or {}).get("namespace") or rel[3]
        spec = d.get("spec") or {}
        for t in ((spec.get("clusterSelector") or {}).get("nodeSelectorTerms") or []):
            for m in (t.get("matchExpressions") or []):
                if "remote-cluster-id" in (m.get("key") or ""):
                    for v in (m.get("values") or []):
                        if norm(str(v)): OFFLOAD[(cons, ns)].add(norm(str(v)))

# ---- 3: argocd hosts per (repo,label) ----
HOSTS = collections.defaultdict(set)
APPNS = collections.defaultdict(set)  # (repo, releaseName/目录名) -> {(dest 集群, dest ns)}
ALIAS = {}  # (repo, releaseName) -> chart 目录名（两者不同时才有）
DEST = {"ascend-cn12-001-cluster": "cn12-001", "ascend-hk-001-cluster": "hk001",
        "openmerlin-guiyang-003-cluster": "gy003", "openmerlin-guiyang-004-cluster": "gy004",
        "openmerlin-guiyang-005-cluster": "gy005", "ascend-aiframework": "aiframe",
        "ascend-mind-third-ci": "mind3", "ascend-infra-guiyang-cluster-001": "gy001",
        "ascend-infra-wlcb-cluster-001": "wlcb001",
        "openmerlin-sh-001-cluster": "sh001", "openmerlin-sh-002-cluster": "sh002"}
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
                repo = "/".join(p[1:3])
                ns = (sp.get("destination") or {}).get("namespace") or ""
                HOSTS[(repo, lbl)].add(dst)
                APPNS[(repo, lbl)].add((dst, ns))
                dir_lbl = os.path.basename(path.rstrip("/"))
                if dir_lbl.startswith("linux-"):
                    HOSTS[(repo, dir_lbl)].add(dst)
                    APPNS[(repo, dir_lbl)].add((dst, ns))
                    if dir_lbl != lbl:
                        # 同一部署的 releaseName 与目录名别名，供无 scaleSetLabels 时打通
                        ALIAS.setdefault((repo, lbl), dir_lbl)

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
def landing(r, lbl):
    """二维定位：(repo,label) -> {目录名 / releaseName 别名 / scaleSetLabels 反查}
    锚定的 chart 集合；返回 (liqo 硬落点, 是否 hostname 钉节点, 相关 host 集群)"""
    dirs = set()
    if lbl in DIRSET.get(r, set()): dirs.add(lbl)
    if ALIAS.get((r, lbl)): dirs.add(ALIAS[(r, lbl)])
    dirs |= LBLDIR.get((r, lbl), set())
    sel, pinned = [], False
    for d in sorted(dirs):
        for c in SEL.get((r, d), []):
            if c.startswith("host:"): pinned = True
            else: sel.append(c)
    hosts = set(HOSTS.get((r, lbl), ()))
    for d in dirs: hosts |= HOSTS.get((r, d), set())
    return list(dict.fromkeys(sel)), pinned, hosts

repos = {r for r, _ in HOSTS} | {r for r, _ in SEL} | {r for r, _ in LBLDIR}
map_by_repo, gmap = {}, collections.defaultdict(set)
for repo in sorted(repos):
    labels = {}
    keys = ({l for (r, l) in HOSTS if r == repo}
            | {l for (r, l) in SEL if r == repo}
            | {l for (r, l) in LBLDIR if r == repo})
    for lbl in sorted(keys):
        sel, pinned, hosts = landing(repo, lbl)
        if (repo, lbl) in QKEYS:
            # Buildkite 池（agent-stack-k8s）：queue/目录名 → 落点 = argocd dest
            # ∪ liqo namespace 卸载 providers。Buildkite 不经过 ARC/karmada，
            # 机型名联邦推断一律不适用（教训同 PR#145：多路由=多下一份白占盘）。
            provs = set(hosts)
            dirs = set(LBLDIR.get((repo, lbl), set()))
            if ALIAS.get((repo, lbl)): dirs.add(ALIAS[(repo, lbl)])
            for d in dirs | {lbl}:
                for (c, n) in APPNS.get((repo, d), ()):
                    provs |= OFFLOAD.get((c, n), set())
            cl = sel or sorted(provs)
        elif sel:
            # chart nodeSelector 硬落点（liqo 跨集群卸载）优先级最高；
            # 不再误并入 host∪karmada（教训：vllm-ascend 800t-* 托管 cn12、
            # 实际落点 gy005，旧逻辑给 cn12-001/gy004 各多下一份模型，见 PR#145）
            cl = sel
        elif pinned:
            cl = sorted(hosts)          # hostname 钉节点 -> 落 host 集群
        else:
            base = sorted(hosts)
            grp = "a3-800i" if "800i" in lbl else "a3-800t" if "800t" in lbl \
                  else "a2" if re.search(r"a2b|910b|-a2", lbl) else \
                  "a5" if re.search(r"-a5\b|-a5-|-a5$", lbl) else None
            if "fed" in lbl and grp:
                cl = fed_clusters(lbl) or base
            elif grp and base and grp != "a5":
                # karmada 组成员并入 host（800i: cn12+ aiframe+mind3；a2: hk001+gy001+wlcb001）
                cl = sorted(set(base) | {c for c in fed_clusters(lbl) if c})
            elif grp and not base:
                # 无 host 证据 = chart 部署在 karmada CP（或 fed 别名的裸标签）-> 组落点
                cl = fed_clusters(lbl)
            else:
                cl = base   # a5 分池（sh001/sh002 各挂各的），有 host 时不隐式跨联邦
        if not cl: continue
        labels[lbl] = sorted(set(cl))
        for c in cl: gmap[lbl].add(c)
    if labels: map_by_repo[repo] = labels

out = {"_generated_by": "gen-runner-map.py (chart nodeSelector + karmada placement + argocd dest + agent-stack-k8s buildkite queues + liqo offload)",
       "map": {k: sorted(v) for k, v in sorted(gmap.items())},
       "map_by_repo": map_by_repo,
       "cluster_disks": {c: disk[c] for c in sorted(disk)}}
print(json.dumps(out, ensure_ascii=False, indent=1))
