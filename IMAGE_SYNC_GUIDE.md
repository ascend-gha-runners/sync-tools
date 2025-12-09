# 镜像地址指引（按项目分类）

本文档按项目分类列出所有可用的容器镜像地址，方便用户根据项目需求找到所需的镜像。

## 1. SGLANG 发行镜像（从 Docker Hub 同步）

SGLANG 镜像发布于 Docker Hub。本项目自动将 **CANN 相关标签** 同步到以下两个仓库，供用户选择。

### 三个可用地址

| 地址 | 说明 | 标签范围 |
|------|------|----------|
| `docker.io/lmsysorg/sglang:[tag]` | Docker Hub 官方源 | 所有官方标签（包括 CANN 标签） |
| `swr.cn-southwest-2.myhuaweicloud.com/base_image/dockerhub/lmsysorg/sglang:[tag]` | 华为云 SWR 西南2 同步仓库 | 仅 **CANN 相关标签**（自动筛选） |
| `quay.io/ascend/sglang:[tag]` | Quay.io Ascend 组织同步仓库 | 仅 **CANN 相关标签**（自动筛选） |

### 使用建议

- **如需所有标签（包括非 CANN 版本）**：请直接使用 Docker Hub 官方地址。
- **如需 CANN 标签版本且位于国内**：使用华为云 SWR 西南2 地址，拉取速度更快。
- **如需 CANN 标签版本且位于公网**：使用 Quay.io 地址。

### 使用示例

```bash
# 从 Docker Hub 拉取
docker pull docker.io/lmsysorg/sglang:[tag]

# 从华为云西南2拉取
docker pull swr.cn-southwest-2.myhuaweicloud.com/base_image/dockerhub/lmsysorg/sglang:[tag]

# 从 Quay.io 拉取
docker pull quay.io/ascend/sglang:[tag]
```

### 注意事项

- 华为云 SWR 和 Quay.io 的镜像仅包含 **CANN 相关标签**，其他标签不会同步。
- 同步频率为每小时一次，新标签可能需要等待同步完成。

## 2. quay.io/ascend 下基础镜像的同步

包括 CANN、PyTorch、Python 等。

### 镜像列表
所有基础镜像均存放在以下两个位置：

#### Quay.io (上游源)
- `quay.io/ascend/cann:[tag]`
- `quay.io/ascend/vllm-ascend:[tag]`
- `quay.io/ascend/manylinux:[tag]`
- `quay.io/ascend/llamafactory:[tag]`
- `quay.io/ascend/triton:[tag]`
- `quay.io/ascend/mindspore:[tag]`
- `quay.io/ascend/python:[tag]`
- `quay.io/ascend/pytorch:[tag]`

#### 华为云 SWR 西南2 (同步副本)
- `swr.cn-southwest-2.myhuaweicloud.com/base_image/ascend-ci/cann/cann:[tag]`
- `swr.cn-southwest-2.myhuaweicloud.com/base_image/ascend-ci/vllm-ascend/vllm-ascend:[tag]`
- `swr.cn-southwest-2.myhuaweicloud.com/base_image/ascend-ci/manylinux/manylinux:[tag]`
- `swr.cn-southwest-2.myhuaweicloud.com/base_image/ascend-ci/llamafactory/llamafactory:[tag]`
- `swr.cn-southwest-2.myhuaweicloud.com/base_image/ascend-ci/triton/triton:[tag]`
- `swr.cn-southwest-2.myhuaweicloud.com/base_image/ascend-ci/mindspore/mindspore:[tag]`
- `swr.cn-southwest-2.myhuaweicloud.com/base_image/ascend-ci/python/python:[tag]`
- `swr.cn-southwest-2.myhuaweicloud.com/base_image/ascend-ci/pytorch/pytorch:[tag]`


### 使用建议
- 内部集群请使用华为云 SWR 地址，拉取速度更快。
- 如需查看标签，可查看 Quay.io 对应仓库的标签列表。

## 3. VERL 镜像

VERL（Vision‑Enhanced Reinforcement Learning）是用于视觉强化学习的专用镜像。

### 可用地址
- **Quay.io (主仓库)**: `quay.io/ascend/verl:[tag]`
- **华为云 SWR 香港 (同步副本)**: `swr.ap-southeast-1.myhuaweicloud.com/base_image/ascend-ci/verl/verl:[tag]`

### 使用示例
```bash
docker pull quay.io/ascend/verl:$tag
docker pull swr.ap-southeast-1.myhuaweicloud.com/base_image/ascend-ci/verl/verl:$tag
```

## 同步状态

所有上述镜像的同步由 [sync-images.yml](.github/workflows/sync-images.yml) 工作流管理，同步频率为每小时一次。如需手动触发，请在 GitHub Actions 页面运行 "Sync Images Between Registries" 工作流。

## 如何查找标签？

### Docker Hub
```bash
curl -s "https://hub.docker.com/v2/repositories/lmsysorg/sglang/tags/" | jq '.results[].name'
```

### Quay.io
Quay.io 的标签列表可通过浏览器访问 `https://quay.io/repository/ascend/<repo>?tab=tags` 查看。

## 常见问题

**Q: 如果某个标签在目标仓库找不到怎么办？**  
A: 可能是同步尚未完成，请等待12:00后再次检查，或手动触发同步。

**Q: 如何请求同步新的镜像？**  
A: 在 `.github/workflows/sync-images.yml` 中添加新的同步任务，并提交 Pull Request。

---

*最后更新: 2025-12-08*