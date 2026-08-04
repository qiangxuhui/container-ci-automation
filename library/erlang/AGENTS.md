# library/erlang — AI Agent 上下文

## 项目信息

- **上游仓库**: https://github.com/erlang/docker-erlang-otp.git
- **迁移范围**: 主版本 24-29（共 6 个大版本）
- **变体**: debian（默认）、debian-slim、alpine
- **构建方式**: 从源码编译 OTP，附带 rebar 和 rebar3

## 上游结构

```
docker-erlang-otp/
├── {MAJOR_VERSION}/           # 24/, 25/, ..., 29/
│   ├── Dockerfile             # 默认变体（buildpack-deps）
│   ├── slim/Dockerfile        # slim 变体（debian）
│   └── alpine/Dockerfile      # alpine 变体
└── generate-stackbrew-library.sh
```

## 版本差异

| 主版本 | 基础镜像 | OTP 下载 URL | REBAR3 |
|--------|----------|--------------|--------|
| 24-25 | bullseye | archive/ | 3.23-3.24 |
| 26 | bookworm | archive/ | 3.26 |
| 27-29 | bookworm/trixie | releases/download/ | 3.27 |

## 模板变量

| 变量 | 说明 | 示例 |
|------|------|------|
| {OTP_VERSION} | OTP 版本号 | 28.5.0.4 |
| {REBAR3_VERSION} | rebar3 版本号 | 3.27.0 |
| {OTP_DOWNLOAD_URL} | OTP 源码下载 URL | https://github.com/... |
| {OTP_DOWNLOAD_SHA256} | OTP 源码 SHA256 | efb045f... |
| {REBAR3_DOWNLOAD_SHA256} | rebar3 SHA256（默认/slim） | 985cae6... |
| {DEBIAN_VERSION} | Debian 版本 | trixie |
| {ALPINE_VERSION} | Alpine 版本 | 3.24 |
| {RUNTIME_DEPS} | 运行时依赖（默认变体） | libodbc2 libsctp1 ... |
| {BUILD_DEPS} | 构建依赖（默认变体） | unixodbc-dev libsctp-dev |
| {SLIM_RUNTIME_DEPS} | 运行时依赖（slim 变体） | libodbc2 libssl3t64 libsctp1 |

## 本地调整

- 所有 FROM 行添加 `lcr.loongnix.cn/` 前缀
- alpine 变体使用 `lcr.loongnix.cn/alpine:` 而非 `alpine:`
- 版本元数据从上游 Dockerfile 提取（非 GitHub API）
- REBAR3 SHA256 在默认/slim 和 alpine 变体间不同

## 构建命令

```bash
# 测试单个版本
./tools/process_version.sh --test library/erlang 28.5.0.4

# 生产构建
./tools/process_version.sh library/erlang
```
