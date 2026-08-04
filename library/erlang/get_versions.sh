#!/bin/bash
# library/erlang/get_versions.sh
# 输出每个活跃大版本（24-29）的最新 OTP patch 版本号（每行一个）
set -eo pipefail

# 活跃大版本列表
#MAJOR_VERSIONS="24 25 26 27 28 29"
MAJOR_VERSIONS="29"

for major in $MAJOR_VERSIONS; do
    # 从 GitHub releases 获取该大版本的最新稳定 release
    # erlang/otp 的 tag 格式: OTP-28.5.0.4
    # 排除 release candidates (-rc)
    # 使用 jq -s 合并多页结果
    version=$(gh api "repos/erlang/otp/releases" --paginate | jq -s -r "
        [.[] | .[] | select(.tag_name | startswith(\"OTP-$major.\") and (test(\"-rc\") | not)) | .tag_name |
         ltrimstr(\"OTP-\")] | sort_by(split(\".\") | map(tonumber)) | last
    " 2>/dev/null || true)

    if [[ -n "$version" ]]; then
        echo "$version"
    fi
done
