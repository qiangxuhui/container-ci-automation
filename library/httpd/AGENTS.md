# httpd — AGENTS.md

## 上游仓库

- **地址**: https://github.com/docker-library/httpd
- **分支**: master
- **当前同步版本**: 2.4.68

## 上游结构

```
2.4/
├── Dockerfile                  # Debian 变体（原始，版本号硬编码）
├── alpine/Dockerfile           # Alpine 变体（原始，版本号硬编码）
└── httpd-foreground
update.sh                       # 用 sed 直接改 Dockerfile 中的版本号
```

## 上游 → 本地转换

### 文件映射

| 上游 | 本地 | 转换方式 |
|------|------|----------|
| `2.4/Dockerfile` | `template/Dockerfile-debian.template` | 提取为模板，硬编码值替换为 `{VAR}` |
| `2.4/alpine/Dockerfile` | `template/Dockerfile-alpine.template` | 提取为模板，硬编码值替换为 `{VAR}` |
| `update.sh` | `template/update.sh` + `template/versions.sh` | 拆分：update.sh 只调用 versions.sh |

### 模板变量转换

上游硬编码的值 → 本地模板占位符：

| 上游 Dockerfile 中的行 | 本地模板 |
|------------------------|----------|
| `ENV HTTPD_VERSION 2.4.68` | `ENV HTTPD_VERSION {VERSION}` |
| `ENV HTTPD_SHA256 68c74d4d...` | `ENV HTTPD_SHA256 {SHA256}` |
| `ENV HTTPD_PATCHES=""` | `ENV HTTPD_PATCHES="{PATCHES}"` |
| `FROM alpine:3.22` | `FROM alpine:{ALPINE_VERSION}` |
| `FROM debian:trixie-slim` | `FROM debian:{DEBIAN_VERSION}-slim` |

### 脚本转换

| 上游 update.sh 逻辑 | 本地实现 |
|---------------------|----------|
| 遍历所有版本目录 | 只处理单个版本 |
| sed 直接改 Dockerfile | versions.sh 生成 JSON，apply-templates.sh 用 sed 渲染模板 |

## 上游更新时的调整步骤

1. 对比上游 `2.4/Dockerfile` 和本地 `template/Dockerfile-debian.template`
2. 对比上游 `2.4/alpine/Dockerfile` 和本地 `template/Dockerfile-alpine.template`
3. 合并上游变更，保留 `{VAR}` 占位符
4. 检查是否有新增的环境变量需要添加为模板变量

## 构建

```bash
./tools/process_version.sh library/httpd
```
