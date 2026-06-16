# 同步工具 (sync-tools) 说明

## 项目概述

本项目通过[skopeo](https://github.com/containers/skopeo)将各种昇腾可用的镜像从主要的[发布 registry](https://quay.io/organization/ascend/)同步到各种[registry]，方便用户就近下载使用。

同时支持将模型和数据集按项目同步到多个 NPU 集群（self-serve 模式：每个仓库只需维护一份合并配置，无需新增 workflow）。

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
├── docker/
│   └── sync-tools/Dockerfile             # 同步任务专用镜像（含 jq / huggingface_hub / modelscope）
├── scripts/
│   ├── build-sync-matrix.sh              # 根据触发事件展开 project×cluster 矩阵
│   └── download-json-models.sh           # 实际下载逻辑（HuggingFace / ModelScope）
└── workflows/
    ├── config/                           # 配置文件目录
    │   ├── projects-clusters.json        # 项目 → 集群映射（唯一总表）
    │   ├── image-sync.json               # 镜像同步列表
    │   ├── readme-sync.json              # README 同步列表
    │   └── projects/                     # 每个项目一份合并配置
    │       ├── vllm.json
    │       ├── sglang.json
    │       ├── ms-swift.json
    │       └── llamafactory.json
    ├── sync-models-datasets.yml          # 通用的模型/数据集同步工作流
    ├── build-sync-tools-image.yml        # 构建/推送 sync-tools 同步镜像（手动触发）
    ├── sync-images.yml                   # 镜像同步工作流
    ├── sync-readmes.yml                  # README 同步工作流
    └── test.yml                          # 配置验证工作流
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

### 模型/数据集同步（按项目，self-serve）

每个项目维护一份合并配置（`models` + `datasets`），系统自动将资源同步到该项目关联的所有集群。

#### 1. 项目与集群映射

编辑 [projects-clusters.json](.github/workflows/config/projects-clusters.json)：

```json
{
  "vllm":         { "clusters": ["linux-amd64-vllm-guiyang003"] },
  "sglang":       { "clusters": ["linux-amd64-sglang-guiyang004", "linux-amd64-sglang-sglang01"] },
  "ms-swift":     { "clusters": ["linux-aarch64-sync-hk001"] },
  "llamafactory": { "clusters": ["linux-aarch64-sync-hk001"] }
}
```

#### 2. 修改同步的模型/数据集列表

编辑 `.github/workflows/config/projects/<project>.json`：

```json
{
  "models": [
    { "platform": "modelscope",  "organization": "Qwen",   "model_name": "Qwen2.5-7B-Instruct" },
    { "platform": "huggingface", "organization": "Qwen",   "model_name": "Qwen2.5-0.5B-Instruct", "local_dir": "/root/.cache/custom-path" }
  ],
  "datasets": [
    { "platform": "huggingface", "organization": "openai", "dataset_name": "gsm8k" }
  ]
}
```

字段说明：

- `platform`：`modelscope` 或 `huggingface`
- `organization` + `model_name` / `dataset_name`：仓库名
- `local_dir`（可选）：自定义下载路径；为空或缺失时由 SDK 走自身默认 cache（`huggingface_hub` → `~/.cache/huggingface`，`modelscope` → `~/.cache/modelscope`）

`models` 或 `datasets` 任一为空数组都可以，对应类型会被跳过。

> **持久化**：ARC runner pod 在 `/root/.cache` 挂载了持久化卷，所以 SDK 默认 cache 路径下的内容会跨任务保留，相同 revision 不会重复下载。

[vllm](.github/workflows/config/projects/vllm.json) ·
[sglang](.github/workflows/config/projects/sglang.json) ·
[ms-swift](.github/workflows/config/projects/ms-swift.json) ·
[llamafactory](.github/workflows/config/projects/llamafactory.json)

#### 3. 新增项目（self-serve）

只需两步：

1. 在 [projects-clusters.json](.github/workflows/config/projects-clusters.json) 加一条记录，指定该项目对应的 runner（集群）
2. 在 `.github/workflows/config/projects/` 下新建 `<project>.json`，填入要下载的模型和数据集

push 到 `main` 后会自动触发同步。**无需新建任何 workflow 文件。**

#### 4. 为项目添加新集群

只需在 `projects-clusters.json` 中对应项目的 `clusters` 数组中追加新的集群名称即可。

#### 5. 触发逻辑

通用工作流 [sync-models-datasets.yml](.github/workflows/sync-models-datasets.yml) 监听三种事件，由 [build-sync-matrix.sh](.github/scripts/build-sync-matrix.sh) 决定要跑哪些项目：

- **定时（每 6 小时）**：全量同步所有项目
- **手动 `workflow_dispatch`**：可选 `project` 输入，留空则全量
- **push 到 main**：只跑发生变更的项目（diff `config/projects/<name>.json` 或 `projects-clusters.json` 中 `clusters` 列表变化的项目）；如果改的是 workflow 自身或 matrix 脚本，则全量跑作为保险

#### 6. 同步镜像

所有 sync job 跑在专用的 `sync-tools` 镜像里（预装 jq、huggingface_hub、modelscope、datasets、filelock），双架构（amd64 + arm64）。

- 镜像地址：`swr.cn-southwest-2.myhuaweicloud.com/base_image/ascend-ci/sync-tools:latest`
- Dockerfile：[.github/docker/sync-tools/Dockerfile](.github/docker/sync-tools/Dockerfile)
- 构建：手动触发 [build-sync-tools-image.yml](.github/workflows/build-sync-tools-image.yml)（buildx 多架构构建并推送到 SWR）

Dockerfile 改动后需要重跑构建 workflow 才能让新内容生效。

### 同步 README 到镜像仓库

编辑 [readme-sync.json](.github/workflows/config/readme-sync.json)，每条记录声明从哪里取 README、推到哪个仓库：

```json
[
  { "src": "https://raw.gitcode.com/user/project/raw/main/docker/README.md",
    "dest": "docker.io/ascendai/slime-ascend" },
  { "src": "https://raw.gitcode.com/user/project/raw/main/docker/README.md",
    "dest": "quay.io/ascend/slime-ascend" }
]
```

- `src` 为可公开访问的 README 原文 URL
- `dest` 目前支持 `docker.io/*` 和 `quay.io/*`
- 工作流使用 [docker-pushrm](https://github.com/christian-korneck/docker-pushrm) 调用各 registry 的描述更新 API，内容未变化（sha256 相同）则跳过
- 触发方式：每日 06:17 UTC 定时 + `workflow_dispatch` 手动触发 + `readme-sync.json` 变更时自动触发
- Quay API token：默认复用 `QUAY_ASCEND_PWD`；若该机器人账号无 repo admin 权限，需在 secrets 中新增 `QUAY_API_TOKEN`（Quay OAuth token，权限至少 `Read/Write to any accessible repositories`），工作流会优先使用它

### 手动触发同步

- 在 GitHub Actions 页面选择对应的工作流，点击 "Run workflow" 即可手动触发同步。
- 也可以通过向 `main` 分支推送配置文件变更来触发同步。

### 查看同步日志

- 在 GitHub Actions 页面查看各工作流的执行日志，确认同步是否成功。
- 失败时会发送通知（如配置了通知）。

## 故障排查

- **同步失败**: 检查网络连通性、凭证有效性以及源仓库的可访问性。
- **镜像同步超时**: 可适当调整 `skopeo` 的超时和重试参数。
- **模型下载失败**: 确认模型名称是否正确，以及是否有访问权限。

## 相关文档

- [功能设计文档](DESIGN.md) – 系统架构、各子系统工作原理与关键设计取舍（“它是怎么工作的、为什么这么设计”）。
- [镜像地址指引（按项目分类）](IMAGE_SYNC_GUIDE.md) – 详细列出各项目镜像的存放地址，方便快速查找。

## 更新记录
- 2026-05-18: 模型/数据集同步重构为单一通用工作流 `sync-models-datasets.yml`，每个项目一份合并配置 `config/projects/<name>.json`（含 `models` / `datasets`，可选 `local_dir`，留空走 SDK 默认 cache）；新增双架构同步镜像 `sync-tools` 与构建 workflow；删除 hk001，新增 ms-swift / llamafactory（共用 `linux-aarch64-sync-hk001` runner）；新增项目只需 2 个文件改动，无需新建 workflow。
- 2026-05-13: 新增 README 同步工作流（sync-readmes.yml），通过 docker-pushrm 将 README 推送到 Docker Hub / Quay.io 的对应仓库。
- 2026-04-20: 镜像同步改为配置驱动（image-sync.json），支持任意源/目标 registry，同步频率改为每小时一次，新增 digest 比对跳过机制。
- 2025-12-08: 更新 README，新增 HK001 同步说明，补充镜像同步流向。
- 2025-11-15: 初始版本，包含 VLLM 和 SGLANG 同步。
