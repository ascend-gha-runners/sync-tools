import json
import os
import re
import sys
import tempfile
import urllib.request

from obs import ObsClient

CONFIG_PATH = ".github/workflows/config/pypi-sync.json"
SERVER = "https://obs.cn-north-4.myhuaweicloud.com"
MIRROR_BASE = "https://mirrors.huaweicloud.com/ascend/repos/pypi/"

SRC_BUCKET = "vllm-ascend"
SRC_PREFIX = "vllm-ascend/"
DST_BUCKET = "ascend-artifcat-packages"
DST_PREFIX = "pypi/packages/ascend/repos/pypi/"


def list_keys(obs, bucket, prefix):
    keys = set()
    marker = None
    while True:
        resp = obs.listObjects(bucket, prefix=prefix, marker=marker, max_keys=1000)
        if resp.status >= 300:
            raise RuntimeError(f"listObjects 失败 {bucket}/{prefix}: {resp.status} {resp.errorCode} {resp.errorMessage}")
        body = resp.body
        for obj in (body.contents or []):
            keys.add(obj.key)
        if not body.is_truncated:
            break
        marker = body.next_marker
    return keys


def list_subdirs(obs, bucket, prefix):
    dirs = set()
    for key in list_keys(obs, bucket, prefix):
        rest = key[len(prefix):]
        if "/" in rest:
            dirs.add(rest.split("/", 1)[0])
    return dirs


def fetch_title(mirror_path):
    url = MIRROR_BASE + mirror_path
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "sync-tools"})
        html = urllib.request.urlopen(req, timeout=30).read().decode("utf-8", "ignore")
        m = re.search(r"<title>(.*?)</title>", html, re.S)
        return m.group(1).strip() if m else ""
    except Exception:
        return ""


def regenerate_index(dst, obj_prefix, title):
    dirs = sorted(list_subdirs(dst, DST_BUCKET, obj_prefix))
    if not dirs:
        print(f"  [index] {obj_prefix} 无子目录，跳过")
        return True
    html = "<html><head><title>%s</title><meta name='api-version' value='2' /></head><body>\n" % title
    for d in dirs:
        html += "<a href='%s/'>%s</a><br />\n" % (d, d)
    html += "</body></html>"
    key = obj_prefix + "index.html"
    r = dst.putContent(DST_BUCKET, key, content=html, headers={"Content-Type": "text/html"})
    if r.status < 300:
        print(f"  [index] 已更新 {key}")
        return True
    print(f"  [index] 更新失败 {key} -> {r.status} {r.errorCode} {r.errorMessage}")
    return False


def main():
    envs = {
        "OBS_VLLM_ASCEND_READ_AK": os.environ.get("OBS_VLLM_ASCEND_READ_AK"),
        "OBS_VLLM_ASCEND_READ_SK": os.environ.get("OBS_VLLM_ASCEND_READ_SK"),
        "OBS_MIRROR_PUSH_AK": os.environ.get("OBS_MIRROR_PUSH_AK"),
        "OBS_MIRROR_PUSH_SK": os.environ.get("OBS_MIRROR_PUSH_SK"),
    }
    missing = [k for k, v in envs.items() if not v]
    if missing:
        print("缺少环境变量:", ", ".join(missing))
        sys.exit(1)

    with open(CONFIG_PATH) as f:
        entries = json.load(f)

    for i, e in enumerate(entries):
        if not e.get("name") or not e.get("target_dir"):
            print(f"配置第 {i} 项缺少 name 或 target_dir: {e}")
            sys.exit(1)

    src = ObsClient(access_key_id=envs["OBS_VLLM_ASCEND_READ_AK"],
                    secret_access_key=envs["OBS_VLLM_ASCEND_READ_SK"], server=SERVER)
    dst = ObsClient(access_key_id=envs["OBS_MIRROR_PUSH_AK"],
                    secret_access_key=envs["OBS_MIRROR_PUSH_SK"], server=SERVER)

    print("列出源桶 vllm-ascend ...")
    src_keys = list_keys(src, SRC_BUCKET, SRC_PREFIX)

    print("列出目标桶已存在的对象 ...")
    dst_keys = set()
    for e in entries:
        dst_keys |= list_keys(dst, DST_BUCKET, DST_PREFIX + e["target_dir"].rstrip("/") + "/")

    synced = skipped = failed = 0
    changed_parents = set()
    for e in entries:
        name = e["name"]
        target_dir = e["target_dir"]
        matched = [
            k for k in src_keys
            if k.startswith(SRC_PREFIX + name + "-") and k.endswith(".whl")
        ]
        if not matched:
            print(f"  [跳过] {name}: 源桶无匹配 wheel")
            continue

        parent = target_dir.rsplit("/", 1)[0] if "/" in target_dir else ""
        for src_key in sorted(matched):
            filename = src_key[len(SRC_PREFIX):]
            dst_key = DST_PREFIX + target_dir.rstrip("/") + "/" + filename

            if dst_key in dst_keys:
                print(f"SKIP {dst_key}")
                skipped += 1
                continue

            tmp = os.path.join(tempfile.gettempdir(), f"syncpypi-{os.getpid()}-{filename}")
            try:
                r = src.getObject(SRC_BUCKET, src_key, downloadPath=tmp)
                if r.status >= 300:
                    print(f"FAIL {dst_key} -> 下载失败 {r.status} {r.errorCode} {r.errorMessage}")
                    failed += 1
                    continue
                r2 = dst.putFile(DST_BUCKET, dst_key, file_path=tmp)
                if r2.status < 300:
                    print(f"OK   {dst_key}")
                    synced += 1
                    changed_parents.add(parent)
                else:
                    print(f"FAIL {dst_key} -> 上传失败 {r2.status} {r2.errorCode} {r2.errorMessage}")
                    failed += 1
            except Exception as exc:
                print(f"FAIL {dst_key} -> {exc}")
                failed += 1
            finally:
                if os.path.exists(tmp):
                    os.remove(tmp)

    for parent in sorted(changed_parents):
        obj_prefix = DST_PREFIX + (parent + "/" if parent else "")
        mirror_path = parent + "/" if parent else ""
        title = fetch_title(mirror_path)
        try:
            ok = regenerate_index(dst, obj_prefix, title)
        except Exception as exc:
            print(f"  [index] 更新异常 {obj_prefix} -> {exc}")
            ok = False
        if not ok:
            failed += 1

    print(f"done: {synced} synced, {skipped} skipped, {failed} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
