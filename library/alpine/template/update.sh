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
# 注意：Alpine 发布目录按「次版本号」组织（v3.24），完整版本号只出现在文件名里（v3.24.1）
ROOTFS_URL="https://cz.alpinelinux.org/alpine/v${MINOR_VERSION}/releases/loongarch64/alpine-minirootfs-${VERSION}-loongarch64.tar.gz"
echo "Downloading rootfs from: $ROOTFS_URL"

mkdir -p out
if ! wget -q -O "out/rootfs.tar.gz" "$ROOTFS_URL"; then
    rm -f out/rootfs.tar.gz
    echo "ERROR: rootfs 下载失败: $ROOTFS_URL" >&2
    exit 1
fi

# 下载失败时 wget 可能留下空文件，防御空产物流入构建
if [[ ! -s out/rootfs.tar.gz ]]; then
    echo "ERROR: rootfs 文件为空: out/rootfs.tar.gz" >&2
    exit 1
fi

echo "Rootfs downloaded: out/rootfs.tar.gz"
