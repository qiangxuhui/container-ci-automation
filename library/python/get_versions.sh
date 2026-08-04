#!/bin/bash
# library/python/get_versions.sh
# 输出所有活跃大版本的最新 patch 版本号（每行一个）
set -eo pipefail

# 活跃大版本列表（按需修改）
# 参考 https://devguide.python.org/versions/
MAJOR_VERSIONS="3.10 3.11 3.12 3.13 3.14"

for major in $MAJOR_VERSIONS; do
    wget -qO- 'https://www.python.org/api/v2/downloads/release/?is_published=true&pre_release=false' \
        | jq -r --arg major "$major" '
            [.[]
             | select(.name | test("^Python " + $major + "\\."))
             | {name: .name, date: .release_date}
             | .version = (.name | ltrimstr("Python "))
            ]
            | sort_by(.version | split(".") | map(tonumber))
            | last
            | .version
        ' 2>/dev/null
done
