#!/bin/bash
# library/debian/get_latest_version.sh
# 输出最新版本号（1 行）
set -eo pipefail

DEBIAN_MIRROR='https://snapshot.debian.org/archive/debian'

year=$(date +%Y)
month=$(date +%m)

version=$(wget -qO- "$DEBIAN_MIRROR?year=$year&month=$month" \
    | grep -oE 'href="[0-9]{8}T[0-9]{6}Z/"' \
    | tail -1 \
    | cut -d '"' -f 2 | cut -d '/' -f 1)

echo "$version"
