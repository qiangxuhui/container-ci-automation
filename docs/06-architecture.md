# 06 — 整体架构（v6.10）

## 目标架构

```
tools/                              ← 1 套统一工具
├──                           ← 日志与辅助函数
└── build.py              ← 统一入口

library/                            ← 项目目录
├── ruby/
│   ├── AGENTS.md                   ← AI agent 上下文
│   ├── config.yml                  ← 声明式配置（强约束）
│   ├── processed_versions.txt      ← 版本跟踪
│   ├── get_versions.sh       ← 自定义版本脚本（可选）
│   ├── template/
│   │   ├── update.sh               ← 项目专属：处理变量
│   │   ├── apply-templates.sh      ← 项目专属：应用模板生成 Dockerfile
│   │   ├── Dockerfile-debian.template
│   │   ├── Dockerfile-debian-slim.template
│   │   └── Dockerfile-alpine.template
│   └── dockerfiles/                ← 生成的构建目录（CI 提交）
│       ├── .gitignore              ← 原生 gitignore，排除不需要提交的文件
│       └── 4.0.6/
│           ├── debian/
│           │   └── Dockerfile
│           ├── debian-slim/
│           │   └── Dockerfile
│           └── alpine/
│               └── Dockerfile
│
└── ...

.github/workflows/                  ← 每个项目一个 workflow
├── library-ruby.yml
└── ...
```

## 关键约束

1. **build.py 流程强制统一**
2. **项目可处理多个版本** — get_versions.sh 输出多行时，build.py 逐个处理
3. **tags 由 config.yml 声明** — build.py 渲染 `{version}` 变量
4. **使用 buildx 构建** — `--platform linux/loong64`
5. **并行由 GitHub 触发**
6. **processed_versions.txt + dockerfiles/** — 存储在仓库内，更新后提交，处理并发冲突
7. **每个项目有 AGENTS.md** — 为 AI agent 提供上下文

---

## config.yml 强约束

### 完整格式

```yaml
# library/{project}/config.yml

# 项目标识（必填）
project:
  org: library                    # 组织名
  name: ruby                      # 项目名

# 版本来源（必填）
version_source:
  type: github_releases           # github_releases | script
  repository: "ruby/ruby"         # type=github_releases 时必填
  tag_regex: "^v([0-9]+\\.[0-9]+\\.[0-9]+)$"  # type=github_releases 时必填
  script: get_versions.sh   # type=script 时必填

# 变体定义（必填，至少一个）
variants:
  - name: "debian"                 # 变体名（对应目录名）
    template: "Dockerfile-debian.template"  # 模板文件名（必须在 template/ 目录下存在）
    tags:                         # 标签列表（{version} 由 build.py 渲染）
      - "{version}"
      - "latest"
  - name: "debian-slim"
    template: "Dockerfile-debian-slim.template"
    tags:
      - "{version}-slim"
  - name: "alpine"
    template: "Dockerfile-alpine.template"
    tags:
      - "{version}-alpine"
```

### 约束规则

| 规则 | 说明 |
|------|------|
| `project.org` + `project.name` | 唯一标识项目，用于 workflow 文件名映射 |
| `variants[].name` | 必须唯一，对应 `dockerfiles/{version}/{name}/` 目录名 |
| `variants[].template` | 必须是 `Dockerfile-{variant}.template` 格式，且文件必须存在 |
| `variants[].tags` | 至少一个标签，`{version}` 为唯一允许的变量占位符 |

### 变量渲染

build.py 在构建时渲染 `variants[].tags` 中的变量：

| 变量 | 含义 | 示例值 |
|------|------|--------|
| `{version}` | 完整版本号 | `3.24.1`, `4.0.6` |
| `{major_version}` | 主版本号 | `3`, `4` |
| `{minor_version}` | 次版本号 | `3.24`, `4.0` |

版本变量计算规则（仅支持语义版本）：
- `3.24.1`: major=`3`, minor=`3.24`

渲染后传递给 docker buildx：
```
lcr.loongnix.cn/library/alpine:3
lcr.loongnix.cn/library/alpine:3.24
lcr.loongnix.cn/library/alpine:3.24.1
lcr.loongnix.cn/library/alpine:latest
```

---

## template 目录强约束

### 目录结构

```
{project}/template/
├── update.sh                     ← 必填：处理变量
├── apply-templates.sh            ← 必填：应用模板生成 Dockerfile
├── Dockerfile-{variant}.template ← 必填：每个变体一个模板
└── {辅助文件}                     ← 可选：modify-rootfs-url.sh 等
```

### 模板文件规范

**命名**：`Dockerfile-{variant}.template`
- variant 名必须与 config.yml 中 `variants[].name` 一致
- 示例：`Dockerfile-debian.template`, `Dockerfile-debian-slim.template`, `Dockerfile-alpine.template`

**变量占位符**（由 apply-templates.sh 使用 sed 渲染）：

| 变量 | 含义 | 示例值 |
|------|------|--------|
| `{VERSION}` | 完整版本号 | `4.0.6` |
| `{MAJOR_VERSION}` | 主版本号 | `4.0` |
| `{VARIANT}` | 变体名 | `debian` |
| `{REGISTRY}` | 镜像仓库地址 | `lcr.loongnix.cn` |
| `{REPOSITORY}` | 镜像仓库路径 | `library/ruby` |
| `{CUSTOM_*}` | 项目自定义变量 | 由 update.sh 生成 |

**示例：Dockerfile-debian.template**

```dockerfile
ARG VERSION

FROM buildpack-deps:forky

ARG VERSION
LABEL org.opencontainers.image.version="{VERSION}"

RUN apt-get update && apt-get install -y \
    ruby-{VERSION} \
    && rm -rf /var/lib/apt/lists/*

CMD ["ruby", "--version"]
```

### 脚本规范

**update.sh**
- 接收参数：`$1` = 版本号
- 职责：处理变量，生成 variables.json 或设置环境变量
- 输出：供 apply-templates.sh 使用的变量数据

**apply-templates.sh**
- 接收参数：`$1` = 版本号
- 职责：遍历 config.yml 中的 variants，使用对应模板生成 Dockerfile
- 输出：`dockerfiles/{version}/{variant}/Dockerfile` + 辅助文件（如 rootfs.tar.xz）

---

## dockerfiles 目录规范

### 目录结构

```
{project}/dockerfiles/
├── .gitignore                    ← 原生 gitignore，排除不需要提交的文件
└── {full_version}/               ← 每个版本一个目录
    └── {variant}/
        ├── Dockerfile            ← 渲染后的 Dockerfile
        └── {辅助文件}             ← 如 rootfs.tar.xz（可能被 .gitignore 排除）
```

### .gitignore

使用原生 gitignore 机制，每个项目自行维护 `dockerfiles/.gitignore`。

常见规则：
- `*.tar.xz` — 排除 rootfs 压缩包
- `rootfs.*` — 排除 rootfs 相关元数据
- `Release`, `InRelease` — 排除 Debian 仓库文件

---

## 上游模板拆分规则

如果上游使用 jinja 混合 debian 和 alpine 模板，拆分为两个独立模板：

### 示例：上游混合模板

```dockerfile
# upstream/Dockerfile.template（jinja）
{% if variant == 'alpine' %}
FROM alpine:3.24
RUN apk add --no-cache ruby
{% else %}
FROM buildpack-deps:forky
RUN apt-get update && apt-get install -y ruby
{% endif %}
```

### 拆分后

```dockerfile
# template/Dockerfile-debian.template
FROM buildpack-deps:forky
RUN apt-get update && apt-get install -y ruby
```

```dockerfile
# template/Dockerfile-alpine.template
FROM alpine:3.24
RUN apk add --no-cache ruby
```

### 拆分原则

1. 每个模板文件只包含一个变体的内容
2. 移除所有 jinja/条件逻辑
3. 保留完整的 Dockerfile 语法
4. 使用统一的变量占位符

---

## 调用方式

```bash
python3 tools/build.py library/ruby
python3 tools/build.py library/debian

# 测试模式
python3 tools/build.py --test library/ruby 4.0.6
python3 tools/build.py -t library/debian 20260803T022142Z

# Dry run
DRY_RUN=true python3 tools/build.py library/ruby
```

## 数据流

```
build.py library/ruby
    │
    ├──→ get_versions.sh → "4.0.6"
    │
    ├──→ grep "4.0.6" processed_versions.txt
    │       │
    │       ├── 存在 → "版本已构建，跳过"
    │       │
    │       └── 不存在 → 继续构建
    │
    ├──→ update.sh 4.0.6 → variables.json
    │
    ├──→ apply-templates.sh 4.0.6
    │       │
    │       └──→ 遍历 variants，生成 Dockerfile
    │               dockerfiles/4.0.6/debian/Dockerfile
    │               dockerfiles/4.0.6/debian-slim/Dockerfile
    │               dockerfiles/4.0.6/alpine/Dockerfile
    │
    ├──→ buildx 构建
    │       │
    │       └──→ 读取 config.yml tags，渲染 {version}
    │               lcr.loongnix.cn/library/ruby:4.0.6
    │               lcr.loongnix.cn/library/ruby:latest
    │
    └──→ git commit processed_versions.txt + dockerfiles/
```

## GitHub Actions Workflow

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

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3
        with:
          driver: docker-container
          driver-opts: |
            image=moby/buildkit:latest

      - name: Login to Loongnix Registry
        uses: docker/login-action@v3
        with:
          registry: lcr.loongnix.cn
          username: ${{ secrets.REGISTRY_USER }}
          password: ${{ secrets.REGISTRY_PASS }}

      - name: Build and Push
        run: python3 tools/build.py library/ruby
```

## 并发处理策略

### 问题

多个 workflow 并行触发时，多个 build.py 实例可能同时修改 processed_versions.txt，导致 git 冲突。

### 解决方案：乐观锁 + 自动重试

1. 构建完成后提交时使用 `git pull --rebase`
2. 如果冲突（其他 workflow 已提交），自动回滚、拉取最新、重新添加版本
3. 最多重试 3 次

```
git add + commit
    │
    ▼
git pull --rebase
    │
    ├── 成功 → git push → 完成
    │
    └── 失败（冲突）
            │
            ▼
        git reset --soft HEAD~1
            │
            ▼
        git pull --rebase（获取最新）
            │
            ▼
        重新添加版本
            │
            ▼
        重试 commit + push
```

## buildx 初始化

```bash
# 在 self-hosted runner 上执行一次
docker buildx create --name loongarch64 --driver docker-container --use
docker buildx inspect --bootstrap
```
