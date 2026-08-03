# 迁移经验 — library/debian

## 项目特点

debian 是特殊项目，不使用标准模板系统：

1. **版本格式**: 时间戳 `20250521T073957Z`
2. **构建方式**: debuerreotype 从 snapshot.debian.org 构建 rootfs
3. **Dockerfile**: `FROM scratch` + `ADD rootfs.tar.xz`
4. **Tags**: 复杂（版本号 + 代号 + suite + 日期 + latest）
5. **文件位置**: debian.version, modify-rootfs-url.sh 在 template/ 目录，get_latest_version.sh 在项目根目录

## 迁移步骤

### 1. 创建配置文件

```yaml
# library/debian/config.yml
project:
  org: library
  name: debian
version_source:
  type: script
  script: fetch_versions.sh
push:
  registry: "lcr.loongnix.cn"
  repository: "library/debian"
```

### 2. 迁移版本获取脚本

原 `fetch_versions.sh` 重命名为 `get_latest_version.sh`，放在项目根目录：

```bash
#!/bin/bash
# library/debian/get_latest_version.sh
# 输出最新版本号（1 行）
set -eo pipefail

DEBIAN_MIRROR='https://snapshot.debian.org/archive/debian'
year=$(date +%Y)
month=$(date +%m)
version=$(wget -qO- "$DEBIAN_MIRROR?year=$year&month=$month" \
    | grep -oE 'href="[0-9]{8}T[0-9]{6}Z/"' \
    | tail -1 \
    | cut -d '"' -f 2 | cut -d '/' -f 1)
echo "$version"
```

config.yml 中引用路径：
```yaml
version_source:
  type: script
  script: get_latest_version.sh
```

### 3. 创建 update.sh

接收版本号，构建 rootfs：

```bash
#!/bin/bash
set -eo pipefail
VERSION="$1"
# 验证版本格式
# 使用 debuerreotype 构建 rootfs
# 输出到 out/ 目录
```

### 4. 创建 apply-templates.sh

接收版本号，生成 Dockerfile：

```bash
#!/bin/bash
set -eo pipefail
VERSION="$1"
# 从 Dockerfile.template 生成 Dockerfile
# 替换变量: {VERSION}, {DEBIAN_VERSION}, {DEBIAN_VERSION_NAME}, {SUITE}
# 复制 rootfs.tar.xz 到构建目录
```

### 5. 创建 Dockerfile.template

```dockerfile
FROM scratch
LABEL maintainer="znley<shanjiantao@loongson.cn>"
LABEL org.opencontainers.image.version="{VERSION}"
LABEL org.opencontainers.image.title="Debian {DEBIAN_VERSION_NAME}"
LABEL org.opencontainers.image.description="Debian {SUITE} for LoongArch64"
ADD rootfs.tar.xz /
CMD ["/bin/bash"]
```

## 遇到的问题

### 1. parse_config Python 语法错误

**问题**: f-string 中不能有反斜杠

```python
# 错误
print(f'VERSION_SOURCE_TAG_REGEX="{vs.get("tag_regex", "^v?([0-9]+\\\\.[0-9]+\\\\.[0-9]+)$")}"')

# 正确: 使用 heredoc + sys.argv
python3 - "$config_file" << 'PYEOF'
import yaml
import sys
config_file = sys.argv[1]
# ...
PYEOF
```

### 2. git push 失败（无远程仓库）

**问题**: 测试环境没有配置远程仓库

**解决**: 使用 dry_run 模式测试，不执行 git push

### 3. debian 特殊性

**问题**: debian 不使用标准模板系统，需要自定义 rootfs 构建流程

**解决**: 将 rootfs 构建逻辑放在 update.sh，模板仅用于打包

## 验证命令

```bash
# 语法检查
bash -n tools/lib.sh
bash -n tools/process_version.sh
bash -n library/debian/template/update.sh
bash -n library/debian/template/apply-templates.sh

# Dry run 测试
DRY_RUN=true ./tools/process_version.sh library/debian
```
