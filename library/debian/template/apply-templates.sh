#!/bin/bash
# library/debian/template/apply-templates.sh
# 接收版本号，生成 Dockerfile
set -eo pipefail

VERSION="$1"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    exit 1
fi

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
#   out/{date}/{arch}/{suite}/           <- 标准变体 (rootfs 文件直接在这里)
#   out/{date}/{arch}/{suite}/slim/     <- slim 变体

SUITE_DIR="$OUT_DIR/$TIME_VERSION/$ARCH/$SUITE"

if [[ ! -d "$SUITE_DIR" ]]; then
    echo "ERROR: Suite directory not found: $SUITE_DIR"
    exit 1
fi

# 定义变体列表: "变体名:rootfs来源目录"
declare -a VARIANTS=(
    ":$SUITE_DIR"
    "slim:$SUITE_DIR/slim"
)

for variant_def in "${VARIANTS[@]}"; do
    variant="${variant_def%%:*}"
    rootfs_dir="${variant_def#*:}"

    if [[ ! -d "$rootfs_dir" ]]; then
        echo "  跳过变体 '$variant': 目录不存在 $rootfs_dir"
        continue
    fi

    echo "  处理变体: ${variant:-standard}"

    # 创建输出目录
    if [[ -z "$variant" ]]; then
        build_dir="$VERSION"
    else
        build_dir="$VERSION/$variant"
    fi
    mkdir -p "$build_dir"

    # 生成 Dockerfile
    sed -e "s/{VERSION}/$VERSION/g" \
        -e "s/{DEBIAN_VERSION}/$DEBIAN_VERSION/g" \
        -e "s/{DEBIAN_VERSION_NAME}/$DEBIAN_VERSION_NAME/g" \
        -e "s/{SUITE}/$SUITE/g" \
        -e "s/{TIME_VERSION}/$TIME_VERSION/g" \
        Dockerfile.template > "$build_dir/Dockerfile"

    # 复制 rootfs 到构建目录
    cp "$rootfs_dir/rootfs.tar.xz" "$build_dir/"

    echo "  生成: $build_dir/Dockerfile"
done
