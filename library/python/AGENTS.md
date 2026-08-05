# python

## 上游

- **仓库**: https://github.com/docker-library/python
- **当前版本**: 3.14.6 (latest)
- **活跃版本**: 3.10, 3.11, 3.12, 3.13, 3.14
- **构建方式**: 从源码编译（Python 官方只提供源码 tarball）

## 上游结构

```
Dockerfile-linux.template    # jq-template.awk 语法，含复杂条件逻辑
Dockerfile-windows.template  # Windows 变体（本地不迁移）
versions.sh                  # 从 cpython git tags + python.org 获取版本
versions.json                # versions.sh 生成的版本数据
apply-templates.sh           # gawk + jq-template.awk 渲染
update.sh                    # 调用 versions.sh + apply-templates.sh
```

## 本地映射

| 上游 | 本地 | 说明 |
|------|------|------|
| `Dockerfile-linux.template` | `template/Dockerfile-debian.template` | Debian 全量镜像 |
| 同上 | `template/Dockerfile-debian-slim.template` | Debian slim 镜像 |
| 同上 | `template/Dockerfile-alpine.template` | Alpine 镜像 |
| `versions.sh` | `template/update.sh` | 从 python.org API 获取 checksum，预计算条件块 |
| `apply-templates.sh` | `template/apply-templates.sh` | sed + awk 渲染 |

## 模板变量

| 变量 | 来源 | 说明 |
|------|------|------|
| `{VERSION}` | update.sh | Python 完整版本号（如 3.14.6） |
| `{PYTHON_SHA256}` | update.sh | 源码 tarball 的 SHA256 |
| `{DEBIAN_VERSION}` | update.sh | Debian 版本（仅在 update.sh 中管理，不体现在 config.yml） |
| `{ALPINE_VERSION}` | update.sh | Alpine 版本（仅在 update.sh 中管理，不体现在 config.yml） |
| `{GPG_KEY}` | update.sh | GPG 公钥 ID（仅 3.10-3.12） |

## 变体说明

| 变体 | 模板 | 特点 |
|------|------|------|
| debian | Dockerfile-debian.template | 全量镜像，含 tk/bluetooth 等 |
| debian-slim | Dockerfile-debian-slim.template | 精简镜像 |
| alpine | Dockerfile-alpine.template | 最小镜像 |

> 基础镜像版本（如 forky、3.24）不体现在变体名中，仅在 update.sh 作为变量管理。

## 版本特殊处理

- **3.10, 3.11**: 需要 GPG 签名验证 + setuptools 安装
- **3.12**: 需要 GPG 签名验证，无 setuptools
- **3.13+**: 无 GPG 验证（PEP 761），无 setuptools
- **Alpine**: `--enable-optimizations` 禁用，`-DTHREAD_STACK_SIZE=0x100000`
- **非 Alpine**: `--enable-optimizations` 启用，`-fno-omit-frame-pointer`

## 上游更新时的调整步骤

1. 对比上游 `Dockerfile-linux.template` 和本地模板
2. 如有新增条件逻辑，在 update.sh 中预计算新块
3. 如有新增 GPG key 或 setuptools 变更，更新 update.sh 中的映射

## 构建

```bash
python3 tools/process_version.py library/python
```
