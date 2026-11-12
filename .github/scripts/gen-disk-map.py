#!/usr/bin/env python3
"""Build model-library/disk-map.json from the ascend-ci-deployment survey.

Inputs (snapshotted under --data):
  survey_apps.tsv   repo \t label \t host-cluster   (argocd Applications)
  survey_repo_cache.tsv  repo \t alias1,alias2,...  (/root/.cache hostPath aliases & PVCs)
  *.mounts          per-cluster "alias => export:path" node mount tables
Providers: parsed from manifests/liqo dir names (passed via --providers file:
  provider \t repo-ns)
Cluster naming normalized to sync registry: cn12-001,hk001,mind3,aiframe,gy001..gy006,wlcb001.
Output JSON: repo -> {hosts, providers, clusters, disk_targets: {cluster: {alias, export, machine_writable_hint}}}
"""
import json, sys, re, glob, os, collections, argparse

ap = argparse.ArgumentParser()
ap.add_argument("--data", required=True)
ap.add_argument("--providers", required=True)
ap.add_argument("--out", required=True)
a = ap.parse_args()
D = a.data

CLUSTER_FIX = {
    "ascend-cn12-001-cluster": "cn12-001", "openmerlin-guiyang-003-cluster": "gy003",
    "openmerlin-guiyang-004-cluster": "gy004", "openmerlin-guiyang-005-cluster": "gy005",
    "openmerlin-guiyang-006-cluster": "gy006", "ascend-hk-001-cluster": "hk001", "hk-001": "hk001",
    "ascend-aiframework": "aiframe", "aiframework": "aiframe", "cn12-001": "cn12-001", "wlcb001": "wlcb001",
    "ascend-mind-third-ci": "mind3", "ascend-infra-guiyang-cluster-001": "gy001", "sz-lab": "szlab",
    "ascend-infra-wlcb-cluster-001": "wlcb001", "KARMADA": None, "?": None,
    "in-cluster": None, "hidevlab": None, "openmerlin-sh-001-cluster": "sh001",
    "sh-002": "sh002", "volcengine": None, "ci-test-01": None,
    "infra-hk-opensourceway-ci-cluster": "hk-oss-ci",
}

def NORM(c):
    return {"aiframework":"aiframe","mind-third-ci":"mind3","szlab":"szlab"}.get(CLUSTER_FIX.get(c,c), CLUSTER_FIX.get(c,c))

ALIAS2EXPORT = {}  # cluster -> {alias: export}
for f in glob.glob(f"{D}/*.mounts"):
    cl = CLUSTER_FIX.get(os.path.basename(f)[:-7], os.path.basename(f)[:-7])
    tab = {}
    for line in open(f):
        m = re.match(r"(\S+)\s+=>\s+(\S+)", line)
        if m and cl:
            tab[m.group(1)] = m.group(2)
    ALIAS2EXPORT.setdefault(cl, {}).update(tab)

hosts = collections.defaultdict(set)
for line in open(f"{D}/survey_apps.tsv"):
    repo, lbl, host = line.rstrip("\n").split("\t")
    c = CLUSTER_FIX.get(host, host)
    if c and lbl.startswith("linux-"):
        hosts[repo].add(NORM(c))

cache_alias = {}
for line in open(f"{D}/survey_repo_cache.tsv"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 2:
        continue
    cache_alias[parts[0]] = [x for x in parts[1].split(",") if x]

providers = collections.defaultdict(set)
for line in open(a.providers):
    prov, ns = line.rstrip("\n").split("\t")
    providers[NORM(prov) if False else prov].add(ns)

# repo -> providers: match provider ns dir name to repo (fuzzy: repo tokens)
def providers_for(repo):
    want = repo.replace("/", "-").lower()
    out = set()
    for prov, nss in providers.items():
        for ns in nss:
            n = ns.lower().replace("-liqo", "")
            if n == want or n == want.replace("-cn12-001", "") or want in (n, n + "-cn12-001"):
                out.add(NORM(prov))
                break
    return out


# ---- label-level landing: host cluster + its liqo providers (per ns) ----
EXPORT2MACHINE = {  # export prefix -> (machine, base mount)
    "37cbefa6": ("cn12-ecs 113.46.27.144", "/mnt/sfs_turbo"),
    "cc8060b8": ("mind3-ecs 113.46.31.157", "/mnt/sfs_turbo"),
    "c461cb6e": ("hb3-ecs 113.46.1.251", "/opt/vllm-ci"),
    "24dd126e": ("hk-ecs 159.138.152.35", "/opt/vllm-ci"),
    "b46afb97": ("guiyang-ecs 101.245.82.28", "/mnt/sfs_turbo"),
    "1b51fb58": ("guiyang-ecs 101.245.82.28", "/mnt/sfs_turbo2"),
    "a8317f79": ("(no machine mount)", ""),
    "fef36441": ("(no machine mount; in-cluster pod needed)", ""),
    "9c241417": ("(no machine mount)", ""),
    "d5b643e2": ("(no machine mount)", ""),
}
OFF = {}  # (consumer, ns) -> [providers]
if os.path.exists(f"{D}/offloading.tsv"):
    for line in open(f"{D}/offloading.tsv"):
        c, ns, provs = line.rstrip("\n").split("\t")
        OFF[(NORM(c), ns)] = [NORM(p) for p in provs.split(",") if p]

# label hosts: repo -> label -> hosts (already in survey_apps)
label_hosts = collections.defaultdict(lambda: collections.defaultdict(set))
for line in open(f"{D}/survey_apps.tsv"):
    repo, lbl, host = line.rstrip("\n").split("\t")
    c = NORM(host)
    if c and lbl.startswith("linux-"):
        label_hosts[repo][lbl].add(c)

def ns_of(repo):
    # liqo ns naming from provider/consumer dirs: try variants
    base = repo.replace("/", "-").lower()
    variants = {base, repo.replace("/", "-"), "vllm-project-vllm-ascend" if repo=="vllm-project/vllm-ascend" else base}
    return variants

label_clusters = {}
for repo, lbls in label_hosts.items():
    for lbl, hs in lbls.items():
        cl = set(hs)
        for h in hs:
            for ns in ns_of(repo):
                cl.update(OFF.get((h, ns), []))
        label_clusters[f"{repo}::{lbl}"] = sorted(cl)

MAP = {}
for repo in sorted(hosts):
    cls = set(hosts[repo]) | providers_for(repo)
    alias_ct = collections.Counter(cache_alias.get(repo, []))
    aliases = [x for x, _ in alias_ct.most_common() if not x.startswith(("/usr", "/data", "/share", "/boot"))]
    targets = {}
    for c in sorted(cls):
        tab = ALIAS2EXPORT.get(c, {})
        hit = None
        for al in aliases:  # 1) exact (incl pvc:)
            if al in tab:
                hit = {"alias": al, "export": tab[al]}; break
        if not hit:
            for al in aliases:  # 2) bare<->pvc exact
                alt = al[4:] if al.startswith("pvc:") else "pvc:" + al
                if alt in tab:
                    hit = {"alias": alt, "export": tab[alt]}; break
        if not hit:
            for al in aliases:  # 3) substring
                al2 = al.replace("pvc:", "")
                if len(al2) < 8: continue
                for k, v in tab.items():
                    kk = k.replace("pvc:", "")
                    if al2 in kk or kk in al2:
                        hit = {"alias": k, "export": v}; break
                if hit: break
        if not hit:  # 4) repo-token scan: alias/PVC mentioning repo words
            toks = [t for t in re.split(r"[-/]", repo.lower()) if len(t) > 3]
            scored = sorted(((sum(t in k.lower() for t in toks), k, v) for k, v in tab.items()), reverse=True)
            for sc, k, v in scored[:1]:
                if sc:
                    hit = {"alias": k, "export": v}
        targets[c] = hit or {"alias": None, "export": "UNRESOLVED"}
    labelmap = {k.split("::",1)[1]: v for k, v in label_clusters.items() if k.startswith(repo + "::")}
    MAP[repo] = {"clusters": sorted(cls), "cache_aliases": sorted(aliases)[:6], "disk_targets": targets,
                 "label_clusters": labelmap,
                 "write_paths": {c: [t["export"], *(EXPORT2MACHINE.get((t["export"] or "").split(":")[0], ["?",""]) if t["export"] and "UNRESOLVED" not in t["export"] else ["?",""])] for c, t in targets.items()}}

json.dump(MAP, open(a.out, "w"), ensure_ascii=False, indent=1)
print(f"wrote {a.out}: {len(MAP)} repos")
