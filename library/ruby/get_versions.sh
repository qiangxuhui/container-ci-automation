#!/bin/bash
# library/ruby/get_versions.sh
# 输出所有活跃大版本的最新 patch 版本号（每行一个）
set -eo pipefail

# 活跃大版本列表（按需修改）
# 参考 https://www.ruby-lang.org/en/downloads/
MAJOR_VERSIONS="3.3 3.4 4.0"

wget -qO- 'https://github.com/ruby/www.ruby-lang.org/raw/master/_data/releases.yml' \
    | python3 -c "
import sys, yaml

data = yaml.safe_load(sys.stdin)
majors = '$MAJOR_VERSIONS'.split()

for major in majors:
    # 筛选该大版本的非预发布版本
    versions = []
    for r in data:
        v = r.get('version', '')
        # 只要正式发布版（不含 preview/rc）
        if v.startswith(major + '.') and 'preview' not in v and 'rc' not in v:
            versions.append(v)
    if versions:
        # 按版本号排序取最新
        versions.sort(key=lambda x: list(map(int, x.split('.'))))
        print(versions[-1])
"
