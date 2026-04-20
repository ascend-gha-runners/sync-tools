# 同步工具 (sync-tools) 说明

## 项目概述

本项目通过[skopeo](https://github.com/containers/skopeo)将各种昇腾可用的镜像从主要的[发布 registry](https://quay.io/organization/ascend/)同步到各种[registry]，方便用户就近下载使用


## 包含的image

|镜像|源地址|目标地址|下载命令|同步日志|
|--|--|--|--|--|
|[sglang](https://github.com/sgl-project/sglang)|`docker.io/lmsysorg/sglang`|国外： `quay.io/ascend/sglang`<br>国内： ` swr.cn-southwest-2.myhuaweicloud.com/base_image/ascend-ci/dockerhub/lmsysorg/sglang`||
|[vllm-ascend](https://github.com/vllm-project/vllm-ascend)|`quay.io/ascend/vllm-ascend`|国内： `swr.cn-southwest-2.myhuaweicloud.com/base_image/ascend-ci/vllm-ascend/vllm-ascend`||
|[verl](https://github.com/verl-project/verl)|`docker.io/verlai/verl`|国外： `quay.io/ascend/verl`<br>国内： `swr.cn-southwest-2.myhuaweicloud.com/base_image/ascend-ci/verl/verl`||
|[llamafactory](https://github.com/hiyouga/LlamaFactory)|`docker.io/hiyouga/llamafactory`|国外：`quay.io/ascend/llamafactory`<br>国内：`swr.cn-southwest-2.myhuaweicloud.com/base_image/ascend-ci/llamafactory/llamafactory`||
|[veomni](https://github.com/ByteDance-Seed/VeOmni)|`quay.io/ascend/veomni`|国内：`swr.cn-southwest-2.myhuaweicloud.com/base_image/ascend-ci/veomni/veomni`|
|[cann](https://gitcode.com/cann)|`quay.io/ascend/cann`|国内：`swr.cn-southwest-2.myhuaweicloud.com/base_image/ascend-ci/cann/cann`||
|[pytorch-npu](https://gitcode.com/ascend/pytorch)|TBD|TBD||
|[swift](https://github.com/modelscope/ms-swift)|TBD|TBD||
|[triton-ascend](https://gitcode.com/ascend/triton-ascend)|`quay.io/ascend/triton`|国内：`swr.cn-southwest-2.myhuaweicloud.com/base_image/ascend-ci/triton/triton`||
|[tilelang-ascend](https://github.com/tile-ai/tilelang-ascend)|TBD|TBD||
## 项目结构

```
.github/
└── workflows/
    ├── config/                           # 配置文件目录
    │   ├── vllm-downloaded-models.ini    # VLLM 模型同步配置
    │   ├── vllm-downloaded-datasets.ini  # VLLM 数据集同步配置
    │   ├── sglang-downloaded-models.ini  # SGLANG 模型同步配置
    │   ├── sglang-downloaded-datasets.ini # SGLANG 数据集同步配置
    │   ├── hk001-models.json             # HK001 模型同步配置 (JSON)
    │   └── hk001-datasets.json           # HK001 数据集同步配置 (JSON)
    ├── vllm-sync-models-datasets.yml     # VLLM 同步工作流
    ├── sglang-innersourse-sync-models-datasets.yml  # SGLANG 内源同步
    ├── sglang-opensourse-sync-models-datasets.yml   # SGLANG 开源同步
    ├── hk001-sync-models.yml             # HK001 模型同步工作流
    ├── hk001-sync-datasets.yml           # HK001 数据集同步工作流
    ├── sync-images.yml                   # 镜像同步工作流
    └── test.yml                          # 测试工作流
```

## 使用方法

### 镜像的同步列表

编辑 [image-sync.json](.github/workflows/config/image-sync.json)，每条记录格式如下：

```json
{ "src": "quay.io/ascend/cann", "dest": "docker.io/ascendai/cann" }
```

支持可选的 `tag_filter` 字段，用于只同步名称匹配关键词的 tag（如 sglang 只同步含 `cann` 的 tag）：

```json
{ "src": "docker.io/lmsysorg/sglang", "dest": "quay.io/ascend/sglang", "tag_filter": "cann" }
```

workflow 根据域名自动匹配认证信息，目前支持的源/目标 registry：

| 域名 | 说明 |
|---|---|
| `quay.io` | Quay.io（Ascend 主发布源） |
| `docker.io` | Docker Hub |
| `swr.cn-southwest-2.myhuaweicloud.com` | 华为云 SWR 西南 |
| `swr.ap-southeast-1.myhuaweicloud.com` | 华为云 SWR 香港 |
| `ascendhub.huawei.com` | AscendHub（认证待补充） |

同步每小时自动执行一次，每个 tag 在 push 前会比对源和目标的 manifest digest，内容未变则跳过，不会刷新目标 registry 的更新时间。

### 修改同步的模型列表

编辑对应的 `.ini` 配置文件，添加需要同步的模型和数据集名称：

```ini
# 示例配置
model_name_1
model_name_2
```

[vllm-ascend模型下载列表](.github/workflows/config/vllm-downloaded-models.ini)
[vllm-ascend数据集下载列表](.github/workflows/config/vllm-downloaded-datasets.ini)
[sglang模型下载列表](.github/workflows/config/sglang-downloaded-models.ini)
[sglang模型下载列表](.github/workflows/config/sglang-downloaded-datasets.ini)

### 配置多平台下载
编辑对应的 `.json` 配置文件，支持多平台 (ModelScope 或 HuggingFace)：

```json
[
  {
    "platform": "modelscope",
    "organization": "organization_name",
    "model_name": "model_name"
  },
  {
    "platform": "huggingface",
    "organization": "organization_name",
    "dataset_name": "dataset_name"
  }
]
```

### 2. 手动触发同步
- 在 GitHub Actions 页面选择对应的工作流，点击 "Run workflow" 即可手动触发同步。
- 也可以通过向 `main` 分支推送配置文件变更来触发同步。

### 3. 查看同步日志
- 在 GitHub Actions 页面查看各工作流的执行日志，确认同步是否成功。
- 失败时会发送通知（如配置了通知）。

## 故障排查

- **同步失败**: 检查网络连通性、凭证有效性以及源仓库的可访问性。
- **镜像同步超时**: 可适当调整 `skopeo` 的超时和重试参数。
- **模型下载失败**: 确认模型名称是否正确，以及是否有访问权限。

## 相关文档

- [镜像地址指引（按项目分类）](IMAGE_SYNC_GUIDE.md) – 详细列出各项目镜像的存放地址，方便快速查找。

## 更新记录
- 2026-04-20: 镜像同步改为配置驱动（image-sync.json），支持任意源/目标 registry，同步频率改为每小时一次，新增 digest 比对跳过机制。
- 2025-12-08: 更新 README，新增 HK001 同步说明，补充镜像同步流向。
- 2025-11-15: 初始版本，包含 VLLM 和 SGLANG 同步。
