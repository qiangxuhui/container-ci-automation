#!/bin/bash
# library/alpine/get_versions.sh
# 输出最新版本号（1 行）
set -eo pipefail

wget -qO- https://cz.alpinelinux.org/alpine/latest-stable/releases/loongarch64 \
    | grep -oP 'minirootfs-\K[\d\.]+(?=-loongarch64\.tar\.gz)' \
    | sort -V \
    | tail -1
