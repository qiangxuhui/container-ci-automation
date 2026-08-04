#!/usr/bin/env bash
# library/node/template/apply-templates.sh
# 接收版本号，读取 versions.json，使用 sed 渲染模板生成 Dockerfile
set -Eeuo pipefail

VERSION="$1"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 26.5.1"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKERFILES_DIR="$PROJECT_DIR/dockerfiles"

if [[ ! -f "$SCRIPT_DIR/versions.json" ]]; then
    echo "ERROR: versions.json not found. Run update.sh first."
    exit 1
fi

V=$(jq -r --arg v "$VERSION" '.[$v] // empty' "$SCRIPT_DIR/versions.json")
if [[ -z "$V" ]]; then
    echo "ERROR: Version $VERSION not found in versions.json"
    exit 1
fi

# 提取变量
V_VERSION=$(echo "$V" | jq -r '.version')
V_DEBIAN=$(echo "$V" | jq -r '.debian_version')
V_ALPINE=$(echo "$V" | jq -r '.alpine_version')
V_LOONG64_SHA256=$(echo "$V" | jq -r '.loong64_sha256')

# 提取 GPG 公钥，格式化为 Dockerfile 中的格式
# 每行一个 key，带缩进和续行符
V_NODE_KEYS=$(echo "$V" | jq -r '.node_keys' | while IFS= read -r key; do
    [[ -n "$key" ]] && printf '    %s \\\n' "$key"
done | sed '$ s/ \\$//')  # 最后一行去掉续行符

echo "Generating Dockerfiles for node $V_VERSION"

# Docker-entrypoint.sh 路径
ENTRYPOINT_SRC="$SCRIPT_DIR/docker-entrypoint.sh"

# === Debian 变体 ===
DEBIAN_DIR="$DOCKERFILES_DIR/$V_VERSION/debian"
mkdir -p "$DEBIAN_DIR"
cp "$ENTRYPOINT_SRC" "$DEBIAN_DIR/docker-entrypoint.sh"

# 使用临时文件处理多行替换
tmp_file=$(mktemp)
trap "rm -f $tmp_file" EXIT

sed \
    -e "s/{VERSION}/$V_VERSION/g" \
    -e "s/{DEBIAN_VERSION}/$V_DEBIAN/g" \
    -e "s/{LOONG64_SHA256}/$V_LOONG64_SHA256/g" \
    "$SCRIPT_DIR/Dockerfile-debian.template" > "$tmp_file"

# 替换多行 NODE_KEYS
python3 - "$tmp_file" "$DEBIAN_DIR/Dockerfile" "$V_NODE_KEYS" << 'PYEOF'
import sys

template_file = sys.argv[1]
output_file = sys.argv[2]
node_keys = sys.argv[3]

with open(template_file) as f:
    content = f.read()

content = content.replace('{NODE_KEYS}', node_keys)

with open(output_file, 'w') as f:
    f.write(content)
PYEOF

echo "  dockerfiles/$V_VERSION/debian/Dockerfile"

# === Debian-slim 变体 ===
SLIM_DIR="$DOCKERFILES_DIR/$V_VERSION/debian-slim"
mkdir -p "$SLIM_DIR"
cp "$ENTRYPOINT_SRC" "$SLIM_DIR/docker-entrypoint.sh"

sed \
    -e "s/{VERSION}/$V_VERSION/g" \
    -e "s/{DEBIAN_VERSION}/$V_DEBIAN/g" \
    -e "s/{LOONG64_SHA256}/$V_LOONG64_SHA256/g" \
    "$SCRIPT_DIR/Dockerfile-debian-slim.template" > "$tmp_file"

python3 - "$tmp_file" "$SLIM_DIR/Dockerfile" "$V_NODE_KEYS" << 'PYEOF'
import sys

template_file = sys.argv[1]
output_file = sys.argv[2]
node_keys = sys.argv[3]

with open(template_file) as f:
    content = f.read()

content = content.replace('{NODE_KEYS}', node_keys)

with open(output_file, 'w') as f:
    f.write(content)
PYEOF

echo "  dockerfiles/$V_VERSION/debian-slim/Dockerfile"

# === Alpine 变体 ===
ALPINE_DIR="$DOCKERFILES_DIR/$V_VERSION/alpine"
mkdir -p "$ALPINE_DIR"
cp "$ENTRYPOINT_SRC" "$ALPINE_DIR/docker-entrypoint.sh"

# 提取主版本号，用于版本条件判断
V_MAJOR="${V_VERSION%%.*}"

# 根据主版本号确定构建依赖
# Node 26+ 需要 rust/cargo（Temporal 特性）
if [[ "$V_MAJOR" -ge 26 ]]; then
    V_BUILD_DEPS=$(printf '        g++ \\\n        gcc \\\n        gnupg \\\n        libgcc \\\n        linux-headers \\\n        make \\\n        python3 \\\n        py-setuptools \\\n        rust \\\n        cargo')
else
    V_BUILD_DEPS=$(printf '        g++ \\\n        gcc \\\n        gnupg \\\n        libgcc \\\n        linux-headers \\\n        make \\\n        python3 \\\n        py-setuptools')
fi

# 根据主版本号确定 Yarn 安装段
# Node 26+ 移除 Yarn v1
if [[ "$V_MAJOR" -ge 26 ]]; then
    V_YARN_SECTION=""
else
    V_YARN_SECTION=$'\nENV YARN_VERSION=1.22.22\n\nRUN apk add --no-cache --virtual .build-deps-yarn curl gnupg tar \\\n  # use pre-existing gpg directory, see https://github.com/nodejs/docker-node/pull/1895#issuecomment-1550389150\n  && export GNUPGHOME="$(mktemp -d)" \\\n  && for key in \\\n    6A010C5166006599AA17F08146C2130DFD2497F5 \\\n  ; do \\\n    { gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "$key" && gpg --batch --fingerprint "$key"; } || \\\n    { gpg --batch --keyserver keyserver.ubuntu.com --recv-keys "$key" && gpg --batch --fingerprint "$key"; } ; \\\n  done \\\n  && curl -fsSLO --compressed "https://yarnpkg.com/downloads/$YARN_VERSION/yarn-v$YARN_VERSION.tar.gz" \\\n  && curl -fsSLO --compressed "https://yarnpkg.com/downloads/$YARN_VERSION/yarn-v$YARN_VERSION.tar.gz.asc" \\\n  && gpg --batch --verify yarn-v$YARN_VERSION.tar.gz.asc yarn-v$YARN_VERSION.tar.gz \\\n  && gpgconf --kill all \\\n  && rm -rf "$GNUPGHOME" \\\n  && mkdir -p /opt \\\n  && tar -xzf yarn-v$YARN_VERSION.tar.gz -C /opt/ \\\n  && ln -s /opt/yarn-v$YARN_VERSION/bin/yarn /usr/local/bin/yarn \\\n  && ln -s /opt/yarn-v$YARN_VERSION/bin/yarnpkg /usr/local/bin/yarnpkg \\\n  && rm yarn-v$YARN_VERSION.tar.gz.asc yarn-v$YARN_VERSION.tar.gz \\\n  && apk del .build-deps-yarn \\\n  # smoke test\n  && yarn --version \\\n  && rm -rf /tmp/*'
fi

sed \
    -e "s/{VERSION}/$V_VERSION/g" \
    -e "s/{ALPINE_VERSION}/$V_ALPINE/g" \
    "$SCRIPT_DIR/Dockerfile-alpine.template" > "$tmp_file"

python3 - "$tmp_file" "$ALPINE_DIR/Dockerfile" "$V_NODE_KEYS" "$V_BUILD_DEPS" "$V_YARN_SECTION" << 'PYEOF'
import sys

template_file = sys.argv[1]
output_file = sys.argv[2]
node_keys = sys.argv[3]
build_deps = sys.argv[4]
yarn_section = sys.argv[5]

with open(template_file) as f:
    content = f.read()

content = content.replace('{NODE_KEYS}', node_keys)
content = content.replace('{BUILD_DEPS}', build_deps)
content = content.replace('{YARN_SECTION}', yarn_section)

with open(output_file, 'w') as f:
    f.write(content)
PYEOF

echo "  dockerfiles/$V_VERSION/alpine/Dockerfile"

echo "Done."
