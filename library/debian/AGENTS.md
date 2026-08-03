# debian — AGENTS.md

## 模板上游信息

| 字段 | 值 |
|------|-----|
| 上游仓库 | docker-library/debian |
| 上游分支 | master |
| 上次同步 | 无（自定义 rootfs 构建） |

## 本地适应性调整

### 特殊说明

debian 项目使用 debuerreotype 工具从 snapshot.debian.org 构建 rootfs，
不是从上游 Dockerfile 构建。模板仅用于打包 rootfs 为 Docker 镜像。

### Dockerfile.template

- **FROM scratch**: 从零开始构建
- **ADD rootfs.tar.xz**: 添加 rootfs 压缩包
- **无上游对比**: 完全自定义

## 构建流程

1. fetch_versions.sh: 从 snapshot.debian.org 获取最新快照版本
2. update.sh: 使用 debuerreotype 构建 rootfs
3. apply-templates.sh: 生成 Dockerfile（FROM scratch + ADD）
4. docker buildx build: 构建 Docker 镜像
5. docker push: 推送到 registry

## 版本格式

版本格式为时间戳: `20250521T073957Z`

- 20250521: 日期
- T: 分隔符
- 073957: 时间
- Z: UTC 时区

## Tag 命名

每个版本生成以下 tags:

### 标准 tags

- `14`: Debian 版本号
- `forky`: Debian 代号
- `unstable`: Suite 名称
- `unstable-20250521`: Suite + 日期
- `latest`: 最新版本

### Slim tags

- `14-slim`
- `forky-slim`
- `unstable-slim`
- `unstable-20250521-slim`

## 已知问题

| 问题 | 影响 | 解决方案 |
|------|------|----------|
| snapshot.debian.org 过期 | apt-get 失败 | 修改 sources.list |
| rootfs 构建慢 | CI 耗时长 | 使用 debuerreotype 缓存 |

## 构建信息

- **构建命令**: `./tools/process_version.sh library/debian`
- **Dry run**: `DRY_RUN=true ./tools/process_version.sh library/debian`
- **Registry**: `lcr.loongnix.cn`
- **Repository**: `library/debian`
- **平台**: `linux/loong64`

## 依赖

- debuerreotype/debuerreotype:latest
- docker buildx
- gh CLI
