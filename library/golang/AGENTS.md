# golang

## 上游

- **仓库**: https://github.com/docker-library/golang
- **当前版本**: 1.26.5

## 上游结构

```
Dockerfile-linux.template    # jq-template.awk 语法，包含多架构 case 语句
versions.sh                  # 从 go.dev API 获取版本信息
apply-templates.sh           # gawk + jq-template.awk 渲染
update.sh                    # 调用 versions.sh + apply-templates.sh
```

## 本地映射

| 上游 | 本地 | 说明 |
|------|------|------|
| `Dockerfile-linux.template` | `template/Dockerfile-forky.template` | case 语句 + `{URL_xxx}` `{SHA256_xxx}` 占位符 |
| 同上 | `template/Dockerfile-alpine.template` | 架构名不同（x86_64, armv7, loongarch64） |
| `versions.sh` | `template/update.sh` | wget + jq，获取所有架构下载信息 |
| `apply-templates.sh` | `template/apply-templates.sh` | jq 提取 + sed 渲染 |

## 架构名映射

| 模板占位符 | API 名 | Debian | Alpine |
|-----------|--------|--------|--------|
| `{URL_AMD64}` | amd64 | amd64 | x86_64 |
| `{URL_ARMHF}` | armv6l | armhf | armv7 |
| `{URL_ARM64}` | arm64 | arm64 | aarch64 |
| `{URL_I386}` | 386 | i386 | x86 |
| `{URL_LOONG64}` | loong64 | loong64 | loongarch64 |

## 上游更新

1. 对比上游 `Dockerfile-linux.template` 和本地模板
2. 如有新增架构，在模板中添加 case 分支 + update.sh 中添加变量
3. 如有新增变体（如新 Alpine 版本），更新 update.sh 中的 `alpine_versions`

## 构建

```bash
./tools/process_version.sh library/golang
```
