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
DEBIAN_VERSION=$(cat "$(dirname "$0")/../debian.version")
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

# 遍历变体目录
for variant_dir in "$OUT_DIR/$TIME_VERSION/$ARCH/$SUITE"/*/; do
    [[ -d "$variant_dir" ]] || continue
    variant=$(basename "$variant_dir")
    
    echo "  Processing variant: $variant"
    
    # 创建输出目录
    mkdir -p "$VERSION/$variant"
    
    # 生成 Dockerfile
    sed -e "s/{VERSION}/$VERSION/g" \
        -e "s/{DEBIAN_VERSION}/$DEBIAN_VERSION/g" \
        -e "s/{DEBIAN_VERSION_NAME}/$DEBIAN_VERSION_NAME/g" \
        -e "s/{SUITE}/$SUITE/g" \
        -e "s/{TIME_VERSION}/$TIME_VERSION/g" \
        Dockerfile.template > "$VERSION/$variant/Dockerfile"
    
    # 复制 rootfs 到构建目录
    cp "$variant_dir/rootfs.tar.xz" "$VERSION/$variant/"
    
    echo "  Generated: $VERSION/$variant/Dockerfile"
done
