# 迁移经验

## 公共规范（所有项目必须遵守）

### 1. 模板变量提取

从上游最终生成的 Dockerfile 中提取关键变量，使用 `{VAR}` 占位符替换：

```dockerfile
# 上游
ENV HTTPD_VERSION 2.4.68
ENV HTTPD_SHA256 68c74d4d...

# 模板
ENV HTTPD_VERSION {VERSION}
ENV HTTPD_SHA256 {SHA256}
```

### 2. 分离变体模板

按基础系统拆分模板文件：

```
template/
├── Dockerfile-debian.template    ← debian/ubuntu 基础
├── Dockerfile-alpine.template    ← alpine 基础
```

### 3. 强制流程

所有项目必须遵循：

```
update.sh → versions.json → apply-templates.sh → Dockerfile
```

- `update.sh`: 获取版本信息，生成 versions.json
- `apply-templates.sh`: 读取 versions.json，渲染模板生成 Dockerfile

### 4. 全量版本号

上游使用 a.b 进行更新的项目，本地必须使用完整 a.b.c：

```bash
# 上游: 1.26（只跟踪 major.minor）
# 本地: 1.26.5（使用完整版本号）
```

### 5. 基础镜像前缀

FROM 指令必须添加 `lcr.loongnix.cn/library/` 前缀：

```dockerfile
# 正确
FROM lcr.loongnix.cn/library/alpine:3.22
FROM lcr.loongnix.cn/library/debian:trixie-slim
FROM lcr.loongnix.cn/library/buildpack-deps:forky-scm

# 错误（会从 Docker Hub 拉取）
FROM alpine:3.22
FROM debian:trixie-slim
```

### 6. 脚本执行权限

新建 .sh 文件必须添加执行权限：

```bash
chmod +x library/{project}/get_latest_version.sh
chmod +x library/{project}/template/update.sh
chmod +x library/{project}/template/apply-templates.sh
```

### 7. versions.json 精简原则

只存储模板渲染需要的数据，不存冗余信息：

```json
// 正确：只存占位符需要的值
{
  "version": "1.26.5",
  "amd64_url": "https://...",
  "amd64_sha256": "..."
}

// 错误：存了模板不需要的数据
{
  "version": "1.26.5",
  "stable": true,
  "files": [...],
  "arches": {...}
}
```

### 8. sed 与 Python 的分工

- **sed**: 处理简单单行替换（{VERSION}, {SHA256} 等）
- **Python**: 只用于多行文本生成（如 case 语句），且应尽量避免
- **jq**: 处理 JSON 数据提取

### 9. 基础镜像版本集中管理

debian 和 alpine 的基础镜像版本必须在 `update.sh` 顶部统一定义，便于后期修改：

```bash
#!/bin/bash
# update.sh 顶部集中管理变体版本
alpine_versions="3.22 3.23"
debian_version="forky"
```

```json
// versions.json 中记录实际使用的版本
{
  "1.26.5": {
    "version": "1.26.5",
    "alpine_version": "3.22 3.23",
    "debian_version": "forky",
    ...
  }
}
```

**好处**：升级 Alpine 或 Debian 版本时，只需修改 `update.sh` 一处，重新运行即可生成新版 Dockerfile。

**禁止**：不要使用单独的 `.version` 文件存储版本号，所有版本信息必须在 `update.sh` 中定义并写入 `versions.json`。

---

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

### 1. 脚本执行权限

**问题**: 新建的 .sh 文件默认没有执行权限，导致 `./script.sh` 调用失败

**解决**: 创建脚本后立即添加执行权限
```bash
chmod +x library/{project}/get_latest_version.sh
chmod +x library/{project}/template/update.sh
chmod +x library/{project}/template/apply-templates.sh
```

**注意**: git 会跟踪文件权限，确保脚本在提交前有 `+x` 权限

### 2. parse_config Python 语法错误

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

### 3. git push 失败（无远程仓库）

**问题**: 测试环境没有配置远程仓库

**解决**: 使用 dry_run 模式测试，不执行 git push

### 4. debian 特殊性

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

---

# 迁移经验 — library/httpd

## 项目特点

httpd 是标准 Docker Library 项目：
1. **版本格式**: 语义版本 `2.4.68`
2. **变体**: 2 个（alpine, debian）
3. **模板系统**: 上游使用 jq-template.awk（`{{ .variable }}` 语法）
4. **版本来源**: GitHub tags + Apache 下载站获取 sha256
5. **补丁支持**: 通过 HTTPD_PATCHES 环境变量传递

## 特殊经验

### 1. jq-template.awk 到 sed 的转换

**问题**: 上游模板使用 jq-template.awk 语法（`{{ .variable }}`），我们的统一工具使用 sed（`{VARIABLE}`）

**转换规则**:
```
{{ .version }}      → {VERSION}
{{ .sha256 }}       → {SHA256}
{{ .patches }}      → {PATCHES}
{{ .alpine.version }} → {ALPINE_VERSION}
{{ .debian.version }} → {DEBIAN_VERSION}
```

**注意**: 转换后需检查模板中是否有 `$` 字符，sed 替换时需转义

### 2. update.sh 拆分

**问题**: 上游 `update.sh` 合并了 `versions.sh` + `apply-templates.sh`，但 `process_version.sh` 分开调用这两个脚本

**解决**: 将上游 update.sh 拆分为：
- `update.sh` → 只调用 versions.sh 生成 versions.json
- `apply-templates.sh` → 读取 versions.json，使用 sed 渲染模板

### 3. 多变量模板渲染

**问题**: httpd 模板有 5 个变量，比 alpine（3 个变量）更复杂

**解决**: apply-templates.sh 使用 jq 从 versions.json 提取变量，然后用 sed 逐个替换：
```bash
sed \
    -e "s/{VERSION}/$V_VERSION/g" \
    -e "s/{SHA256}/$V_SHA256/g" \
    -e "s/{ALPINE_VERSION}/$V_ALPINE/g" \
    -e "s/{DEBIAN_VERSION}/$V_DEBIAN/g" \
    -e "s/{PATCHES}/$V_PATCHES/g" \
    "$TEMPLATE" > "$OUTPUT"
```

### 4. 版本信息获取

**问题**: httpd 需要从 Apache 下载站获取 sha256 和补丁信息

**解决**: versions.sh 使用 wget 从 `https://downloads.apache.org/httpd/` 获取：
- sha256: `httpd-$VERSION.tar.bz2.sha256`
- 补丁: 检查 `patches/apply_to_$VERSION/` 目录

## 验证命令

```bash
# 语法检查
bash -n library/httpd/get_latest_version.sh
bash -n library/httpd/template/update.sh
bash -n library/httpd/template/apply-templates.sh
bash -n library/httpd/template/versions.sh

# 模板渲染测试（需要先创建 versions.json）
cd library/httpd/template
./versions.sh 2.4.68
./apply-templates.sh 2.4.68

# 检查生成的 Dockerfile
head -20 dockerfiles/2.4.68/alpine/Dockerfile
head -20 dockerfiles/2.4.68/debian/Dockerfile
```

---

# 迁移经验 — library/golang

## 项目特点

golang 是标准 Docker Library 项目：
1. **版本格式**: 完整版本 `1.26.5`（a.b.c）
2. **变体**: 3 个（forky/debian, alpine3.22, alpine3.23）
3. **模板系统**: 上游使用 jq-template.awk，我们使用 sed + 占位符
4. **多架构**: 支持 9 种架构（amd64, armhf, arm64, i386, loong64 等）
5. **特殊逻辑**: ARM 架构需要 GOARM=7 修复

## 核心设计：占位符替代 case 语句生成

**与其他项目的关键区别**：golang 的 Dockerfile 包含复杂的 case 语句（多架构下载链接），我们选择**在模板中保留 case 语句结构，用占位符替代具体的 URL 和 SHA256**，而不是动态生成 case 语句。

### 模板结构

```dockerfile
case "$arch" in
    'amd64')
        url='{URL_AMD64}';
        sha256='{SHA256_AMD64}';
        ;;
    'loong64')
        url='{URL_LOONG64}';
        sha256='{SHA256_LOONG64}';
        ;;
    ...
esac;
```

### update.sh 生成占位符变量

```bash
# 从 go.dev API 获取所有架构的下载信息
new_data=$(wget -qO- 'https://golang.org/dl/?mode=json&include=all' \
    | jq -c --arg ver "$VERSION" '
        [.[] | select(.version == ("go" + $ver))]
        | first
        | {
            version: (.version | ltrimstr("go")),
            amd64_url: (...),
            amd64_sha256: (...),
            loong64_url: (...),
            ...
        }
    ')
```

### apply-templates.sh 纯 sed 替换

```bash
# 提取所有变量
eval "$(echo "$V" | jq -r '"V_URL_AMD64=\(.amd64_url)"')"

# sed 替换
sed -e "s/{URL_AMD64}/$V_URL_AMD64/g" \
    -e "s/{SHA256_AMD64}/$V_SHA256_AMD64/g" \
    ...
    Dockerfile-template > Dockerfile
```

## 模板变量映射

### Debian 变体

| 模板占位符 | API 架构名 | Debian 架构名 |
|-----------|-----------|--------------|
| `{URL_AMD64}` | amd64 | amd64 |
| `{URL_ARMHF}` | armv6l | armhf |
| `{URL_ARM64}` | arm64 | arm64 |
| `{URL_I386}` | 386 | i386 |
| `{URL_LOONG64}` | loong64 | loong64 |

### Alpine 变体

| 模板占位符 | API 架构名 | Alpine 架构名 |
|-----------|-----------|--------------|
| `{URL_AMD64}` | amd64 | x86_64 |
| `{URL_ARMHF}` | armv6l | armv7 |
| `{URL_ARM64}` | arm64 | aarch64 |
| `{URL_I386}` | 386 | x86 |
| `{URL_LOONG64}` | loong64 | loongarch64 |

## 基础镜像前缀

**必须添加 `lcr.loongnix.cn/library/` 前缀**，否则会从 Docker Hub 拉取：

```dockerfile
# 正确
FROM lcr.loongnix.cn/library/buildpack-deps:forky-scm AS build
FROM lcr.loongnix.cn/library/alpine:3.22 AS build

# 错误（会从 Docker Hub 拉取）
FROM buildpack-deps:forky-scm AS build
FROM alpine:3.22 AS build
```

## 文件结构

```
library/golang/
├── get_latest_version.sh              ← 返回完整版本 a.b.c
├── config.yml
├── processed_versions.txt
└── template/
    ├── Dockerfile-forky.template      ← case 语句 + {URL_xxx} {SHA256_xxx}
    ├── Dockerfile-alpine.template     ← 同上，架构名不同
    ├── update.sh                      ← wget + jq → versions.json
    └── apply-templates.sh             ← jq 提取 + sed 渲染
```

## versions.json 结构

```json
{
  "1.26.5": {
    "version": "1.26.5",
    "alpine_version": "3.22 3.23",
    "debian_version": "forky",
    "amd64_url": "https://dl.google.com/go/go1.26.5.linux-amd64.tar.gz",
    "amd64_sha256": "...",
    "loong64_url": "https://dl.google.com/go/go1.26.5.linux-loong64.tar.gz",
    "loong64_sha256": "...",
    ...
  }
}
```

## 设计优势

1. **简单**: 纯 bash + jq + sed，无 Python 依赖
2. **可维护**: 模板结构清晰，与上游 Dockerfile 一一对应
3. **可扩展**: 新增架构只需在模板中添加 case 分支 + update.sh 中添加变量
4. **一致性**: 生成的 Dockerfile 与上游功能逻辑完全一致

## 验证命令

```bash
# 语法检查
bash -n library/golang/get_latest_version.sh
bash -n library/golang/template/update.sh
bash -n library/golang/template/apply-templates.sh

# 模板渲染测试
cd library/golang/template
./update.sh 1.26.5
./apply-templates.sh 1.26.5

# 检查生成的 Dockerfile
head -30 dockerfiles/1.26.5/forky/Dockerfile
head -30 dockerfiles/1.26.5/alpine3.22/Dockerfile
```

## AGENTS.md 编写规范

**目的**: 让 AI 能自动追踪上游变更并微调本地模板

**必须包含的内容**:

### 1. 上游仓库信息
```markdown
## 上游仓库
- **地址**: https://github.com/docker-library/httpd
- **分支**: master
- **当前同步版本**: 2.4.68
```

### 2. 上游仓库结构
```markdown
## 上游结构
```
2.4/
├── Dockerfile              # Debian 变体
├── alpine/Dockerfile       # Alpine 变体
└── httpd-foreground
update.sh                   # 用 sed 直接改 Dockerfile
```
```

### 3. 上游 → 本地转换映射（核心）
```markdown
## 上游 → 本地转换

| 上游 | 本地 | 转换方式 |
|------|------|----------|
| `2.4/Dockerfile` | `template/Dockerfile-debian.template` | 提取为模板，硬编码值替换为 `{VAR}` |
| `2.4/alpine/Dockerfile` | `template/Dockerfile-alpine.template` | 提取为模板，硬编码值替换为 `{VAR}` |
| `update.sh` | `template/update.sh` + `template/versions.sh` | 拆分 |
```

### 4. 模板变量转换规则
```markdown
## 模板变量转换

| 上游 Dockerfile 中的行 | 本地模板 |
|------------------------|----------|
| `ENV HTTPD_VERSION 2.4.68` | `ENV HTTPD_VERSION {VERSION}` |
| `ENV HTTPD_SHA256 68c74d4d...` | `ENV HTTPD_SHA256 {SHA256}` |
| `FROM alpine:3.22` | `FROM alpine:{ALPINE_VERSION}` |
```

### 5. 上游更新时的调整步骤
```markdown
## 上游更新时的调整步骤

1. 对比上游 `2.4/Dockerfile` 和本地 `template/Dockerfile-debian.template`
2. 对比上游 `2.4/alpine/Dockerfile` 和本地 `template/Dockerfile-alpine.template`
3. 合并上游变更，保留 `{VAR}` 占位符
4. 检查是否有新增的环境变量需要添加为模板变量
```
