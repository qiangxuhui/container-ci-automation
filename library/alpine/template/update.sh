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
ROOTFS_URL="https://cz.alpinelinux.org/alpine/v${VERSION}/releases/loongarch64/alpine-minirootfs-${VERSION}-loongarch64.tar.gz"
echo "Downloading rootfs from: $ROOTFS_URL"

mkdir -p out
wget -q -O "out/rootfs.tar.gz" "$ROOTFS_URL"

echo "Rootfs downloaded: out/rootfs.tar.gz"
