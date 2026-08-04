#!/bin/bash
# library/node/get_versions.sh
# 输出所有活跃大版本的最新 patch 版本号（每行一个）
# 从 unofficial-builds 获取（因为 nodejs.org 没有 loong64 二进制）
set -eo pipefail

# 活跃大版本列表（按需修改）
#MAJOR_VERSIONS="22 24 26"
MAJOR_VERSIONS="26"

wget -qO- 'https://unofficial-builds.nodejs.org/download/release/' \
    | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' \
    | sort -V \
    | uniq \
    | awk -v majors="$MAJOR_VERSIONS" '
BEGIN {
    n = split(majors, mv, " ")
    for (i = 1; i <= n; i++) active[mv[i]] = 1
}
{
    split($0, v, ".")
    major = v[1]
    if (major in active) {
        latest[major] = $0
    }
}
END {
    for (maj in latest) print latest[maj]
}' \
    | sort -t. -k1,1n -k2,2n -k3,3n
