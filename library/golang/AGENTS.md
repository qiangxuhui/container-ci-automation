# golang — AGENTS.md

## 上游仓库

- **地址**: https://github.com/docker-library/golang
- **分支**: master
- **当前同步版本**: 1.26

## 上游结构

```
├── Dockerfile-linux.template       # Linux 变体模板（jq-template.awk 语法）
├── versions.sh                     # 从 go.dev API 获取版本信息生成 versions.json
├── apply-templates.sh              # 使用 gawk + jq-template.awk 渲染模板
├── update.sh                       # 调用 versions.sh + apply-templates.sh
└── .jq-template.awk                # jq-template 渲染引擎
```

## 上游 → 本地转换

### 文件映射

| 上游 | 本地 | 转换方式 |
|------|------|----------|
| `Dockerfile-linux.template` | `template/Dockerfile-forky.template` + `template/Dockerfile-alpine.template` | 拆分为两个 sed 兼容模板 |
| `versions.sh` | `template/versions.sh` + `template/versions.py` | 重写：用 Python 生成架构 case 语句 |
| `apply-templates.sh` | `template/apply-templates.sh` | 重写：用 sed 渲染模板（不是 jq-template.awk） |
| `update.sh` | `template/update.sh` | 保留调用结构 |
| `.jq-template.awk` | 不使用 | 容器流水线使用 sed 渲染 |

### 模板变量

| 占位符 | 含义 | 示例 |
|--------|------|------|
| `{VERSION}` | 完整版本号 | `1.26.5` |
| `{DEBIAN_VARIANT}` | Debian 变体名 | `forky` |
| `{ALPINE_VERSION}` | Alpine 版本号 | `3.22` |
| `{ARCH_CASE}` | 架构 case 语句（包含所有架构的 URL 和 SHA256） | 自动生成 |
| `{ARM_FIXUP}` | ARM 架构修复代码 | 自动生成 |

### 变体

| 变体 | 模板 | 基础镜像 |
|------|------|----------|
| `forky` | `Dockerfile-forky.template` | `buildpack-deps:forky-scm` |
| `alpine3.22` | `Dockerfile-alpine.template` | `alpine:3.22` |
| `alpine3.23` | `Dockerfile-alpine.template` | `alpine:3.23` |

### 特殊说明

1. **架构名称差异**: Alpine 和 Debian 使用不同的架构名称
   - Alpine: `x86_64`, `aarch64`, `armv7`, `x86`, `loongarch64`
   - Debian: `amd64`, `arm64`, `armhf`, `i386`, `loong64`
   - `versions.py` 为每个变体生成对应的 case 语句

2. **ARM fixup 差异**: Alpine 使用 `armv7`，Debian 使用 `armhf`

3. **版本格式**: golang 使用 X.Y 格式（如 `1.26`），versions.sh 自动获取最新 patch 版本

## 上游更新时的调整步骤

1. 对比上游 `Dockerfile-linux.template` 和本地模板
2. 更新 `versions.py` 中的架构映射（如有新增架构）
3. 检查是否有新增的变体（如新版本的 Alpine）
4. 更新 `config.yml` 中的变体列表

## 构建

```bash
./tools/process_version.sh library/golang
```
