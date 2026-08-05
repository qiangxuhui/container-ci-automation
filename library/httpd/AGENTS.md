# httpd

## 上游

- **仓库**: https://github.com/docker-library/httpd
- **当前版本**: 2.4.68

## 上游结构

```
2.4/
├── Dockerfile                # Debian 变体
├── alpine/Dockerfile         # Alpine 变体
└── httpd-foreground
update.sh                     # sed 直接改 Dockerfile 中的版本号
```

## 本地映射

| 上游 | 本地 | 说明 |
|------|------|------|
| `2.4/Dockerfile` | `template/Dockerfile-debian.template` | `{VERSION}` `{SHA256}` `{DEBIAN_VERSION}` `{PATCHES}` |
| `2.4/alpine/Dockerfile` | `template/Dockerfile-alpine.template` | `{VERSION}` `{SHA256}` `{ALPINE_VERSION}` `{PATCHES}` |
| `update.sh` | `template/update.sh` | wget 获取 sha256 + 补丁信息 |
| — | `template/apply-templates.sh` | jq 提取 + sed 渲染 |

## 模板变量

| 占位符 | 来源 |
|--------|------|
| `{VERSION}` | go.dev API / Apache 下载站 |
| `{SHA256}` | `httpd-$VERSION.tar.bz2.sha256` |
| `{ALPINE_VERSION}` | update.sh 顶部定义 |
| `{DEBIAN_VERSION}` | update.sh 顶部定义 |
| `{PATCHES}` | `patches/apply_to_$VERSION/` 目录 |

## 上游更新

1. 对比上游 `2.4/Dockerfile` 和本地 `template/Dockerfile-debian.template`
2. 对比上游 `2.4/alpine/Dockerfile` 和本地 `template/Dockerfile-alpine.template`
3. 合并上游变更，保留 `{VAR}` 占位符
4. 检查是否有新增环境变量需要添加为模板变量

## 构建

```bash
python3 tools/process_version.py library/httpd
```
