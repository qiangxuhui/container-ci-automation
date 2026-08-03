# 01 — 声明式配置设计（v6.6）

## 关键约束

**每次 CI 只执行一个版本** — fetch_versions.sh 只输出最新版本（1 行）。
是否执行由 process_version.sh 决定。

## 版本获取方式

### GitHub releases（标准）

```yaml
version_source:
  type: github_releases
  repository: "ruby/ruby"
  tag_regex: "^v([0-9]+\.[0-9]+\.[0-9]+)$"
```

### 自定义脚本

```yaml
version_source:
  type: script
  script: fetch_versions.sh
```

## fetch_versions.sh 示例

```bash
#!/bin/bash
# 只输出最新版本号（1 行）

# GitHub releases
gh api repos/ruby/ruby/releases/latest --jq '.tag_name' | sed 's/^v//'

# Docker Hub
# curl -s "https://hub.docker.com/v2/repositories/library/nginx/tags/?page_size=1" | \
#     jq -r '.results[0].name'
```

## 流程

```
process_version.sh library/ruby
    │
    ├──→ fetch_versions.sh → "4.0.6"（1 行）
    │
    ├──→ grep "4.0.6" processed_versions.txt
    │       │
    │       ├── 存在 → "already built, skipping"
    │       │
    │       └── 不存在 → 继续构建
    │
    ├──→ update.sh 4.0.6 → variables.json
    │
    ├──→ apply-templates.sh 4.0.6 → Dockerfile
    │
    ├──→ docker build + push
    │
    └──→ git commit processed_versions.txt
```

## 目录结构

```
library/ruby/
├── config.yml
├── processed_versions.txt
└── template/
    ├── update.sh
    ├── apply-templates.sh
    ├── Dockerfile-*.template
    └── 4.0.6/
        └── {variant}/Dockerfile
```
