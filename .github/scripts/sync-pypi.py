import json
import os
import sys
import tempfile
import urllib.parse
import urllib.request

from obs import ObsClient

CONFIG_PATH = ".github/workflows/config/pypi-sync.json"
BUCKET = "ascend-artifcat-packages"
SERVER = "https://obs.cn-north-4.myhuaweicloud.com"
TARGET_PREFIX = "pypi/packages/ascend/repos/pypi/"


def main():
    ak = os.environ.get("HW_AK")
    sk = os.environ.get("HW_SK")
    if not ak or not sk:
        print("缺少 HW_AK / HW_SK 环境变量")
        sys.exit(1)

    with open(CONFIG_PATH) as f:
        entries = json.load(f)

    obs = ObsClient(access_key_id=ak, secret_access_key=sk, server=SERVER)

    dirs = sorted({e["target_dir"] for e in entries})
    existing = set()
    for d in dirs:
        prefix = TARGET_PREFIX + d.rstrip("/") + "/"
        existing |= list_keys(obs, prefix)

    synced = skipped = failed = 0
    for e in entries:
        source = e["source"]
        target_dir = e["target_dir"]
        filename = urllib.parse.unquote(os.path.basename(urllib.parse.urlsplit(source).path))
        key = TARGET_PREFIX + target_dir.rstrip("/") + "/" + filename

        if key in existing:
            print(f"SKIP {key}")
            skipped += 1
            continue

        tmp = None
        try:
            tmp = os.path.join(tempfile.gettempdir(), filename)
            download(source, tmp)
            resp = obs.putFile(bucketName=BUCKET, objectKey=key, file_path=tmp)
            if resp.status < 300:
                print(f"OK   {key}")
                synced += 1
            else:
                print(f"FAIL {key} -> {resp.status} {resp.errorCode} {resp.errorMessage}")
                failed += 1
        except Exception as exc:
            print(f"FAIL {key} -> {exc}")
            failed += 1
        finally:
            if tmp and os.path.exists(tmp):
                os.remove(tmp)

    print(f"done: {synced} synced, {skipped} skipped, {failed} failed")
    sys.exit(1 if failed else 0)


def list_keys(obs, prefix):
    keys = set()
    marker = None
    while True:
        resp = obs.listObjects(BUCKET, prefix=prefix, marker=marker, max_keys=1000)
        if resp.status >= 300:
            print(f"listObjects 失败 {prefix} -> {resp.status} {resp.errorCode} {resp.errorMessage}")
            break
        body = resp.body
        for obj in (body.contents or []):
            keys.add(obj.key)
        if not body.is_truncated:
            break
        marker = body.contents[-1].key
    return keys


def download(url, path):
    req = urllib.request.Request(url, headers={"User-Agent": "sync-tools"})
    with urllib.request.urlopen(req, timeout=300) as r, open(path, "wb") as f:
        while True:
            chunk = r.read(1024 * 1024)
            if not chunk:
                break
            f.write(chunk)


if __name__ == "__main__":
    main()
