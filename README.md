# 同步工具 (sync-tools) 说明

## 项目概述

本项目是一个自动化同步工具集，用于在多个集群和镜像仓库之间同步模型、数据集和容器镜像。通过 GitHub Actions 实现定时和触发式同步，确保各环境数据的一致性。

## 核心功能

### 1. 模型和数据集同步

#### VLLM 项目同步
- **Runner**: `linux-amd64-vllm-guiyang003`
- **特点**: 两个集群共用一个共享盘，只需一个 Runner 同步一次
- **配置文件**: 
  - `vllm-downloaded-models.ini`
  - `vllm-downloaded-datasets.ini`

#### SGLANG 项目同步
- **Runner 分配策略**:
  - `linux-amd64-sglang-sglang01`: 负责内源 **华东 001 集群** 同步
  - `linux-amd64-sglang-guiyang004`: 负责开源 **贵阳 004 集群** 同步
- **特点**: 两个 Runner 共用同一份配置文件
- **配置文件**:
  - `sglang-downloaded-models.ini`
  - `sglang-downloaded-datasets.ini`

#### HK001 项目同步
- **Runner**: `linux-aarch64-sync-hk001`
- **特点**: 针对香港集群的ci 项目，支持从 ModelScope 和 HuggingFace 同步模型和数据集
- **配置文件**:
  - `hk001-models.json` (JSON 格式，支持多平台)
  - `hk001-datasets.json` (JSON 格式，支持多平台)

### 2. 镜像同步

#### 同步流向 1: 东南1 → Quay.io
- **源仓库**: `swr.ap-southeast-1.myhuaweicloud.com/base_image/ascend-ci/sglang`
- **目标仓库**: `quay.io/ascend/`

#### 同步流向 2: Quay.io → 西南2
- **源仓库**: `quay.io/ascend/`
- **目标仓库**: `swr.cn-southwest-2.myhuaweicloud.com/base_image/ascend-ci/`
- **同步镜像**: cann, vllm-ascend, manylinux, llamafactory, triton, mindspore, python, pytorch

#### 同步流向 3: 东南1 → 华东4
- **源仓库**: `swr.ap-southeast-1.myhuaweicloud.com/base_image/ascend-ci/sglang`
- **目标仓库**: `swr.cn-east-4.myhuaweicloud.com/base_image/ascend-ci/sglang`

#### 同步流向 4: DockerHub → 西南2 (CANN 相关标签)
- **源仓库**: `docker.io/lmsysorg/sglang`
- **目标仓库**: `swr.cn-southwest-2.myhuaweicloud.com/base_image/dockerhub/lmsysorg/sglang`
- **筛选条件**: 仅同步包含 "cann" 标签的镜像

#### 同步流向 5: DockerHub → Quay.io (CANN 相关标签)
- **源仓库**: `docker.io/lmsysorg/sglang`
- **目标仓库**: `quay.io/ascend/sglang`
- **筛选条件**: 仅同步包含 "cann" 标签的镜像

#### 同步流向 6: Quay.io → 香港 SWR (verl)
- **源仓库**: `quay.io/ascend/verl`
- **目标仓库**: `swr.ap-southeast-1.myhuaweicloud.com/base_image/ascend-ci/verl`

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

## 工作流配置

### 模型数据集同步
- **触发方式**: 每 6 小时自动执行，手动触发，文件变更触发
- **执行环境**: 
  - VLLM/SGLANG: 使用华为云 SWR 中的 `cann:8.2.rc1-a3-ubuntu22.04-py3.11` 镜像
  - HK001: 使用 `python:3.11-slim` 镜像 (ARM64 环境)
- **依赖工具**: `modelscope`, `datasets`, `filelock`, `huggingface_hub`, `jq`

### 镜像同步
- **触发方式**: 每小时自动执行，手动触发，代码变更触发
- **同步工具**: 使用 `skopeo` 工具进行镜像同步
- **支持平台**: Docker Hub, Quay.io, 华为云 SWR

## 使用方法

### 1. 配置模型和数据集

#### 对于 VLLM/SGLANG 项目
编辑对应的 `.ini` 配置文件，添加需要同步的模型和数据集名称：

```ini
# 示例配置
model_name_1
model_name_2
```

#### 对于 HK001 集群项目
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

- 2025-12-08: 更新 README，新增 HK001 同步说明，补充镜像同步流向。
- 2025-11-15: 初始版本，包含 VLLM 和 SGLANG 同步。
