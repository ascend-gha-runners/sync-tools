# 业务对照表：runner 标签 → 集群 → 共享盘

由 `.github/scripts/gen-runner-map.py` 从 ascend-ci-deployment 生成，证据链三级：**chart nodeSelector 硬落点**（如 `liqo.io/remote-cluster-id: gy005`）> **karmada propagation 组成员**（prod-cp-a3-800i: cn12-001/aiframework/mind-third-ci）> **argocd dest**。集群盘位来自节点 mount 表 + PV csi 实证。勿手改。

## 集群盘位（cache 别名 → 真实 export → 写入口）

| 集群 | 别名/claim | 真实 export | 机器写入口 |
|--|--|--|--|
| aiframe | `vllm-ascend-az5` | `c461cb6e:/` | hb3-ecs 113.46.1.251:/opt/vllm-ci |
| cn12-001 | `vllm-ascend-az5` | `37cbefa6:/ascend-ci-share` | cn12-ecs 113.46.27.144:/mnt/sfs_turbo |
| gy003 | `ascend-ci-share-nv-action-vllm-benchmarks` | `b46afb97:/ascend-ci-share-nv-action-vllm-benchmarks` | TODO(集群侧) |
| gy004 | `ascend-ci-share` | `1b51fb58:/ascend-ci-share-pkking-sglang` | guiyang-ecs 101.245.82.28:/mnt/sfs_turbo2 |
| gy005 | `vllm-ascend-az5` | `b46afb97:/ascend-ci-share-nv-action-vllm-benchmarks` | guiyang-ecs 101.245.82.28:/mnt/sfs_turbo |
| hk001 | `pvc:ascend-ci-share-nv-action-vllm-benchmarks` | `24dd126e:/ascend-ci-share-nv-action-vllm-benchmarks` | hk-ecs 159.138.152.35:/opt/vllm-ci |
| mind3 | `vllm-ascend-az5` | `cc8060b8:/` | mind3-ecs 113.46.31.157:/mnt/sfs_turbo |
| wlcb001 | `pvc:vllm-ascend-a2-fed-cache` | `fef36441:/ascend-ci-share-nv-action-vllm-benchmarks` | TODO(集群内 pod) |

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
