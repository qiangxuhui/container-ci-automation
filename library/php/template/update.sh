#!/usr/bin/env bash
# library/php/template/update.sh
# 接收版本号，从 PHP API 获取元数据，生成 versions.json
# 注意：versions.json 以 major.minor 为 key（如 "8.4"），与上游一致
#       模板中 env.version 用于 JSON 查找和 GPG keys，必须是 major.minor 格式
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VERSION="$1"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 8.4.24"
    exit 1
fi

# 变体版本（集中管理）
alpine_version="3.24"
debian_version="forky"

# 去掉 -rc 后缀获取基础版本号
rcVersion="${VERSION%-rc}"

# 查询 PHP API 获取版本元数据
now="$(date --utc '+%s')"
apiUrl="https://www.php.net/releases/index.php?json&max=100&version=${rcVersion%%.*}"
apiUrl+="&cachebuster=$now"

echo "Fetching metadata for PHP $VERSION..." >&2

# 获取版本信息
possibles=$(curl -fsSL "$apiUrl" 2>/dev/null | jq --raw-output --arg v "$rcVersion" '
    (keys[] | select(startswith($v))) as $version
    | [ $version, (
        .[$version].source[]
        | select(.filename | endswith(".xz"))
        |
            "https://www.php.net/distributions/" + .filename,
            "https://www.php.net/distributions/" + .filename + ".asc",
            .sha256 // ""
    ) ] | @sh
' | sort -rV | head -1)

if [[ -z "$possibles" ]]; then
    echo "error: PHP $VERSION not found in upstream releases" >&2
    exit 1
fi

# 解析结果
eval "possi=( $possibles )"
fullVersion="${possi[0]}"
url="${possi[1]}"
ascUrl="${possi[2]}"
sha256="${possi[3]}"

# 验证下载 URL
if ! curl --head -fsSL "$url" -o /dev/null 2>/dev/null; then
    echo "error: '$url' appears to be missing" >&2
    exit 1
fi

# 如果没有 ASC URL，假设一个
if [[ -z "$ascUrl" ]]; then
    ascUrl="$url.asc"
fi

echo "  version: $fullVersion" >&2
echo "  url: $url" >&2
echo "  sha256: $sha256" >&2

# 提取主版本号和次版本号
major_version="${fullVersion%%.*}"
minor_version="${fullVersion%.*}"

# 读取现有 versions.json
if [[ -f versions.json ]] && [[ -s versions.json ]]; then
    json=$(< versions.json)
else
    json='{}'
fi

# 构建版本数据
# key 使用 major.minor 格式（如 "8.4"），与上游一致
# 模板中 env.version 用于 JSON 查找 .[env.version] 和 GPG keys 查找
new_data=$(
    jq -n \
        --arg version "$fullVersion" \
        --arg url "$url" \
        --arg ascUrl "$ascUrl" \
        --arg sha256 "$sha256" \
        --arg major_version "$major_version" \
        --arg minor_version "$minor_version" \
        --arg alpine_version "$alpine_version" \
        --arg debian_version "$debian_version" \
        '{
            version: $version,
            url: $url,
            ascUrl: $ascUrl,
            sha256: $sha256,
            major_version: $major_version,
            minor_version: $minor_version,
            alpine_version: $alpine_version,
            debian_version: $debian_version
        }'
)

# key 使用 minor_version（major.minor），与上游一致
json=$(echo "$json" | jq -c --argjson d "$new_data" '.[$d.minor_version] = $d')
echo "$json" | jq -S . > versions.json

echo "Version info saved to versions.json" >&2
