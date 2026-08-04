#!/usr/bin/env bash
# library/node/template/update.sh
# 接收版本号，从 unofficial-builds 获取 loong64 信息，生成 versions.json
set -Eeuo pipefail

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

VERSION="$1"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 26.5.1"
    exit 1
fi

if [[ -f versions.json ]] && [[ -s versions.json ]]; then
    json=$(< versions.json)
else
    json='{}'
fi

# 基础镜像版本（集中管理）
debian_version="forky"
alpine_version="3.24"

# 获取 GPG 公钥（从上游仓库）
node_keys=$(wget -qO- 'https://raw.githubusercontent.com/nodejs/docker-node/master/keys/node.keys')

# 获取 loong64 glibc 二进制的 SHA256（用于 Debian 变体）
loong64_sha256=$(wget -qO- "https://unofficial-builds.nodejs.org/download/release/v${VERSION}/SHASUMS256.txt" \
    | grep "node-v${VERSION}-linux-loong64.tar.xz" \
    | cut -d' ' -f1)

if [[ -z "$loong64_sha256" ]]; then
    echo "error: loong64 binary not found for version $VERSION" >&2
    exit 1
fi

# 构建版本数据
new_data=$(jq -n \
    --arg version "$VERSION" \
    --arg node_keys "$node_keys" \
    --arg loong64_sha256 "$loong64_sha256" \
    --arg debian_version "$debian_version" \
    --arg alpine_version "$alpine_version" \
    '{
        version: $version,
        node_keys: $node_keys,
        loong64_sha256: $loong64_sha256,
        debian_version: $debian_version,
        alpine_version: $alpine_version
    }')

json=$(echo "$json" | jq -c --argjson d "$new_data" '.[$d.version] = $d')
echo "$json" | jq -S . > versions.json

echo "Version info saved to versions.json" >&2
