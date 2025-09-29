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

## 项目结构

```
.github/
└── workflows/
    ├── config/                           # 配置文件目录
    │   ├── vllm-downloaded-models.ini    # VLLM 模型同步配置
    │   ├── vllm-downloaded-datasets.ini  # VLLM 数据集同步配置
    │   ├── sglang-downloaded-models.ini  # SGLANG 模型同步配置
    │   └── sglang-downloaded-datasets.ini # SGLANG 数据集同步配置
    ├── vllm-sync-models-datasets.yml     # VLLM 同步工作流
    ├── sglang-innersourse-sync-models-datasets.yml  # SGLANG 内源同步
    ├── sglang-opensourse-sync-models-datasets.yml   # SGLANG 开源同步
    └── sync-images.yml                   # 镜像同步工作流
```

## 工作流配置

### 模型数据集同步
- **触发方式**: 每 6 小时自动执行，手动触发，文件变更触发
- **执行环境**: 使用华为云 SWR 中的 `cann:8.2.rc1-a3-ubuntu22.04-py3.11` 镜像
- **依赖工具**: `modelscope`, `datasets`, `filelock`

### 镜像同步
- **触发方式**: 每小时自动执行，手动触发，代码变更触发
- **同步工具**: 使用 `skopeo` 工具进行镜像同步

## 使用方法

### 1. 配置模型和数据集
编辑对应的 `.ini` 配置文件，添加需要同步的模型和数据集名称：

```ini
# 示例配置
model_name_1
model_name_2

