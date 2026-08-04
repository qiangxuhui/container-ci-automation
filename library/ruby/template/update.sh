#!/usr/bin/env bash
# library/ruby/template/update.sh
# 接收版本号，从 ruby-lang.org 获取 checksum，生成 versions.json
set -Eeuo pipefail

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

VERSION="$1"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 3.3.12"
    exit 1
fi

if [[ -f versions.json ]] && [[ -s versions.json ]]; then
    json=$(< versions.json)
else
    json='{}'
fi

# 变体版本（集中管理）
alpine_version="3.24"
debian_version="forky"

# 提取版本信息
# VERSION="3.3.12" → MAJOR_MINOR="3.3"
MAJOR_MINOR="${VERSION%.*}"

# === 获取版本元数据 ===
# 从 ruby-lang.org releases.yml 获取版本信息
echo "Fetching metadata for Ruby $VERSION..." >&2

RELEASES_DATA=$(wget -qO- 'https://github.com/ruby/www.ruby-lang.org/raw/master/_data/releases.yml' 2>/dev/null)

# 使用 python3 解析 YAML（比 yq 更可靠）
METADATA=$(echo "$RELEASES_DATA" | python3 -c "
import sys, yaml, json

data = yaml.safe_load(sys.stdin)
version = '$VERSION'

for r in data:
    if r.get('version') == version:
        result = {
            'date': str(r.get('date', '')),
            'post': r.get('post', ''),
            'url_xz': r.get('url', {}).get('xz', ''),
            'sha256_xz': r.get('sha256', {}).get('xz', ''),
        }
        print(json.dumps(result))
        sys.exit(0)

print('{}')
")

if [[ -z "$METADATA" ]] || [[ "$METADATA" == "{}" ]]; then
    echo "error: Ruby $VERSION not found in upstream releases" >&2
    exit 1
fi

DATE=$(echo "$METADATA" | jq -r '.date')
POST=$(echo "$METADATA" | jq -r '.post | ltrimstr("/")')
URL_XZ=$(echo "$METADATA" | jq -r '.url_xz')
SHA256_XZ=$(echo "$METADATA" | jq -r '.sha256_xz')

if [[ -z "$URL_XZ" ]] || [[ "$URL_XZ" == "null" ]]; then
    echo "error: No xz download URL for Ruby $VERSION" >&2
    exit 1
fi

echo "  date: $DATE" >&2
echo "  url: $URL_XZ" >&2
echo "  sha256: $SHA256_XZ" >&2

# === Rust 版本 ===
# Ruby 3.3+ 支持 YJIT（需要 Rust），4.0+ 支持 ZJIT
# 使用上游当前的 Rust 版本
RUST_VERSION="1.91.1"

# === 构建版本数据 ===
new_data=$(
    jq -n \
        --arg version "$VERSION" \
        --arg date "$DATE" \
        --arg post "$POST" \
        --arg url_xz "$URL_XZ" \
        --arg sha256_xz "$SHA256_XZ" \
        --arg rust_version "$RUST_VERSION" \
        --arg alpine_version "$alpine_version" \
        --arg debian_version "$debian_version" \
        '{
            version: $version,
            date: $date,
            post: $post,
            url_xz: $url_xz,
            sha256_xz: $sha256_xz,
            rust_version: $rust_version,
            alpine_version: $alpine_version,
            debian_version: $debian_version
        }'
)

json=$(echo "$json" | jq -c --argjson d "$new_data" '.[$d.version] = $d')
echo "$json" | jq -S . > versions.json

echo "Version info saved to versions.json" >&2
