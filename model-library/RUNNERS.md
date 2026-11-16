# 业务对照表：runner 标签 → 集群 → 共享盘

由 `.github/scripts/gen-runner-map.py` 从 ascend-ci-deployment 生成，证据链：**chart nodeSelector 硬落点** > **karmada propagation 组成员** > **argocd dest**；盘位在 `model-library/clusters.json` 的 node_cache。业务只需要看这张表 + 各集群台账 `<cluster>.json`。

## 集群盘位

| 集群 | 节点 cache 别名/claim | 真实 export | 写入口 |
|--|--|--|--|
| aiframe | `vllm-ascend-az5` | `c461cb6e:/` | hb3-ecs 113.46.1.251:/opt/vllm-ci |
| cn12-001 | `vllm-ascend-az5` | `37cbefa6:/ascend-ci-share` | cn12-ecs 113.46.27.144:/mnt/sfs_turbo |
| gy003 | `ascend-ci-share-nv-action-vllm-benchmarks` | `b46afb97:/ascend-ci-share-nv-action-vllm-benchmarks` | TODO(集群侧) |
| gy004 | `ascend-ci-share` | `1b51fb58:/ascend-ci-share-pkking-sglang` | guiyang-ecs 101.245.82.28:/mnt/sfs_turbo2 |
| gy005 | `vllm-ascend-az5` | `b46afb97:/ascend-ci-share-nv-action-vllm-benchmarks` | guiyang-ecs 101.245.82.28:/mnt/sfs_turbo |
| hk001 | `pvc:ascend-ci-share-nv-action-vllm-benchmarks` | `24dd126e:/ascend-ci-share-nv-action-vllm-benchmarks` | hk-ecs 159.138.152.35:/opt/vllm-ci |
| mind3 | `vllm-ascend-az5` | `cc8060b8:/` | mind3-ecs 113.46.31.157:/mnt/sfs_turbo |
| gy001 | `ascend-gha-runners-gy001` | `d561f410:/ascend-ci-share` | （无同步机，O卡集群内下载） |
| wlcb001 | `pvc:vllm-ascend-hk-001` | `fef36441:/ascend-ci-share-nv-action-vllm-benchmarks` | （无同步机，O卡集群内下载） |
| sh001 | `hostPath:/mnt/weight` | 节点权重盘 | （无同步机，O卡集群内下载） |
| sh002 | `pvc:vllm-ascend-share-pvc-test` | 静态 PV（vllm-ascend/config-sh-002） | （无同步机，O卡集群内下载） |

## 无同步机集群：O卡集群内 runner 下载

gy001/wlcb001/sh001/sh002 没有同步 ECS，路由到这些集群的请求由 **ascend-gha-runners org 级 ARC runner** 在集群内执行（`clusters.json` 中 `mode:"arc"`，workflow `download-arc` job 跑 sync-tools 容器，占 O卡节点资源队列，非 NPU 任务也在其上调度）：

| 集群 | 下载 runner 标签（runs-on） | job pod `/root/.cache` ← | 真实落点 |
|--|--|--|--|
| gy001 | `linux-amd64-cpu-2-gy001` | hostPath `/mnt/sfs-local/ascend-gha-runners-gy001` | `d561f410:/ascend-ci-share` |
| wlcb001 | `linux-aarch64-a2-1-wlcb001` | PVC `vllm-ascend-hk-001` | `fef36441:/ascend-ci-share-nv-action-vllm-benchmarks` |
| sh001 | `linux-aarch64-a5-2-sh001` | hostPath `/mnt/weight` | 节点本地权重盘（跨节点不共享！同集群多节点调度时需评估） |
| sh002 | `linux-amd64-a5-2-sh002` | PVC `vllm-ascend-share-pvc-test` | 见 config-sh-002 静态 PV |

- 下载写在 job pod 的 `/root/.cache/huggingface`（=`<盘>/huggingface/hub/…`），与业务 job 容器视角一致，**不需要**再经同步机中转。
- 这些集群均为非 HK 区：endpoint 固定 `hf-mirror.com`，且全局禁 xet（同裸机规则）。
- 需 token 的模型不走流水线：开 issue 联系维护者（见 README"需要 token 的模型"）。

## 仓库 × 机型族 → 落点集群

- **Ascend/Ascend-CI**: `310p`→{gy003}, `a2`→{gy001,hk001,wlcb001}
- **Ascend/cann-container-image**: `cpu`→{cn12-001}
- **Ascend/docs**: `a2`→{gy001,hk001,wlcb001}, `a3`→{cn12-001}
- **Ascend/pytorch**: `a3-800i`→{aiframe,cn12-001,mind3}, `cpu`→{gy005}
- **Ascend/ray-ascend**: `a3`→{gy005}
- **Ascend/sglang**: `a2b3`→{gy001,hk001,wlcb001}, `a3`→{cn12-001}, `a3-800i`→{aiframe,cn12-001,mind3}, `a3-800t`→{gy004}, `cpu`→{gy004}
- **GanDing/Rlinf**: `a2`→{gy001,hk001,wlcb001}, `cpu`→{hk001}
- **TecJesh/triton-ascend**: `a3`→{cn12-001}
- **UsernameFull/transformers-ci**: `a2`→{gy001,hk001,wlcb001}
- **XPU-Forces/mojo_opset**: `a2b3`→{gy001,hk001,wlcb001}, `a3-800i`→{aiframe,cn12-001,mind3}
- **alibaba/ROLL**: `a3-800i`→{aiframe,cn12-001,mind3}
- **areal-project/AReaL**: `a3-800i`→{aiframe,cn12-001,mind3}
- **ascend-gha-runners/pytorch**: `cpu`→{aiframe}
- **ascend-gha-runners/sgl-kernel-npu**: `a2`→{gy001,hk001,wlcb001}, `a3`→{cn12-001,gy004}, `npu`→{gy004}
- **ascend-gha-runners/sglang_public**: `a3-0-sgl`→{cn12-001}, `a3-16-sgl`→{cn12-001}, `a3-2-sgl`→{cn12-001}, `a3-4-sgl`→{cn12-001}, `a3-8-sgl`→{cn12-001}
- **ascend-gha-runners/sync-tools**: `sglang-a2`→{gy001,hk001,wlcb001}, `sglang-a3`→{gy004}, `verl-a3`→{mind3}, `vllm-a2`→{gy001,hk001,wlcb001}, `vllm-a3`→{gy005}
- **ascend-gha-runners/vllm-ascend**: `a2`→{gy001,hk001,wlcb001}, `a3`→{gy005}, `a3-test`→{cn12-001}
- **fla-org/flash-linear-attention**: `a2`→{gy001,hk001,wlcb001}
- **gaoyuanyuanqiqi/TorchTurbo**: `a3-800i`→{aiframe,cn12-001,mind3}
- **hiyouga/LLaMA-Factory**: `a2`→{gy001,hk001,wlcb001}
- **modelscope/ms-swift**: `a2`→{gy001,hk001,wlcb001}
- **nv-action/vllm-benchmarks**: `310p`→{gy003}, `910b`→{gy001,hk001,wlcb001}, `a2`→{gy001,hk001,wlcb001}, `a2b1`→{gy001}, `a2b3`→{gy001,hk001,wlcb001}, `a2b3-v-half`→{gy001,hk001,wlcb001}, `a2b3-v-quarter`→{gy001,hk001,wlcb001}, `a2b4`→{gy001}, `a3`→{cn12-001}, `a3-800i`→{aiframe,cn12-001,mind3}, `a3-800t`→{cn12-001,gy004,gy005}, `cpu`→{gy005}, `cpu-16-hk`→{hk001}, `cpu-2-hk`→{hk001}, `cpu-32-hk`→{hk001}, `cpu-4-hk`→{hk001}, `cpu-8-hk`→{hk001}, `nightly-310p`→{gy003}, `nightly-a2b3`→{gy001,hk001,wlcb001}, `nightly-a3`→{gy005}
- **pt-ecosystem/flash-linear-attention**: `a2`→{gy001,hk001,wlcb001}
- **sgl-project/sgl-kernel-npu**: `a2`→{gy001,hk001,wlcb001}, `a3`→{cn12-001}, `a3-800i`→{aiframe,cn12-001,mind3}, `a3-800t`→{gy004}
- **sgl-project/sglang**: `a2`→{gy001,hk001,wlcb001}, `a3`→{cn12-001,gy004}, `a3-800t`→{gy004}, `a3-800t-test`→{gy004}, `a3-test`→{cn12-001}, `cpu`→{gy004}
- **sgl-project/sglang-omni**: `a2`→{gy001,hk001,wlcb001}
- **tile-ai/tilelang-mlir-ascend**: `a3-800i`→{aiframe,cn12-001,mind3}
- **triton-lang/triton-ascend**: `a2b1`→{gy001}, `a3-800i`→{aiframe,cn12-001,mind3}, `cpu`→{gy005}, `cpu-16-hk`→{hk001}, `cpu-2-hk`→{hk001}, `cpu-4-buildkit`→{cn12-001}, `cpu-4-hk`→{hk001}, `cpu-8-hk`→{hk001}
- **vllm-ascend-ci-dev/vllm-ascend**: `310p`→{gy003}, `a2`→{gy001,hk001,wlcb001}, `a3`→{gy005}
- **vllm-ascend/main2main-automator**: `a2b3`→{gy001,hk001,wlcb001}
- **vllm-ascend/vllm-ascend-kimi-k3**: `a2b3`→{gy001,hk001,wlcb001}, `a3`→{gy005}, `cpu-2-hk`→{hk001}, `cpu-8-hk`→{hk001}
- **vllm-ascend/vllm-ascend-recipes**: `a2b4`→{gy001}, `a3-800i`→{aiframe,cn12-001,mind3}
- **vllm-project/vllm-ascend**: `310p`→{gy003}, `910b`→{gy001,hk001,szlab,wlcb001}, `a2`→{gy001,hk001,wlcb001}, `a2b1`→{gy001}, `a2b1b3`→{gy001,hk001,wlcb001}, `a2b1b3-test`→{gy001,hk001,wlcb001}, `a2b3`→{gy001,hk001,wlcb001}, `a2b4`→{gy001}, `a3`→{cn12-001}, `a3-800i`→{aiframe,cn12-001,mind3}, `a3-800i-test`→{aiframe,cn12-001,mind3}, `a3-800t`→{cn12-001,gy004,gy005}, `a3-800t-test`→{gy005}, `a3-test-16-gy005`→{gy005}, `cpu`→{cn12-001,gy005}, `cpu-16-hk`→{hk001}, `cpu-2-hk`→{hk001}, `cpu-32-hk`→{hk001}, `cpu-4-hk`→{hk001}, `cpu-8-hk`→{hk001}, `nightly-a3`→{gy005}
- **vllm-project/vllm-omni**: `310p`→{gy003}, `a2b3`→{gy001,hk001,wlcb001}, `a3`→{cn12-001}, `a3-offload`→{cn12-001}, `a3-offload-test`→{cn12-001}
- **volcengine/uni-agent**: `a2`→{gy001,hk001,wlcb001}
- **volcengine/verl**: `a2`→{gy001,hk001,wlcb001}, `a3-800i`→{aiframe,cn12-001,mind3}, `a3-800i-16-memclean`→{aiframe,cn12-001,mind3}, `a3-800i-test`→{aiframe,cn12-001,mind3}
- **volcengine/verl-SpeCo**: `a2`→{gy001,hk001,wlcb001}
- **volcengine/verl-omni**: `a2b4`→{gy001}
- **xuedinge233/triton-ascend**: `cpu`→{gy005}

## 模型在容器里的最终路径

流水线只负责"写到哪块盘"；业务 job 容器里能不能看到，由该仓库自己的 job 模板决定（ascend-ci-deployment）。规则一共三层：

1. **容器内挂载点**：几乎所有 job 模板把 cache 卷整盘挂到 `/root/.cache`（个别 ARC runner，如 `triton-lang/triton-ascend` 的部分模板，是 `/home/runner/.cache`）。
2. **SDK 目录布局**（相对容器挂载点）：
   - huggingface：`huggingface/hub/models--<org>--<model>/snapshots/<revision>/`（`HF_HOME=<挂载点>/huggingface` 时；CI 里 `HF_HUB_OFFLINE=1` 直接离线读）
   - datasets：`huggingface/datasets/`
   - modelscope（1.37 布局）：`modelscope/hub/models/<org>/<model>/`
3. **`/root/.cache` 对应哪块物理盘**：看 configmap 里 volume 是 hostPath `/mnt/sfs-local/<alias>` 还是 PVC `claimName`，alias→真实盘查 `argocd/clusters/<c>/sfs-local-provisioner.yaml`（share-id + `everest.io/path`）。**不同盘的同名目录互不等价**——HK 区 `ascend-ci-share` 在 `24dd126e` 和 `d5b643e2` 上各有一个。

### 各集群容器视角 ← 真实盘（证据：sfs-local-provisioner.yaml 全量解析）

| 集群 | 容器 `/root/.cache` = | 该集群别名盘分布 | 同步机默认写入口一致？ |
|--|--|--|--|
| cn12-001 | `37cbefa6:/ascend-ci-share` | 14 个别名全同盘 ✓ | ✓ `cn12-ecs:/mnt/sfs_turbo/ascend-ci-share` |
| aiframe | `c461cb6e:/` | 9 个别名全同盘 ✓ | ✓ `hb3-ecs:/opt/vllm-ci` |
| mind3 | `cc8060b8:/` | 统一，仅 `verl-hb003`→`a8317f79:/ascend-ci-share` 例外 | ✓ `mind3-ecs:/mnt/sfs_turbo` |
| gy004 | `1b51fb58:/ascend-ci-share-pkking-sglang` | 单盘 ✓ | ✓ `guiyang-ecs:/mnt/sfs_turbo2/ascend-ci-share-pkking-sglang` |
| gy005 | `b46afb97:/ascend-ci-share-nv-action-vllm-benchmarks` | 3 个别名全同盘 ✓ | ✓ `guiyang-ecs:/mnt/sfs_turbo/ascend-ci-share-nv-action-vllm-benchmarks` |
| gy001 | `d561f410:/ascend-ci-share` | 单盘 ✓ | 无同步机（线下交付 ARC） |
| **hk001** | **一分为三**，见下表 | ⚠️ 唯一分裂集群 | 默认只写 `24dd126e:/ascend-ci-share`，覆盖不了 uni-agent 系 |

### hk001 的三块分盘（给 uni-agent 们下模型前必读）

| 容器 `/root/.cache` ← | 真实位置 | 同步机写路径 | 谁在用 |
|--|--|--|--|
| `24dd126e:/ascend-ci-share` | 盘 24dd126e | hk-ecs `/opt/vllm-ci/ascend-ci-share`（**流水线默认**） | fla-org/flash-linear-attention（alias `fla-org-flash-linear-attention-a2-hk-001`，bindFrom `ganding-rlinf-a2-hk-001`） |
| `d5b643e2:/ascend-ci-share` | 盘 d5b643e2 | hk-ecs `/mnt/d5b643e2/ascend-ci-share` | volcengine/uni-agent（`verl-uni-agent-hk001`）、volcengine/verl-SpeCo（`verl-verl-speco-hk001`）、hiyouga/LLaMA-Factory 与 modelscope/ms-swift（`hk001-v1`） |
| `24dd126e:/ascend-ci-share-nv-action-vllm-benchmarks` | 盘 24dd126e | hk-ecs `/opt/vllm-ci/ascend-ci-share-nv-action-vllm-benchmarks` | nv-action/vllm-benchmarks 系（alias `ascend-ci-share-nv-action-vllm-benchmarks`） |

### 实例（#103：uni-agent 要 Qwen/Qwen3-0.6B）

| 视角 | 路径 |
|--|--|
| 容器内 | `/root/.cache/huggingface/hub/models--Qwen--Qwen3-0.6B/snapshots/c1899de289a04d12100db370d81485cdf75e47ca/model.safetensors` |
| 共享盘 | `d5b643e2:/ascend-ci-share/huggingface/hub/models--Qwen--Qwen3-0.6B/…`（**不是** 24dd126e 上的同名目录） |
| 同步机 | hk-ecs `159.138.152.35:/mnt/d5b643e2/ascend-ci-share/huggingface/hub/…` |

### 新仓库自查两连

```bash
# ① 该 repo job 模板里 /root/.cache 挂的是哪个卷（hostPath alias 或 PVC）
grep -B8 -A4 "mountPath: /root/.cache" <ci-deployment>/projects/<org>/<repo>/**/*configmap*.yaml
# ② alias → 真实盘（share-id + export）
grep -A14 "name: <alias>:" <ci-deployment>/argocd/clusters/<cluster>/sfs-local-provisioner.yaml | grep -E "share-id|everest.io/path|bindFrom"
```

> 待办：`gen-runner-map.py` 把上面两层自动进 `runner-map.json`（repo→cache 卷→写路径），下载 job 按 repo 选盘后，本节的"同步机默认写入口一致？"列将全部为 ✓。
