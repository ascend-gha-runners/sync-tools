# 同步工具 (sync-tools) 说明

## 1. 模型数据集同步

### Runner 分配策略

**VLLM 项目使用一个 Runner：**
因为两个集群共用一个共享盘，因此只需要一个runner同步一次即可

**SGLANG 项目分配两个 Runner：linux-amd64-vllm-guiyang003**

- 一个 Runner 负责内源 **华东 001 集群** 的模型和数据集同步
- 另一个 Runner 负责开源 **贵阳 004 集群** 的模型和数据集同步

> 这两个 Runner **共用同一份** 配置文件 (`sglang-downloaded-datasets.ini`, `sglang-downloaded-models.ini`)

### 目录结构

```bash
.github/
└── workflows/
    ├── config/                    # 配置文件目录
    │   ├── vllm-model.ini        # VLLM 模型同步配置文件（003/005集群共用）
    │   ├── vllm-dataset.ini      # VLLM 数据集同步配置文件（003/005集群共用）
    │   ├── sglang-model.ini      # SGLANG 模型同步配置文件（001/004集群共用）
    │   └── sglang-dataset.ini    # SGLANG 数据集同步配置文件（001/004集群共用）
    ├── vllm-sync-003.yml         # 贵阳 003 集群同步工作流定义（005同步也随之生效）
    ├── sglang-sync-001.yml       # 华东 001 集群同步工作流定义
    └── sglang-sync-004.yml       # 贵阳 004 集群同步工作流定义
```

## 2. 镜像同步

### 同步流向 1：西南区 -> Quay.io

- **源仓库：** `quay.io/ascend/`
- **目标仓库：** `swr.cn-southwest-2.myhuaweicloud.com/base_image/ascend-ci/`
- **同步分支/仓库列表：**

### 同步流向 2：东南亚区 -> 华东区

- **源仓库：** `swr.ap-southeast-1.myhuaweicloud.com/base_image/ascend-ci/sglang`
- **目标仓库：** `swr.cn-east-4.myhuaweicloud.com/base_image/ascend-ci/sglang`
- **同步分支/仓库列表：**

