# 06 — 整体架构（v6.7）

## 目标架构

```
tools/                              ← 1 套统一工具
├── lib.sh                          ← 共享函数
└── process_version.sh              ← 统一入口

library/                            ← 项目目录
├── ruby/
│   ├── AGENTS.md                   ← AI agent 上下文
│   ├── config.yml                  ← 声明式配置
│   ├── processed_versions.txt      ← 版本跟踪
│   ├── fetch_versions.sh           ← 自定义版本脚本（可选）
│   └── template/
│       ├── update.sh               ← 项目专属
│       ├── apply-templates.sh      ← 项目专属
│       ├── Dockerfile-forky.template
│       ├── Dockerfile-slim-forky.template
│       ├── Dockerfile-alpine.template
│       └── 4.0.6/
│           ├── forky/Dockerfile
│           ├── slim-forky/Dockerfile
│           └── alpine/Dockerfile
│
└── ...

.github/workflows/                  ← 每个项目一个 workflow
├── library-ruby.yml
└── ...
```

## 关键约束

1. **process_version.sh 流程强制统一**
2. **每次 CI 只执行一个版本**
3. **latest tag 逻辑** — 只在版本 >= processed_versions.txt 最新版本时更新
4. **使用 buildx 构建** — `--platform linux/loong64`
5. **并行由 GitHub 触发**
6. **processed_versions.txt** — 存储在仓库内，更新后提交，处理并发冲突
7. **每个项目有 AGENTS.md** — 为 AI agent 提供上下文

## 调用方式

```bash
./tools/process_version.sh library/ruby
```

## GitHub Actions Workflow

```yaml
name: 'library::ruby'

on:
  schedule:
    - cron: '0 18 * * *'
  workflow_dispatch:

jobs:
  build:
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v3

      - name: Login to Registry
        uses: docker/login-action@v3
        with:
          registry: lcr.loongnix.cn
          username: ${{ secrets.REGISTRY_USER }}
          password: ${{ secrets.REGISTRY_PASS }}

      - name: Build and Push
        run: ./tools/process_version.sh library/ruby
```

## 数据流

```
process_version.sh library/ruby
    │
    ├──→ fetch_versions.sh → 最新版本
    │
    ├──→ 检查 processed_versions.txt
    │
    ├──→ update.sh <version> → variables.json
    │
    ├──→ apply-templates.sh <version> → Dockerfile
    │
    ├──→ docker buildx build --platform linux/loong64
    │
    └──→ git commit processed_versions.txt
```
