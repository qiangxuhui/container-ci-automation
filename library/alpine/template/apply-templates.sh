#!/bin/bash
# library/alpine/template/apply-templates.sh
# 接收版本号，生成 Dockerfile 到 dockerfiles/ 目录
set -eo pipefail

VERSION="$1"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    exit 1
fi

# 项目根目录（template 的上级目录）
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# 输出目录
DOCKERFILES_DIR="$PROJECT_DIR/dockerfiles"

# 计算版本变量
MINOR_VERSION="${VERSION%.*}"
MAJOR_VERSION="${MINOR_VERSION%.*}"

echo "Generating Dockerfiles for version $VERSION"

# alpine 只有一个变体
VARIANT="alpine"

# 创建输出目录
mkdir -p "$DOCKERFILES_DIR/$VERSION/$VARIANT"

# 生成 Dockerfile
sed -e "s/{VERSION}/$VERSION/g" \
    -e "s/{MINOR_VERSION}/$MINOR_VERSION/g" \
    -e "s/{MAJOR_VERSION}/$MAJOR_VERSION/g" \
    Dockerfile-alpine.template > "$DOCKERFILES_DIR/$VERSION/$VARIANT/Dockerfile"

# 复制 rootfs 到构建目录
cp out/rootfs.tar.gz "$DOCKERFILES_DIR/$VERSION/$VARIANT/"

echo "  生成: dockerfiles/$VERSION/$VARIANT/Dockerfile"
