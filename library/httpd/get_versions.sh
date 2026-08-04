#!/bin/bash
# library/httpd/get_versions.sh
# 输出最新版本号（1 行）
set -eo pipefail

readonly ORG='apache'
readonly PROJ='httpd'

# 获取 GitHub tags，过滤语义版本，输出最新版本
git ls-remote --tags "https://github.com/$ORG/$PROJ.git" \
    | cut -d'/' -f3- \
    | cut -d'^' -f1 \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -rV \
    | head -1
