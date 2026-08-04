# ruby

## 上游

- **仓库**: https://github.com/docker-library/ruby
- **当前版本**: 3.3.12, 3.4.10, 4.0.6
- **活跃版本**: 3.3, 3.4, 4.0
- **构建方式**: 从源码编译（Ruby 官方只提供源码 tarball）

## 上游结构

```
Dockerfile.template    # jq-template.awk 语法，含复杂条件逻辑
versions.sh            # 从 ruby-lang.org releases.yml 获取版本
versions.json          # versions.sh 生成的版本数据
apply-templates.sh     # gawk + jq-template.awk 渲染
update.sh              # 调用 versions.sh + apply-templates.sh
rust.json              # rustup 二进制信息（per-arch）
```

## 本地映射

| 上游 | 本地 | 说明 |
|------|------|------|
| `Dockerfile.template` | `template/Dockerfile-debian.template` | Debian 全量镜像 |
| 同上 | `template/Dockerfile-debian-slim.template` | Debian slim 镜像 |
| 同上 | `template/Dockerfile-alpine.template` | Alpine 镜像 |
| `versions.sh` | `template/update.sh` | 从 ruby-lang.org 获取 checksum |
| `apply-templates.sh` | `template/apply-templates.sh` | sed + awk 渲染 |

## 模板变量

| 变量 | 来源 | 说明 |
|------|------|------|
| `{VERSION}` | update.sh | Ruby 完整版本号（如 3.3.12） |
| `{RUBY_DOWNLOAD_URL}` | update.sh | xz 下载链接 |
| `{RUBY_DOWNLOAD_SHA256}` | update.sh | xz 文件的 SHA256 |
| `{POST}` | update.sh | 发布博文路径 |
| `{RUST_VERSION}` | update.sh | Rust 版本号（用于 rustup） |
| `{DEBIAN_VERSION}` | update.sh | Debian 版本（forky） |
| `{ALPINE_VERSION}` | update.sh | Alpine 版本（3.24） |

## 变体说明

| 变体 | 模板 | 特点 |
|------|------|------|
| debian | Dockerfile-debian.template | 全量镜像，基于 buildpack-deps |
| debian-slim | Dockerfile-debian-slim.template | 精简镜像，基于 debian:*-slim |
| alpine | Dockerfile-alpine.template | 最小镜像，含 thread-stack-fix 补丁 |

> 基础镜像版本（如 forky、3.24）不体现在变体名中，仅在 update.sh 作为变量管理。

## LoongArch64 特殊处理

- **无 Rust/YJIT/ZJIT**: loong64 不在 rust.json 中，case statement 为空，`rustArch` 保持空，YJIT/ZJIT 不启用
- **Alpine thread-stack-fix**: 保留上游补丁（仅 alpine 变体）
- **autoconf + dpkg-architecture**: alpine 变体也使用 `dpkg-dev dpkg` 进行架构检测

## 版本特殊处理

- **3.3, 3.4**: 仅 YJIT（`${rustArch:+--enable-yjit}`）
- **4.0+**: YJIT + ZJIT（`${rustArch:+--enable-zjit}`）

## 上游更新时的调整步骤

1. 对比上游 `Dockerfile.template` 和本地模板
2. 如有新增条件逻辑，在 apply-templates.sh 中预计算新块
3. 如有新增架构支持，更新 rust.json 映射

## 构建

```bash
./tools/process_version.sh library/ruby
```
