#!/bin/bash
# library/debian/template/update.sh
# 接收版本号，构建 rootfs
set -eo pipefail

VERSION="$1"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 20250521T073957Z"
    exit 1
fi

# 验证版本格式
if [[ ! "$VERSION" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
    echo "ERROR: Invalid version format: $VERSION"
    echo "Expected format: 20250501T015255Z"
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

echo "Building rootfs for Debian $DEBIAN_VERSION ($DEBIAN_VERSION_NAME)"

# 创建输出目录
mkdir -p "$OUT_DIR"

# 转换时间格式
# 20250521T073957Z -> 2025-05-21T07:39:57Z
format_time() {
    echo "$1" | sed -E 's/([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})/\1-\2-\3T\4:\5:\6/'
}

# 构建 rootfs
formatted=$(format_time "$VERSION")
timestamp=$(date -d "$formatted" +%s)

echo "Building rootfs with debuerreotype..."
docker run --privileged -v "$(pwd)/$OUT_DIR":/v -w /v \
    -e https_proxy="$https_proxy" \
    -e http_proxy="$http_proxy" \
    debuerreotype/debuerreotype:latest \
    /opt/debuerreotype/examples/debian.sh --arch "$ARCH" . "$SUITE" "@$timestamp"

echo "Rootfs built successfully"
