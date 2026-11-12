#!/usr/bin/env python3
"""Extract only NEW request entries between two versions of the single
requests file (model-requests/requests.json).

Usage: lib-extract-new-requests.py <base.json> <head.json>
base may be an empty array (first PR). Emits one JSON object per line:
  {"repo":..., "runner_label":..., "auth_secret":..., "models":[<new only>], "datasets":[<new only>]}
Identity keys:
  request group = (repo, runner_label, auth_secret)
  model entry   = (platform, organization, model_name, revision)
"""
import json, sys

def key(m):
    return (m.get("platform"), m.get("organization"), m.get("model_name") or m.get("dataset_name"), m.get("revision"))

def load(p):
    try:
        with open(p) as f:
            return json.load(f) or []
    except Exception:
        return []

base, head = load(sys.argv[1]), load(sys.argv[2])

def group(req):
    return (req.get("repo", ""), req.get("runner_label", req.get("clusters") and ",".join(req["clusters"]) or "", req.get("auth_secret", "none")))

old = {}
for r in base:
    g = old.setdefault(group(r), {"models": set(), "datasets": set()})
    for m in r.get("models", []) or []: g["models"].add(key(m))
    for m in r.get("datasets", []) or []: g["datasets"].add(key(m))

for r in head:
    seen = old.get(group(r), {"models": set(), "datasets": set()})
    nm = [m for m in (r.get("models") or []) if key(m) not in seen["models"]]
    nd = [m for m in (r.get("datasets") or []) if key(m) not in seen["datasets"]]
    if not nm and not nd:
        continue
    out = {"repo": r.get("repo", ""), "runner_label": r.get("runner_label", ""), "auth_secret": r.get("auth_secret", "none")}
    if r.get("clusters"): out["clusters"] = r["clusters"]
    if nm: out["models"] = nm
    if nd: out["datasets"] = nd
    print(json.dumps(out, ensure_ascii=False))
