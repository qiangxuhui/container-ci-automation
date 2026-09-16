#!/bin/bash
# library/alpine/template/update.sh
# 接收版本号，下载 rootfs
set -eo pipefail

VERSION="$1"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 3.24.1"
    exit 1
fi

# 验证版本格式
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Invalid version format: $VERSION"
    echo "Expected format: 3.24.1"
    exit 1
fi

# 计算 minor version
MINOR_VERSION="${VERSION%.*}"

# 下载 rootfs
# 注意：Alpine 官方发布目录使用 major.minor（如 v3.24），不是完整版本号
ROOTFS_URL="https://cz.alpinelinux.org/alpine/v${MINOR_VERSION}/releases/loongarch64/alpine-minirootfs-${VERSION}-loongarch64.tar.gz"
echo "Downloading rootfs from: $ROOTFS_URL"

mkdir -p out
# 下载失败时打印 URL 便于排查
wget -q -O "out/rootfs.tar.gz" "$ROOTFS_URL" || {
    echo "ERROR: 下载失败: $ROOTFS_URL"
    exit 1
}

echo "Rootfs downloaded: out/rootfs.tar.gz"
