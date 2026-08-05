# debian

## 上游

- **仓库**: https://github.com/docker-library/debian
- **特殊**: 使用 debuerreotype 构建 rootfs，不直接使用上游 Dockerfile

## 本地结构

```
template/
├── update.sh                 # debuerreotype 构建 rootfs + 生成 versions.json
├── apply-templates.sh        # 读 versions.json，生成 Dockerfile + 复制 rootfs
├── Dockerfile-standard.template
├── Dockerfile-slim.template
└── modify-rootfs-url.sh      # 修改 rootfs 源地址
```

## 模板变量

| 占位符 | 来源 |
|--------|------|
| `{VERSION}` | 时间戳格式 `20250521T073957Z` |
| `{DEBIAN_VERSION}` | update.sh 顶部定义（如 `14`） |
| `{DEBIAN_VERSION_NAME}` | 从映射表获取（如 `forky`） |
| `{SUITE}` | 固定 `unstable` |
| `{TIME_VERSION}` | 从版本号提取日期部分 |

## 上游更新

1. 检查 snapshot.debian.org 是否有新的快照
2. 如需调整 rootfs 源，修改 `modify-rootfs-url.sh`
3. 如需支持新 Debian 版本，在 update.sh 的 `VERSION_NAMES` 映射中添加

## 构建

```bash
python3 tools/process_version.py library/debian
```
