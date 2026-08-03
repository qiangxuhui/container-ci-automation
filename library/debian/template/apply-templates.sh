#!/bin/bash
# library/debian/template/apply-templates.sh
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

# 读取 debian 版本
DEBIAN_VERSION=$(cat "$(dirname "$0")/debian.version")
readonly -A DEBIAN_VERSIONS=(
    ["14"]="forky"
    ["13"]="trixie"
    ["12"]="bookworm"
    ["11"]="bullseye"
    ["10"]="buster"
)
DEBIAN_VERSION_NAME="${DEBIAN_VERSIONS[$DEBIAN_VERSION]}"
readonly SUITE='unstable'
readonly ARCH='loong64'
readonly OUT_DIR='out'

# 从版本号提取日期部分
# 20250521T073957Z -> 20250521
TIME_VERSION="${VERSION%T*}"

echo "Generating Dockerfiles for version $VERSION"

# debuerreotype 输出结构:
#   out/{date}/{arch}/{suite}/           <- standard 变体 (rootfs 文件直接在这里)
#   out/{date}/{arch}/{suite}/slim/     <- slim 变体

SUITE_DIR="$OUT_DIR/$TIME_VERSION/$ARCH/$SUITE"

if [[ ! -d "$SUITE_DIR" ]]; then
    echo "ERROR: Suite directory not found: $SUITE_DIR"
    exit 1
fi

# 定义变体: "变体名:模板文件:rootfs来源目录"
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

    # 创建输出目录
    mkdir -p "$DOCKERFILES_DIR/$VERSION/$variant"

    # 生成 Dockerfile
    sed -e "s/{VERSION}/$VERSION/g" \
        -e "s/{DEBIAN_VERSION}/$DEBIAN_VERSION/g" \
        -e "s/{DEBIAN_VERSION_NAME}/$DEBIAN_VERSION_NAME/g" \
        -e "s/{SUITE}/$SUITE/g" \
        -e "s/{TIME_VERSION}/$TIME_VERSION/g" \
        "$template_file" > "$DOCKERFILES_DIR/$VERSION/$variant/Dockerfile"

    # 复制 rootfs 到构建目录
    cp "$rootfs_dir/rootfs.tar.xz" "$DOCKERFILES_DIR/$VERSION/$variant/"

    echo "  生成: dockerfiles/$VERSION/$variant/Dockerfile"
done
