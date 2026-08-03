# 00 — 设计总览（v6）

## 核心目标

**用声明式配置 + 统一工具，替代 76+ 个项目各自手写的 process_version.sh 和 lib.sh**

## 关键约束

1. **process_version.sh 流程强制统一** — 所有项目遵循相同处理流程，不允许例外
2. **去掉 ci.sh** — process_version.sh 是唯一入口
3. **latest tag 逻辑** — 只在版本 >= processed_versions.txt 最新版本时更新
4. **并行由 GitHub 触发** — 用户通过多个 workflow 并行触发，工具不关心并行度
5. **暂不考虑依赖处理**
6. **processed_versions.txt** — 仍存储在仓库内，更新后提交，处理并发冲突

## 架构

```
tools/
├── lib.sh              ← 共享函数
├── process_version.sh  ← 统一入口（所有项目共用）
└── parse_config.py     ← config.yml 解析

library/ruby/
├── config.yml          ← 声明式配置（唯一配置文件）
├── processed_versions.txt
└── template/
    ├── Dockerfile-forky.template
    ├── Dockerfile-slim-forky.template
    ├── Dockerfile-alpine.template
    └── 4.0.6/
        ├── forky/Dockerfile
        ├── slim-forky/Dockerfile
        └── alpine/Dockerfile
```

## 调用方式

```bash
# 构建所有新版本
./tools/process_version.sh library/ruby

# 构建特定版本
./tools/process_version.sh library/ruby 4.0.6

# dry run
DRY_RUN=true ./tools/process_version.sh library/ruby
```

## GitHub Actions 触发

```yaml
# .github/workflows/library-ruby.yml
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
      - name: Build
        run: ./tools/process_version.sh library/ruby
```

多个 workflow 并行触发，每个 workflow 处理一个项目。

## 文档索引

| 文件 | 内容 | 版本 |
|------|------|------|
| 01-declarative-config.md | config.yml 结构 | v6 |
| 02-template-standardization.md | 模板目录结构统一规范 | v6 |
| 03-unified-tools.md | 统一工具设计 | v6 |
| 04-git-merge-strategy.md | processed_versions.txt 并发处理 | v6 |
| 06-architecture.md | 整体架构 | v6 |
