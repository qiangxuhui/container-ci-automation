#!/usr/bin/env bash
# library/php/get_versions.sh
# 获取 PHP 最新稳定版本（每个活跃大版本一个）
set -Eeuo pipefail

# 活跃的 PHP 大版本（不含开发版 8.5）
MAJOR_VERSIONS=(8.2 8.3 8.4)

now="$(date --utc '+%s')"

for major in "${MAJOR_VERSIONS[@]}"; do
    # 查询 PHP API 获取该大版本所有发布版本
    apiUrl="https://www.php.net/releases/index.php?json&max=100&version=${major}"
    apiUrl+="&cachebuster=$now"

    # 获取最新稳定版本（排除 RC）
    latest=$(curl -fsSL "$apiUrl" 2>/dev/null | jq -r '
        keys[]
        | select(test("^'"$major"'\\.") and test("-rc") | not)
        | .
    ' | sort -rV | head -1)

    if [[ -n "$latest" ]]; then
        echo "$latest"
    fi
done
