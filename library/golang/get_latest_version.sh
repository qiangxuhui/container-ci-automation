#!/bin/bash
# library/golang/get_latest_version.sh
# 输出最新稳定版本号（1 行），格式 a.b.c
set -eo pipefail

wget -qO- 'https://go.dev/dl/?mode=json' \
    | jq -r '.[0].version' \
    | sed 's/^go//'
