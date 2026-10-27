#!/usr/bin/env python3
"""Read-only investigation helper for sync-images.

Given one tag and src/dest, it answers:
  - when was the destination tag last written (Quay last_modified),
  - which sync run wrote it,
  - whether that sync was caused by an upstream rebuild or by a failed
    digest comparison (e.g. registry 503s), using config digest fingerprints
    from surrounding job logs,
  - what the current source build time and source/destination digests are.

It never runs skopeo copy and never triggers a sync workflow.
"""
import datetime as dt
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from email.utils import parsedate_to_datetime

REPO = os.environ["REPO"]
TAG = os.environ.get("TAG", "").strip()
SRC = os.environ["SRC"].rstrip("/")
DEST = os.environ["DEST"].rstrip("/")
LOOKBACK_DAYS = int(os.environ.get("LOOKBACK_DAYS", "14"))
MAX_RUNS = int(os.environ.get("MAX_RUNS", "80"))

if not TAG:
    raise SystemExit("TAG is required")

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T[\d:.]+Z\s+")

def log(*args):
    print(*args, flush=True)

def parse_iso(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))

def parse_http_date(s):
    d = parsedate_to_datetime(s)
    if d.tzinfo is None:
        d = d.replace(tzinfo=dt.timezone.utc)
    return d

# ---------- GitHub API ----------

def gh_json(path):
    p = subprocess.run(["gh", "api", path], text=True, capture_output=True)
    if p.returncode != 0:
        raise RuntimeError(f"gh api {path} failed: {p.stderr.strip()}")
    return json.loads(p.stdout)

def gh_text(path):
    p = subprocess.run(["gh", "api", path], text=True, capture_output=True)
    if p.returncode != 0:
        raise RuntimeError(f"gh api {path} failed: {p.stderr.strip()}")
    return p.stdout

# ---------- credential mapping (same domains as sync-images.yml) ----------

def get_creds(image):
    host = image.split("/", 1)[0]

    def pair(u, p):
        u = os.environ.get(u, "")
        p = os.environ.get(p, "")
        return f"{u}:{p}" if u and p else None

    if host.startswith("quay.io"):
        if image.startswith("quay.io/atlas_inference/"):
            return pair("QUAY_ATLAS_INFERENCE_USER", "QUAY_ATLAS_INFERENCE_PWD")
        return pair("QUAY_ASCEND_USER", "QUAY_ASCEND_PWD")
    if host.startswith("docker.io"):
        return pair("DOCKERHUB_USER", "DOCKERHUB_PWD")
    if host.startswith("swr.cn-southwest-2."):
        return pair("HWCLOUD_USER", "HWCLOUD_PWD")
    if host.startswith("swr.cn-east-3."):
        return pair("SWR_EAST3_USER", "SWR_EAST3_SECRET")
    if host.startswith("swr.ap-southeast-1."):
        return pair("SWR_HK_USER", "SWR_HK_SECRET")
    if host.startswith("swr.cn-north-12."):
        return pair("SWR_NORTH12_USER", "SWR_NORTH12_SECRET")
    if host.startswith("swr.cn-north-4."):
        return pair("SWR_NORTH4_USER", "SWR_NORTH4_SECRET")
    return None

# ---------- registry reads (read-only) ----------

def skopeo_raw(image):
    creds = get_creds(image)
    args = ["skopeo", "inspect", "--raw"]
    if creds:
        args += ["--creds", creds]
    args += [f"docker://{image}"]
    p = subprocess.run(args, text=True, capture_output=True, timeout=180)
    if p.returncode != 0:
        return None, p.stderr.strip().splitlines()[-1] if p.stderr.strip() else "inspect failed"
    try:
        return json.loads(p.stdout), None
    except json.JSONDecodeError as e:
        return None, f"bad json: {e}"

def manifest_id(raw):
    if not raw:
        return ""
    if raw.get("manifests"):
        return ",".join(sorted(m.get("digest", "") for m in raw["manifests"]))
    return raw.get("config", {}).get("digest", "")

def skopeo_digest(image):
    creds = get_creds(image)
    args = ["skopeo", "inspect", "--format", "{{.Digest}}"]
    if creds:
        args += ["--creds", creds]
    args += [f"docker://{image}"]
    p = subprocess.run(args, text=True, capture_output=True, timeout=180)
    if p.returncode != 0:
        return None, p.stderr.strip().splitlines()[-1] if p.stderr.strip() else "inspect failed"
    return p.stdout.strip() or None, None

def image_created(image, raw):
    """Return the image config 'created' (build time) for one child of the tag."""
    creds = get_creds(image)
    target = image
    if raw and raw.get("manifests"):
        children = sorted(m.get("digest", "") for m in raw["manifests"] if m.get("digest"))
        if not children:
            return None, "manifest list without child digests"
        target = image.rsplit(":", 1)[0] + "@" + children[0]
    args = ["skopeo", "inspect", "--format", "{{.Created}}"]
    if creds:
        args += ["--creds", creds]
    args += [f"docker://{target}"]
    p = subprocess.run(args, text=True, capture_output=True, timeout=180)
    if p.returncode != 0:
        return None, p.stderr.strip().splitlines()[-1] if p.stderr.strip() else "inspect failed"
    value = p.stdout.strip()
    return (value or None), None

def quay_tag_meta(image, tag):
    if not image.startswith("quay.io/"):
        return None
    repo = image.split("/", 1)[1]
    url = (
        "https://quay.io/api/v1/repository/"
        + repo
        + "/tag/?specificTag="
        + urllib.parse.quote(tag, safe="")
    )
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    token = os.environ.get("QUAY_API_TOKEN", "")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.load(resp)
        tags = data.get("tags") or []
        if not tags:
            return None
        t = tags[0]
        return {
            "last_modified": t.get("last_modified"),
            "manifest_digest": t.get("manifest_digest"),
        }
    except Exception as e:
        return {"error": str(e)}

# ---------- historical job logs ----------

def parse_job_log(text):
    """Parse one sync job log -> {tag: {status, configs, event_at}}."""
    out = {}
    current = None
    for raw in text.splitlines():
        ts = None
        m = re.match(r"^(\d{4}-\d{2}-\d{2}T[\d:.]+Z)\s+", raw)
        if m:
            ts = m.group(1)
        line = TS_RE.sub("", ANSI_RE.sub("", raw), count=1)

        m = re.match(r'^from="docker://([^"]+)" to="docker://([^"]+)"', line)
        if m:
            left = m.group(1)
            tag = left.rsplit(":", 1)[-1]
            current = tag
            out.setdefault(tag, {"status": None, "configs": set(), "event_at": None})
            continue

        if current is None:
            continue

        m = re.match(r"^Syncing (\S+)\.\.\.$", line)
        if m:
            current = m.group(1)
            out.setdefault(current, {"status": None, "configs": set(), "event_at": None})
            continue

        m = re.match(r"^⏭️\s+Skip\s+(\S+?)(?:\s+\(cache\))?$", line)
        if m:
            tag = m.group(1)
            e = out.setdefault(tag, {"status": None, "configs": set(), "event_at": None})
            e["status"] = "skipped"
            e["event_at"] = e["event_at"] or ts
            current = tag
            continue

        m = re.match(r"^✅ Synced (\S+)$", line)
        if m:
            tag = m.group(1)
            e = out.setdefault(tag, {"status": None, "configs": set(), "event_at": None})
            e["status"] = "synced"
            e["event_at"] = ts or e["event_at"]
            current = tag
            continue

        m = re.match(r"^❌ Failed (\S+) \(exit (\d+)\)$", line)
        if m:
            tag = m.group(1)
            e = out.setdefault(tag, {"status": None, "configs": set(), "event_at": None})
            e["status"] = "failed"
            e["event_at"] = ts or e["event_at"]
            current = tag
            continue

        m = re.search(r"Copying config sha256:([0-9a-f]{64})", line)
        if m:
            out[current]["configs"].add("sha256:" + m.group(1))
    return out

def find_job(run_id):
    data = gh_json(f"repos/{REPO}/actions/runs/{run_id}/jobs?per_page=100")
    for job in data.get("jobs", []):
        if job.get("name") == f"Sync {SRC}":
            return job
    return None

def job_entries(run):
    job = find_job(run["id"])
    if not job:
        return None
    text = gh_text(f"repos/{REPO}/actions/jobs/{job['id']}/logs")
    return {
        "run_id": run["id"],
        "run_created": run["created_at"],
        "run_conclusion": run.get("conclusion"),
        "job_id": job["id"],
        "job_started": job.get("started_at") or run["created_at"],
        "job_completed": job.get("completed_at") or run["created_at"],
        "entries": parse_job_log(text),
    }

# ---------- anchor: when was this tag last written to dest? ----------

qmeta = quay_tag_meta(DEST, TAG)
anchor_time = None
anchor_source = "now"
if isinstance(qmeta, dict) and qmeta.get("last_modified"):
    try:
        anchor_time = parse_http_date(qmeta["last_modified"])
        anchor_source = "quay_last_modified"
    except Exception:
        anchor_time = None
if anchor_time is None:
    anchor_time = dt.datetime.now(dt.timezone.utc)
    log("No usable Quay last_modified; anchoring at now")

now = dt.datetime.now(dt.timezone.utc)
start = anchor_time - dt.timedelta(days=LOOKBACK_DAYS)
end = min(anchor_time + dt.timedelta(days=1), now + dt.timedelta(hours=1))
log(f"Tag: {TAG}")
log(f"Anchor: {anchor_time.isoformat()} ({anchor_source})")
log(f"Search runs created in [{start.isoformat()}, {end.isoformat()}]")

# ---------- collect runs around the anchor ----------

runs = []
page = 1
while True:
    path = (
        f"repos/{REPO}/actions/workflows/sync-images.yml/runs"
        f"?per_page=100&page={page}"
        f"&created={start.strftime('%Y-%m-%dT%H:%M:%SZ')}..{end.strftime('%Y-%m-%dT%H:%M:%SZ')}"
    )
    data = gh_json(path)
    batch = data.get("workflow_runs", [])
    runs.extend(batch)
    if len(batch) < 100:
        break
    page += 1

runs.sort(key=lambda r: abs((parse_iso(r["created_at"]) - anchor_time).total_seconds()))
runs = runs[:MAX_RUNS]
runs.sort(key=lambda r: r["created_at"])

log(f"Fetching logs for {len(runs)} runs ...")
history = []
for i, run in enumerate(runs, 1):
    try:
        item = job_entries(run)
    except Exception as e:
        log(f"  [{i}/{len(runs)}] run {run['id']}: {e}")
        continue
    if not item:
        continue
    history.append(item)
    log(f"  [{i}/{len(runs)}] run {run['id']} {run['created_at']} "
        f"(tag: {item['entries'].get(TAG, {}).get('status', 'absent')})")
history.sort(key=lambda h: h["job_started"])

# ---------- timeline for this tag ----------

events = []
for h in history:
    if TAG not in h["entries"]:
        continue
    events.append(h["entries"][TAG] | {
        "run_id": h["run_id"],
        "run_created": h["run_created"],
        "job_started": h["job_started"],
        "job_completed": h["job_completed"],
    })

def event_time(e):
    return parse_iso(e.get("event_at") or e.get("job_started") or e["run_created"])

synced_events = [e for e in events if e.get("status") == "synced"]

# Quay 目标：优先匹配 last_modified 附近（±30 分钟）的那次 Synced。
# 非 Quay 目标：没有 last_modified，退化为“窗口内最近一次 Synced”。
tgt = None
if anchor_source == "quay_last_modified":
    near = [
        e for e in synced_events
        if abs((event_time(e) - anchor_time).total_seconds()) <= 30 * 60
    ]
    if near:
        tgt = max(near, key=event_time)
elif synced_events:
    tgt = max(synced_events, key=event_time)

target_anchor = event_time(tgt) if tgt else anchor_time
target_run_id = tgt["run_id"] if tgt else None

log(f"Events in window: {len(events)} (synced={len(synced_events)})")
if tgt:
    log(f"Target sync: run {tgt['run_id']} @ {tgt.get('event_at') or tgt['job_started']}")
elif anchor_source == "quay_last_modified":
    log("NOTE: 没有找到与 Quay last_modified 对应的 Synced 日志"
        "（日志可能已过期，或这次写入不是本 workflow 做的）")

def event_before(e):
    return event_time(e) < target_anchor

all_before = [
    e for e in events
    if e["run_id"] != target_run_id and event_before(e)
]
all_after = [
    e for e in events
    if e["run_id"] != target_run_id and event_time(e) > target_anchor
]
before = [e for e in all_before if e.get("status") == "synced"]
after = [e for e in all_after if e.get("status") == "synced"]
prev = before[-1] if before else None
nxt = after[0] if after else None
prev_any = all_before[-1] if all_before else None
next_any = after[0] if after else None

# ---------- current registry state ----------

src_ref = f"{SRC}:{TAG}"
dest_ref = f"{DEST}:{TAG}"
src_raw, src_err = skopeo_raw(src_ref)
dest_raw, dest_err = skopeo_raw(dest_ref)
src_mid_now = manifest_id(src_raw)
dest_mid_now = manifest_id(dest_raw)
src_top, src_top_err = skopeo_digest(src_ref)
dest_top, dest_top_err = skopeo_digest(dest_ref)
src_created, created_err = (None, None)
if src_raw:
    src_created, created_err = image_created(src_ref, src_raw)

now_equal = bool(src_mid_now and dest_mid_now and src_mid_now == dest_mid_now)

def short(digests):
    ds = sorted(digests)
    return ", ".join(d[:19] for d in ds) if ds else "-"

target_fp = sorted(tgt["configs"]) if tgt else []
prev_fp = sorted(prev["configs"]) if prev else []
next_fp = sorted(nxt["configs"]) if nxt else []

created_dt = None
if src_created:
    try:
        created_dt = parse_iso(src_created)
    except Exception:
        created_dt = None

def time_of(entry):
    return event_time(entry) if entry else None

def time_end(entry):
    return parse_iso(entry.get("job_completed") or entry["run_created"]) if entry else None

# ---------- verdict ----------

verdict = ""
if tgt is None:
    if anchor_source == "quay_last_modified":
        verdict = "没有找到与目标 tag 最后一次写入对应的 Synced 日志；只能按当前状态判断"
    else:
        verdict = "窗口内没有找到该 tag 的 Synced 日志；只能按当前状态判断"
    if created_dt:
        if created_dt > anchor_time:
            verdict += "；源 Created 晚于目标最后写入 → 源之后重建过"
        else:
            verdict += "；源 Created 不晚于目标最后写入"
    verdict += "；当前源/目标 digest 一致" if now_equal else "；当前源/目标 digest 不一致"
else:
    if prev and prev_fp and target_fp:
        if prev_fp == target_fp:
            verdict = "源未变：与上次 Synced 的 config digest 完全相同 → 这次是重复写（inspect 失败/抖动）"
        else:
            verdict = "源已重新构建：config digest 与上次 Synced 不同"
    elif prev_any and prev_any.get("status") == "skipped" and created_dt:
        p = time_of(prev_any)
        p_end = time_end(prev_any)
        if created_dt <= p:
            verdict = "源内容未变：上次运行 Skip（当时源==目标），且源 Created 早于上次运行 → 这次很可能是 inspect 失败导致的重复写"
        elif created_dt <= p_end:
            verdict = "无法确定：源在上次运行期间重建，那次 Skip 可能没有覆盖新内容"
        elif created_dt <= target_anchor:
            verdict = "源已重新构建：源 Created 在上次运行结束与 target 之间"
        else:
            verdict = "源在 target 之后又重建过；target 当时内容无法回推"
    elif nxt and next_fp and target_fp:
        if next_fp == target_fp:
            verdict = "源未变：与下一次 Synced 的 config digest 相同"
        else:
            verdict = "目标之后又重建过；target 当时内容无法仅凭日志回推"
    elif next_any and next_any.get("status") == "skipped" and created_dt:
        q = time_of(next_any)
        q_end = time_end(next_any)
        if created_dt <= target_anchor:
            verdict = "源未变（下次运行 Skip 且 Created 不晚于 target）；target 的写入可能只是补同步"
        elif created_dt <= q:
            verdict = "源在 target 与下次运行开始之间重建过"
        elif created_dt <= q_end:
            verdict = "无法确定：源在下次运行期间重建"
        else:
            verdict = "源在下次运行之后又重建过；target 当时内容无法回推"
    elif prev_any and prev_any.get("status") == "failed":
        verdict = "上次运行失败、缺少可比指纹；需结合源 Created 判断"
    else:
        verdict = "日志指纹不足，需结合源 Created 判断"

    if created_dt and created_dt > target_anchor + dt.timedelta(minutes=10):
        verdict += "；源在 target 之后又重建过（当前是否落后看 now src==dest）"
    if not now_equal:
        verdict += "；当前源/目标 digest 不一致"

created_hint = ""
if created_dt and ("不足" in verdict or "无法确定" in verdict):
    if created_dt > anchor_time:
        created_hint = "（Created 晚于目标最后写入 → 之后又重建过）"
    elif prev_any and created_dt <= time_of(prev_any):
        created_hint = "（Created 早于上次运行 → target 时未重建）"
    elif prev_any and created_dt <= target_anchor:
        created_hint = "（Created 在上次运行与 target 之间 → target 前已重建）"

verdict_full = verdict + created_hint

# 能推断出的“当时 digest”：
#   - 如果 target 就是 Quay last_modified 那次写入 → 当前 Quay digest 就是当时写进去的
#   - 如果结论是“源未变”且当前源/目标一致 → 当时源/目标 digest = 当前源 top digest
inferred_before = (
    src_top
    if ("未变" in verdict and prev_any and now_equal)
    else None
)
inferred_after = None
if (tgt and anchor_source == "quay_last_modified"
        and abs((target_anchor - anchor_time).total_seconds()) <= 30 * 60):
    inferred_after = (qmeta or {}).get("manifest_digest") or dest_top

tgt_desc = (
    f"{tgt['run_id']} @ {tgt.get('event_at') or tgt['job_started']}"
    if tgt else "-"
)
prev_desc = (
    f"{prev['run_id']} @ {prev.get('event_at') or prev['job_started']} ({len(prev_fp)} cfg)"
    if prev else "-"
)
next_desc = (
    f"{nxt['run_id']} @ {nxt.get('event_at') or nxt['job_started']} ({len(next_fp)} cfg)"
    if nxt else "-"
)
prev_any_desc = (
    f"{prev_any['run_id']} @ {prev_any.get('event_at') or prev_any['job_started']} ({prev_any.get('status')})"
    if prev_any else "-"
)
next_any_desc = (
    f"{next_any['run_id']} @ {next_any.get('event_at') or next_any['job_started']} ({next_any.get('status')})"
    if next_any else "-"
)
qlm = (qmeta or {}).get("last_modified", "-") if isinstance(qmeta, dict) else "-"

log("")
log(f"anchor: {anchor_time.isoformat()} ({anchor_source})")
log(f"target: {tgt_desc} configs={short(target_fp)}")
log(f"prev any: {prev_any_desc}")
log(f"next any: {next_any_desc}")
log(f"prev synced: {prev_desc} configs={short(prev_fp)}")
log(f"next synced: {next_desc} configs={short(next_fp)}")
log(f"src Created: {src_created or 'n/a'}" + (f" (err: {created_err})" if created_err else ""))
log(f"src  manifest_id now: {src_mid_now or 'n/a'}" + (f" (err: {src_err})" if src_err else ""))
log(f"dest manifest_id now: {dest_mid_now or 'n/a'}" + (f" (err: {dest_err})" if dest_err else ""))
log(f"src  top digest: {src_top or 'n/a'}" + (f" (err: {src_top_err})" if src_top_err else ""))
log(f"dest top digest: {dest_top or 'n/a'}" + (f" (err: {dest_top_err})" if dest_top_err else ""))
log(f"quay last_modified: {qlm}")
log(f"quay manifest_digest: {(qmeta or {}).get('manifest_digest', '-') if isinstance(qmeta, dict) else '-'}")
log(f"now src==dest: {now_equal}")
log(f"inferred before digest: {inferred_before or '无法推断（历史 manifest digest 未落盘）'}")
log(f"inferred after  digest: {inferred_after or '无法推断（该 tag 之后又被写过）'}")
log(f"verdict: {verdict_full}")

log("")
log("Timeline (oldest -> newest):")
for e in events[-20:]:
    mark = "  <== target" if tgt and e["run_id"] == target_run_id else ""
    log(f"  {e['run_id']} @ {e.get('event_at') or e['job_started']} "
        f"{e.get('status')} configs={short(e['configs'])}{mark}")

def ser(entry):
    if not entry:
        return None
    return {**entry, "configs": sorted(entry.get("configs", []))}

report = {
    "tag": TAG,
    "src": SRC,
    "dest": DEST,
    "anchor": {"source": anchor_source, "time": anchor_time.isoformat()},
    "current": {
        "src_manifest_id": src_mid_now,
        "dest_manifest_id": dest_mid_now,
        "src_top_digest": src_top,
        "dest_top_digest": dest_top,
        "src_created": src_created,
        "now_equal": now_equal,
        "quay": qmeta,
    },
    "target": ser(tgt),
    "prev_any": ser(prev_any),
    "next_any": ser(next_any),
    "prev_synced": ser(prev),
    "next_synced": ser(nxt),
    "inferred_before_manifest_digest": inferred_before,
    "inferred_after_manifest_digest": inferred_after,
    "verdict": verdict_full,
    "timeline": [ser(e) for e in events],
}

summary = [
    "# Sync history for one tag",
    "",
    f"- tag: `{TAG}`",
    f"- src: `{SRC}`",
    f"- dest: `{DEST}`",
    f"- anchor: `{anchor_time.isoformat()}` ({anchor_source})",
    "",
    "| tag | anchor | target sync | prev any | prev synced | next synced | target config digests | prev config digests | src Created | now src==dest | verdict |",
    "|---|---|---|---|---|---|---|---|---|---|---|",
    f"| `{TAG}` | {anchor_time.isoformat()} ({anchor_source}) | {tgt_desc} | {prev_any_desc} | {prev_desc} | {next_desc} "
    f"| {short(target_fp)} | {short(prev_fp)} | {src_created or '-'} | {now_equal} | {verdict_full} |",
]

os.makedirs("/tmp/inspect-sync-digests", exist_ok=True)
with open("/tmp/inspect-sync-digests/report.json", "w") as f:
    json.dump(report, f, indent=2, default=str)
with open("/tmp/inspect-sync-digests/summary.md", "w") as f:
    f.write("\n".join(summary) + "\n")
with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
    f.write("\n".join(summary) + "\n")

log("")
log("Report written to /tmp/inspect-sync-digests/report.json")
