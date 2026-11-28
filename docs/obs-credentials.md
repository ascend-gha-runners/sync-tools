# OBS 凭据清单

> 只记录「哪个 secret 对应哪个桶、什么权限」，**不记录明文密钥**。密钥值只存在于 GitHub Actions Secrets。

## Secret 命名约定

`OBS_<目标>_<用途>_<AK|SK>`

- 目标：`MIRROR`（昇腾 PyPI 镜像后端）、`VLLM_ASCEND`（vllm-ascend 源桶）等
- 用途：`PUSH`（写）、`READ`（只读）

## 清单

| Secret 名 | 桶 | 区域 | 前缀 | 权限 | 用途 |
|---|---|---|---|---|---|
| `OBS_MIRROR_PUSH_AK` / `OBS_MIRROR_PUSH_SK` | `ascend-artifcat-packages` | cn-north-4 | `pypi/packages/ascend/repos/pypi/` | 上传、删除、列目录；**无读**（HEAD 403） | sync-pypi 上传 wheel 到镜像 |
| `OBS_VLLM_ASCEND_READ_AK` / `OBS_VLLM_ASCEND_READ_SK` | `vllm-ascend` | cn-north-4 | `vllm-ascend/` | 只读（列目录 + 下载） | 自动发现源桶新包 |

## 说明

- 镜像地址 `mirrors.huaweicloud.com/ascend/repos/pypi/` 对应桶 `ascend-artifcat-packages` 的 `pypi/packages/ascend/repos/pypi/` 前缀。
- 当前 `OBS_MIRROR_PUSH_AK` 只有写权限（无 `GetObject`），所以脚本用 `listObjects` 判断对象是否已存在，不能用 `HEAD`。
- 源桶 `vllm-ascend` 用 `OBS_VLLM_ASCEND_READ_AK` 列目录 + 下载；`pypi-sync.json` 里每项 `name` 对应源桶里 `vllm-ascend/<name>-*.whl`，`target_dir` 是目标目录。新版本自动发现、只同步新增。
