#!/bin/bash
# library/httpd/template/update.sh
# 接收版本号，从 Apache 下载站获取 sha256 和补丁信息，生成 versions.json
set -eo pipefail

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

VERSION="$1"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 2.4.68"
    exit 1
fi

if [[ -f versions.json ]] && [[ -s versions.json ]]; then
    json=$(< versions.json)
else
    json='{}'
fi

alpine='3.22'
debian='trixie'

# 获取 sha256
sha256=$(wget -qO- "https://downloads.apache.org/httpd/httpd-$VERSION.tar.bz2.sha256" | cut -d' ' -f1)

# 检查是否有补丁
patches=""
patchesUrl="https://downloads.apache.org/httpd/patches/apply_to_$VERSION"
if wget --quiet --spider -O /dev/null -o /dev/null "$patchesUrl/"; then
    patchFiles=$(
        wget -qO- "$patchesUrl/?C=M;O=A" \
            | grep -oE 'href="[^"]+[.]patch"' \
            | cut -d'"' -f2 \
            || true
    )
    for patchFile in $patchFiles; do
        patchSha256=$(wget -qO- "$patchesUrl/$patchFile" | sha256sum | cut -d' ' -f1)
        patches="$patches $patchFile $patchSha256"
    done
fi

echo "version: $VERSION, sha256: ${sha256:0:16}..." >&2

# 生成扁平化的 versions.json
json=$(echo "$json" | jq -c \
    --arg v "$VERSION" \
    --arg sha256 "$sha256" \
    --arg alpine "$alpine" \
    --arg debian "$debian" \
    --arg patches "$patches" \
    '.[$v] = {
        version: $v,
        sha256: $sha256,
        alpine_version: $alpine,
        debian_version: $debian,
        patches: $patches
    }')

echo "$json" | jq -S . > versions.json

echo "Version info saved to versions.json"
