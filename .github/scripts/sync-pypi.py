import json
import os
import sys
import tempfile

from obs import ObsClient

CONFIG_PATH = ".github/workflows/config/pypi-sync.json"
SERVER = "https://obs.cn-north-4.myhuaweicloud.com"

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


def main():
    src_ak = os.environ.get("OBS_VLLM_ASCEND_READ_AK")
    src_sk = os.environ.get("OBS_VLLM_ASCEND_READ_SK")
    dst_ak = os.environ.get("OBS_MIRROR_PUSH_AK")
    dst_sk = os.environ.get("OBS_MIRROR_PUSH_SK")
    missing = [n for n, v in [
        ("OBS_VLLM_ASCEND_READ_AK", src_ak), ("OBS_VLLM_ASCEND_READ_SK", src_sk),
        ("OBS_MIRROR_PUSH_AK", dst_ak), ("OBS_MIRROR_PUSH_SK", dst_sk),
    ] if not v]
    if missing:
        print("缺少环境变量:", ", ".join(missing))
        sys.exit(1)

    with open(CONFIG_PATH) as f:
        entries = json.load(f)

    src = ObsClient(access_key_id=src_ak, secret_access_key=src_sk, server=SERVER)
    dst = ObsClient(access_key_id=dst_ak, secret_access_key=dst_sk, server=SERVER)

    print("列出源桶 vllm-ascend ...")
    src_keys = list_keys(src, SRC_BUCKET, SRC_PREFIX)

    print("列出目标桶已存在的对象 ...")
    dst_keys = set()
    for e in entries:
        dst_keys |= list_keys(dst, DST_BUCKET, DST_PREFIX + e["target_dir"].rstrip("/") + "/")

    synced = skipped = failed = 0
    for e in entries:
        name = e["name"]
        target_dir = e["target_dir"]
        prefix = name + "-"
        matched = [
            k for k in src_keys
            if k.startswith(SRC_PREFIX + prefix) and k.endswith(".whl")
        ]
        if not matched:
            print(f"  [跳过] {name}: 源桶无匹配 wheel")
            continue

        for src_key in sorted(matched):
            filename = src_key[len(SRC_PREFIX):]
            dst_key = DST_PREFIX + target_dir.rstrip("/") + "/" + filename

            if dst_key in dst_keys:
                print(f"SKIP {dst_key}")
                skipped += 1
                continue

            tmp = os.path.join(tempfile.gettempdir(), filename)
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
                else:
                    print(f"FAIL {dst_key} -> 上传失败 {r2.status} {r2.errorCode} {r2.errorMessage}")
                    failed += 1
            except Exception as exc:
                print(f"FAIL {dst_key} -> {exc}")
                failed += 1
            finally:
                if os.path.exists(tmp):
                    os.remove(tmp)

    print(f"done: {synced} synced, {skipped} skipped, {failed} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
