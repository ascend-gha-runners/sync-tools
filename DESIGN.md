# sync-tools 功能设计文档

> 本文档描述 `sync-tools` 仓库的设计目标、整体架构、各子系统的工作原理与关键设计取舍。
> 面向维护者与新加入的同学，回答“它是怎么工作的、为什么这么设计”；
> 面向用户的“如何配置/使用”请见 [README.md](README.md)。

## 1. 背景与目标

昇腾（Ascend）生态的镜像、模型与数据集主要发布在境外或公网 registry（如 `quay.io/ascend`、Docker Hub、HuggingFace、ModelScope）。国内用户与各 NPU 集群直接访问这些源存在网络慢、限速、偶发不可达等问题。

`sync-tools` 的目标是用一套**配置驱动、自动化、幂等**的 GitHub Actions 流水线，把这些资源就近搬运到用户可快速访问的位置：

- **镜像**：从主发布源同步到多个目标 registry（华为云 SWR 各区域、Docker Hub 镜像账号等）。
- **模型 / 数据集**：按项目同步到该项目关联的一个或多个 NPU 集群（ARC self-hosted runner）。
- **仓库 README**：把上游 README 推送到 Docker Hub / Quay.io 对应镜像仓库的描述页。

设计上贯穿三条原则：

1. **配置即数据**：新增同步项是改 JSON，不是改流程代码或新增 workflow（self-serve）。
2. **幂等与省流**：每次同步前做内容比对（digest / sha256），未变化即跳过，不刷新目标更新时间、不浪费带宽与配额。
3. **声明式凭证映射**：根据 registry 域名自动选择认证信息，配置里不出现任何密钥。

## 2. 系统总览

仓库本身没有常驻服务，全部能力由 GitHub Actions workflow + 配置文件 + 少量脚本构成。三大业务流水线相互独立、可单独触发：

```
                     ┌─────────────────────────────────────────────┐
                     │              配置文件（数据层）               │
                     │  image-sync.json   readme-sync.json          │
                     │  projects-clusters.json  projects/<name>.json│
                     └─────────────────────────────────────────────┘
                                       │ 读取
        ┌──────────────────────────────┼──────────────────────────────┐
        ▼                              ▼                              ▼
┌────────────────┐           ┌────────────────────┐         ┌────────────────┐
│ sync-images    │           │ sync-models-       │         │ sync-readmes   │
│ .yml (skopeo)  │           │ datasets.yml       │         │ .yml(pushrm)   │
│ 镜像跨 registry │           │ 模型/数据集→集群    │         │ README→仓库描述 │
└────────────────┘           └────────────────────┘         └────────────────┘
        │                              │                              │
        ▼                              ▼                              ▼
  目标 registry              ARC runner 持久化 cache          Docker Hub / Quay
```

支撑组件：

- **`sync-tools` 容器镜像**：模型/数据集同步任务的运行环境，预装 `jq`、`huggingface_hub`、`modelscope`、`datasets`、`filelock`，双架构（amd64 + arm64）。由 `build-sync-tools-image.yml` 手动构建并推送到 SWR。
- **辅助脚本**：`build-sync-matrix.sh`（决定跑哪些项目×集群）、`download-json-models.sh`（实际下载逻辑）。

### 目录结构

```
.github/
├── docker/sync-tools/Dockerfile          # 模型/数据集同步任务的运行镜像
├── scripts/
│   ├── build-sync-matrix.sh              # 按触发事件展开 project×cluster 矩阵
│   ├── download-json-models.sh           # HuggingFace / ModelScope 下载逻辑
│   └── quay_md_adapt.py                  # README 同步的 Quay 描述适配
└── workflows/
    ├── config/                           # 全部配置（数据层）
    │   ├── image-sync.json               # 镜像同步：src→dest 列表
    │   ├── readme-sync.json              # README 同步：src→dest 列表
    │   ├── projects-clusters.json        # 项目→集群映射（唯一总表）
    │   └── projects/<name>.json          # 每个项目的 models/datasets 合并配置
    ├── sync-images.yml                   # 镜像同步流水线
    ├── sync-models-datasets.yml          # 模型/数据集同步流水线
    ├── sync-readmes.yml                  # README 同步流水线
    ├── build-sync-tools-image.yml        # 构建/推送 sync-tools 镜像
    ├── verify-digest.yml / test.yml      # 校验与配置自检
    └── oneoff-sync-*.yml                 # 一次性大规模迁移用的临时 workflow
```

## 3. 镜像同步子系统（sync-images.yml）

### 3.1 数据模型

`image-sync.json` 是一个扁平数组，每条记录声明“一个源到一个目标”：

```json
{ "src": "quay.io/ascend/cann", "dest": "docker.io/ascendai/cann" }
```

- 同一个 `src` 可以出现多次，对应同步到多个 `dest`。
- 可选 `tag_filter`：只同步名字匹配关键词（不区分大小写）的 tag，例如 sglang 只同步含 `cann` 的 tag。同一个 `src` 的多条记录应保持一致的 `tag_filter`（实现里取该 src 的第一个）。

### 3.2 执行流程

1. **prepare job**：对 `image-sync.json` 的 `src` 去重，生成 `[{src}]` 矩阵。**以 src 为并行单元**，让同一镜像的所有 dest 复用同一次 tag 列表与源 inspect 结果。
2. **sync job**（矩阵并行，`fail-fast: false`）：运行在 `quay.io/skopeo/stable` 容器内。
   - **取 tag 列表**：默认 `skopeo list-tags`；带 `tag_filter` 时改走 Docker Hub Registry v2 分页 API 过滤（最多 20 页）。
   - **逐 dest、逐 tag 比对再同步**，用 `skopeo copy --all`（多架构）带重试。

### 3.3 关键设计：内容寻址的 digest 比对

幂等是这条流水线的核心。直接比顶层 manifest digest 不可靠——Docker Hub 会重新序列化 manifest list，导致顶层 digest 与源不一致而误判“有变化”。

因此 `get_manifest_id()` 比对的是**子 manifest 的 digest 列表**（content-addressed，跨 registry 稳定）：

```
manifest list → 取所有 .manifests[].digest，排序后 join
单 manifest    → 取 .config.digest
```

源与目标的该标识相同即跳过，不会刷新目标 registry 的更新时间。

### 3.4 Docker Hub 的特殊处理与缓存

- **digest 缓存**：对 `docker.io/*` 目标，每个 tag 的源标识写入 `actions/cache`（key 按 src 分片）。比对优先读缓存，避免对 Docker Hub 做大量 inspect 请求触发限速。命中缓存或同步成功后都会刷新缓存，保证缓存文件完整。
- **限速观测**：每个 docker.io dest 同步完后查询并打印 Docker Hub 剩余 rate limit，便于排查“同步变慢/失败”是否因配额耗尽。

### 3.5 凭证映射

`get_creds()` 按 `src`/`dest` 域名前缀匹配对应的 user/secret（quay.io、docker.io、SWR 西南/东北三/香港等），无匹配则匿名（`--no-creds`）。**配置文件里只有域名，密钥全部来自 repo secrets/vars**。

### 3.6 触发

每小时定时 + 手动 `workflow_dispatch`。`copy` 退出码 0 或 2 视为成功；任一 dest 有失败 tag，则该 job 以失败结束（保留其他 dest 已完成的进度）。

## 4. 模型 / 数据集同步子系统（sync-models-datasets.yml）

这是最能体现 **self-serve** 设计的子系统：**新增一个项目只需 2 个文件改动，不新增任何 workflow**。

### 4.1 数据模型

- **`projects-clusters.json`**：唯一的项目→集群映射总表。
  ```json
  { "vllm": { "clusters": ["linux-amd64-vllm-a2", "linux-amd64-vllm-a3"] } }
  ```
  `clusters` 里的字符串就是目标 ARC runner 的 label，也是同步任务实际运行的位置。
- **`projects/<name>.json`**：该项目要同步的资源，`models` 与 `datasets` 合并在一份文件里。
  ```json
  {
    "models":   [ { "platform": "modelscope",  "organization": "Qwen",   "model_name": "Qwen2.5-7B-Instruct" } ],
    "datasets": [ { "platform": "huggingface", "organization": "openai", "dataset_name": "gsm8k", "local_dir": "/root/.cache/custom" } ]
  }
  ```
  `local_dir` 可选，缺省时走 SDK 默认 cache。任一数组为空都允许，对应类型被跳过。

### 4.2 矩阵展开与“只跑变更项目”

`build-sync-matrix.sh` 把“跑哪些项目”与“项目对应哪些集群”解耦，按触发事件决定项目集合：

| 触发事件 | 选中的项目 |
|---|---|
| `schedule`（每 6 小时） | 全部项目（全量保险） |
| `workflow_dispatch` | 输入的 `project`，留空=全部；非法名直接报错退出 |
| `push` 到 main | 仅**发生变更**的项目 |

push 的变更判定（精细化，避免无谓全量）：

- 改了 `projects/<name>.json` → 选中该项目；
- 改了 `projects-clusters.json` → 用 `jq` 逐项目 diff `clusters` 数组，**只选 clusters 真正变化的项目**（新增集群、改集群才跑，纯格式改动不触发）；
- 改了 workflow 自身或 matrix 脚本 → 全量跑（兜底，因为行为可能整体改变）。

最终展开为 `[{project, cluster}, ...]` 笛卡尔积矩阵；为空则 `sync` job 被 `if` 跳过。

### 4.3 下载执行

`sync` job 跑在 `matrix.cluster` 指定的 runner 上、`sync-tools` 容器内：

1. 用 `jq` 把项目配置拆成 `/tmp/models.json` 与 `/tmp/datasets.json`；
2. 非空则调用 `download-json-models.sh`，按 `platform` 分派：
   - **modelscope**：`modelscope download --model|--dataset org/name [--local_dir ...]`；
   - **huggingface**：默认 `HF_ENDPOINT=https://hf-mirror.com`（国内镜像），模型用 `snapshot_download`，数据集用 `hf download --repo-type=dataset`。

单条资源下载失败只打印 WARNING 不中断整批（最大化单次运行的同步覆盖面）。

### 4.4 关键设计：持久化 cache 实现跨任务免重复下载

ARC runner pod 在 `/root/.cache` 挂载了持久化卷。模型/数据集默认就下到 SDK 的标准 cache 路径（`~/.cache/huggingface`、`~/.cache/modelscope`）下，因此**相同 revision 跨任务保留，不会重复下载**。这也是 `local_dir` 默认留空、交给 SDK 自管 cache 的原因——既复用持久化卷，又拿到 SDK 自带的 revision 级幂等。

## 5. README 同步子系统（sync-readmes.yml）

把上游 README 推送到镜像仓库的描述页，让 Docker Hub / Quay 上的仓库有内容。

### 5.1 数据模型与流程

`readme-sync.json` 每条声明 `src`（可公开访问的 README 原文 URL）→ `dest`（`docker.io/*` 或 `quay.io/*`）。流程：下载 README → 计算 sha256 → 与缓存比对，未变化跳过 → 用 [docker-pushrm](https://github.com/christian-korneck/docker-pushrm) 调各 registry 描述更新 API。

### 5.2 两个针对性设计

- **绕过 gitcode 反爬**：`raw.gitcode.com` 的 CDN 对 GHA runner IP 段返回 418，但 git 协议不拦截。`download_readme()` 用正则把 raw URL 还原成仓库地址，用 `git clone --depth=1 --filter=blob:none --no-checkout` + `checkout HEAD -- <path>` 稀疏拉取单文件；非 gitcode 的 URL 走普通 `curl`。
- **Quay 凭证回退**：Quay 描述 API 需要 repo admin。默认复用 `QUAY_ASCEND_PWD`；若机器人账号权限不足，可在 secrets 配 `QUAY_API_KEY`（OAuth token），工作流优先使用它。

### 5.3 触发

每日 06:17 UTC 定时 + 手动 + `readme-sync.json` 变更时自动触发。

## 6. 运行镜像（sync-tools image）

模型/数据集同步任务统一跑在 `swr.cn-southwest-2.myhuaweicloud.com/base_image/ascend-ci/sync-tools:latest`，基于 `python:3.11-slim`，预装 `jq/git/curl` 与 `filelock/modelscope/datasets/huggingface_hub[cli]`，pip 走华为云镜像源。`build-sync-tools-image.yml` 用 buildx 多架构（amd64+arm64）构建并推送到 SWR，**仅手动触发**。

> ⚠️ Dockerfile 改动后必须手动重跑构建 workflow，否则同步任务仍用旧镜像。

## 7. 跨子系统的设计取舍

| 主题 | 取舍 | 理由 |
|---|---|---|
| 配置 vs 代码 | 全部用 JSON 配置 + 通用 workflow | self-serve，新增项无需懂 Actions、无需 review 流程逻辑 |
| 幂等粒度 | 镜像比子 manifest digest；README 比 sha256；模型靠 SDK revision cache | 内容寻址，跨 registry/跨任务稳定，避免无谓写入与下载 |
| 并行单元 | 镜像按 src、模型按 project×cluster | 复用 inspect / tag 列表；集群间互不阻塞 |
| 失败处理 | `fail-fast: false`，单条失败不拖垮整批 | 最大化单次运行的同步覆盖面 |
| 凭证 | 域名→secret 自动映射 | 配置零密钥，新增目标 registry 才需补凭证 |
| 触发 | 定时全量 + push 增量 + 手动 | 定时兜底一致性，push 快速生效，手动便于排障/补同步 |

## 8. 扩展指引（速查）

- **加一条镜像同步**：在 `image-sync.json` 加 `{src, dest}`；目标域名是新 registry 时，补 `get_creds()` 分支与对应 secrets。
- **加一个模型/数据集项目**：① `projects-clusters.json` 加项目→集群映射；② 新建 `projects/<name>.json`。push 到 main 自动触发，无需新 workflow。
- **给项目加集群**：在 `projects-clusters.json` 对应项目的 `clusters` 数组追加 runner label。
- **加一条 README 同步**：在 `readme-sync.json` 加 `{src, dest}`。
- **改运行环境**：改 `Dockerfile` 后手动跑 `build-sync-tools-image.yml`。

## 9. 故障排查要点

- **镜像同步慢/失败**：先看日志里的 Docker Hub rate limit 剩余量；可调 `skopeo` 重试参数。
- **digest 一直判定有变化**：确认比对的是子 manifest digest 列表而非顶层 digest。
- **模型下载失败**：核对 `organization/name` 与平台、访问权限；HuggingFace 走 `hf-mirror.com`。
- **README 推送 418 / 权限错误**：gitcode 源已走 git 回退；Quay 需确认 `QUAY_API_KEY` 或机器人账号 admin 权限。
- **push 后没触发预期项目**：核对改动是否命中 `paths` 过滤，以及 `clusters` 是否真的发生变化。
