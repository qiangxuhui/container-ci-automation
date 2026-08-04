#!/bin/bash
# library/debian/template/update.sh
# 接收版本号，构建 rootfs，生成 versions.json
set -eo pipefail

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

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

# ===== 变体版本集中管理 =====
DEBIAN_VERSION="14"
DEBIAN_VERSION_NAME="forky"
SUITE="unstable"
ARCH="loong64"

# 版本名映射（备用）
declare -A VERSION_NAMES=(
    ["14"]="forky"
    ["13"]="trixie"
    ["12"]="bookworm"
    ["11"]="bullseye"
    ["10"]="buster"
)
DEBIAN_VERSION_NAME="${VERSION_NAMES[$DEBIAN_VERSION]}"

echo "Building rootfs for Debian $DEBIAN_VERSION ($DEBIAN_VERSION_NAME)"

# 创建输出目录
mkdir -p out

# 转换时间格式
format_time() {
    echo "$1" | sed -E 's/([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})/\1-\2-\3T\4:\5:\6/'
}

# 构建 rootfs
formatted=$(format_time "$VERSION")
timestamp=$(date -d "$formatted" +%s)

echo "Building rootfs with debuerreotype..."
docker run --privileged -v "$(pwd)/out":/v -w /v \
    -e https_proxy="$https_proxy" \
    -e http_proxy="$http_proxy" \
    debuerreotype/debuerreotype:latest \
    /opt/debuerreotype/examples/debian.sh --arch "$ARCH" . "$SUITE" "@$timestamp"

echo "Rootfs built successfully"

# 生成 versions.json
if [[ -f versions.json ]]; then
    json=$(< versions.json)
else
    json='{}'
fi

json=$(echo "$json" | jq -c \
    --arg v "$VERSION" \
    --arg debian_ver "$DEBIAN_VERSION" \
    --arg debian_name "$DEBIAN_VERSION_NAME" \
    --arg suite "$SUITE" \
    --arg arch "$ARCH" \
    '.[$v] = {
        version: $v,
        debian_version: $debian_ver,
        debian_version_name: $debian_name,
        suite: $suite,
        arch: $arch
    }')

echo "$json" | jq -S . > versions.json

echo "Version info saved to versions.json"
