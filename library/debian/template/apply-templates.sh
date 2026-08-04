#!/bin/bash
# library/debian/template/apply-templates.sh
# 接收版本号，读取 versions.json，生成 Dockerfile 到 dockerfiles/ 目录
set -eo pipefail

VERSION="$1"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    exit 1
fi

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

PROJECT_DIR="$(cd .. && pwd)"
DOCKERFILES_DIR="$PROJECT_DIR/dockerfiles"

if [[ ! -f versions.json ]]; then
    echo "ERROR: versions.json not found. Run update.sh first."
    exit 1
fi

# 从 versions.json 提取变量
V=$(jq -r --arg v "$VERSION" '.[$v] // empty' versions.json)
if [[ -z "$V" ]]; then
    echo "ERROR: Version $VERSION not found in versions.json"
    exit 1
fi

eval "$(echo "$V" | jq -r '
    "DEBIAN_VERSION=\(.debian_version)",
    "DEBIAN_VERSION_NAME=\(.debian_version_name)",
    "SUITE=\(.suite)",
    "ARCH=\(.arch)
')"

# 从版本号提取日期部分
TIME_VERSION="${VERSION%T*}"

echo "Generating Dockerfiles for version $VERSION (Debian $DEBIAN_VERSION $DEBIAN_VERSION_NAME)"

# debuerreotype 输出结构
SUITE_DIR="out/$TIME_VERSION/$ARCH/$SUITE"

if [[ ! -d "$SUITE_DIR" ]]; then
    echo "ERROR: Suite directory not found: $SUITE_DIR"
    exit 1
fi

# 定义变体
declare -a VARIANTS=(
    "standard:Dockerfile-standard.template:$SUITE_DIR"
    "slim:Dockerfile-slim.template:$SUITE_DIR/slim"
)

for variant_def in "${VARIANTS[@]}"; do
    IFS=':' read -r variant template_file rootfs_dir <<< "$variant_def"

    if [[ ! -d "$rootfs_dir" ]]; then
        echo "  跳过变体 '$variant': 目录不存在 $rootfs_dir"
        continue
    fi

    echo "  处理变体: $variant"

    mkdir -p "$DOCKERFILES_DIR/$VERSION/$variant"

    sed -e "s/{VERSION}/$VERSION/g" \
        -e "s/{DEBIAN_VERSION}/$DEBIAN_VERSION/g" \
        -e "s/{DEBIAN_VERSION_NAME}/$DEBIAN_VERSION_NAME/g" \
        -e "s/{SUITE}/$SUITE/g" \
        -e "s/{TIME_VERSION}/$TIME_VERSION/g" \
        "$template_file" > "$DOCKERFILES_DIR/$VERSION/$variant/Dockerfile"

    cp "$rootfs_dir/rootfs.tar.xz" "$DOCKERFILES_DIR/$VERSION/$variant/"

    echo "  生成: dockerfiles/$VERSION/$variant/Dockerfile"
done
