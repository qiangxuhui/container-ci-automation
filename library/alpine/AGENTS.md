# alpine — AGENTS.md

## 模板上游信息

| 字段 | 值 |
|------|-----|
| 上游仓库 | cz.alpinelinux.org |
| 上游分支 | latest-stable |
| 上次同步 | 无（直接下载 minirootfs） |

## 本地适应性调整

### 特殊说明

alpine 项目直接从 Alpine 官方下载 minirootfs，不是从上游 Dockerfile 构建。
模板仅用于打包 minirootfs 为 Docker 镜像。

### Dockerfile-alpine.template

- **FROM scratch**: 从零开始构建
- **ADD rootfs.tar.gz**: 添加 minirootfs 压缩包
- **无上游对比**: 完全自定义

## 构建流程

1. get_versions.sh: 从 cz.alpinelinux.org 获取最新版本
2. update.sh: 下载 minirootfs
3. apply-templates.sh: 生成 Dockerfile（FROM scratch + ADD）
4. docker buildx build: 构建 Docker 镜像
5. docker push: 推送到 registry

## 版本格式

版本格式为: `3.24.1`

- 3: 主版本号
- 3.24: 次版本号
- 3.24.1: 完整版本号

## Tag 命名

每个版本生成以下 tags:

- `3`: 主版本号
- `3.24`: 次版本号
- `3.24.1`: 完整版本号
- `latest`: 最新版本

## 已知问题

| 问题 | 影响 | 解决方案 |
|------|------|----------|
| minirootfs 下载慢 | CI 考时长 | 使用缓存 |

## 构建信息

- **构建命令**: `python3 tools/build.py library/alpine`
- **Dry run**: `DRY_RUN=true python3 tools/build.py library/alpine`
- **Registry**: `lcr.loongnix.cn`
- **Repository**: `library/alpine`
- **平台**: `linux/loong64`

## 依赖

- wget
- docker buildx
