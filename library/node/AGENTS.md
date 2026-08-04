# node

## 上游

- **仓库**: https://github.com/nodejs/docker-node
- **当前版本**: 26.5.1
- **版本来源**: unofficial-builds.nodejs.org

## 上游结构

```
Dockerfile-debian.template    # Debian 全量镜像模板
Dockerfile-alpine.template    # Alpine 镜像模板
Dockerfile-slim.template      # Debian slim 镜像模板
update.sh                     # gawk 渲染，动态生成架构 case 语句
versions.json                 # 版本和变体配置
keys/node.keys                # GPG 公钥
docker-entrypoint.sh          # 容器入口脚本
```

## 本地映射

| 上游 | 本地 | 说明 |
|------|------|------|
| `Dockerfile-debian.template` | `template/Dockerfile-debian.template` | 使用预编译 loong64 二进制（unofficial-builds） |
| `Dockerfile-slim.template` | `template/Dockerfile-debian-slim.template` | 使用预编译 loong64 二进制（unofficial-builds） |
| `Dockerfile-alpine.template` | `template/Dockerfile-alpine.template` | 从源码编译（无 loong64 musl 二进制） |
| `update.sh` | `template/update.sh` | bash + jq，获取 GPG keys 和 SHA256 |
| `apply-templates.sh` | `template/apply-templates.sh` | jq 提取 + sed 渲染 |
| `keys/node.keys` | `template/update.sh` 运行时获取 | 从上游仓库实时获取 |

## 模板变量

| 变量 | 来源 | 说明 |
|------|------|------|
| `{VERSION}` | update.sh | Node.js 完整版本号（如 26.5.1） |
| `{NODE_KEYS}` | update.sh | GPG 公钥列表（多行，从上游 keys/node.keys 获取） |
| `{LOONG64_SHA256}` | update.sh | loong64 glibc 二进制的 SHA256（仅 Debian 变体使用） |
| `{DEBIAN_VERSION}` | update.sh | Debian 版本（如 forky） |
| `{ALPINE_VERSION}` | update.sh | Alpine 版本（如 3.24） |

## 架构说明

- **Debian 变体**: 使用 unofficial-builds.nodejs.org 的预编译 loong64 glibc 二进制
- **Alpine 变体**: 从源码编译（unofficial-builds 没有 loong64 musl 二进制）
- 所有变体只支持 loong64 架构

## 上游更新时的调整步骤

1. 对比上游 `Dockerfile-debian.template` 和本地模板
2. 合并上游变更，保留 `{VAR}` 占位符
3. 检查是否有新增的环境变量需要添加为模板变量
4. 检查 GPG 公钥是否变更（update.sh 从上游实时获取）
5. 检查 Yarn 版本是否变更
6. Node 26+ 移除了 Yarn v1，如上游有变更需同步

## 已知问题

- Node.js 官方（nodejs.org）没有 loong64 预编译二进制
- unofficial-builds.nodejs.org 有 loong64 glibc 二进制，但版本可能滞后
- Alpine 变体需要从源码编译，构建时间较长
- **Alpine 源码编译失败**（2026-08-04）— 从源码编译 Node.js on Alpine loong64 报错，已暂时在 config.yml 中注释掉 Alpine 变体，待排查修复
