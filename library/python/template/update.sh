#!/usr/bin/env bash
# library/python/template/update.sh
# 接收版本号，从 python.org 获取 checksum，预计算条件块，生成 versions.json
set -Eeuo pipefail

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

VERSION="$1"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 3.14.6"
    exit 1
fi

if [[ -f versions.json ]] && [[ -s versions.json ]]; then
    json=$(< versions.json)
else
    json='{}'
fi

# 变体版本（集中管理）
alpine_versions="3.24"
debian_version="forky"

# 提取版本信息
# VERSION="3.14.6" → MAJOR_MINOR="3.14", MINOR="14"
MAJOR_MINOR="${VERSION%.*}"       # "3.14.6" → "3.14"
MINOR="${MAJOR_MINOR#*.}"          # "3.14" → "14"

# === 获取 SHA256 ===
# Python 使用 sigstore 或 SBOM 提供校验和
DIR_VERSION="${VERSION%%[a-z]*}"  # 去掉 a/b/rc 后缀
FILENAME="Python-${VERSION}.tar.xz"

echo "Fetching checksum for Python $VERSION..." >&2

SHA256=""

# 尝试从 SBOM 获取
SBOM_URL="https://www.python.org/ftp/python/${DIR_VERSION}/${FILENAME}.spdx.json"
SBOM_DATA=$(wget -qO- "$SBOM_URL" 2>/dev/null || true)
if [[ -n "$SBOM_DATA" ]]; then
    SHA256=$(echo "$SBOM_DATA" | jq -r --arg fn "$FILENAME" '
        first(.packages[]
            | select(.name == "CPython" and .packageFileName == $fn))
        | .checksums
        | map({key: (.algorithm // empty | ascii_downcase), value: (.checksumValue // empty)})
        | from_entries
        | .sha256 // empty
    ' 2>/dev/null || true)
fi

# 如果 SBOM 失败，尝试从 sigstore 获取
if [[ -z "$SHA256" ]]; then
    SIGSTORE_URL="https://www.python.org/ftp/python/${DIR_VERSION}/${FILENAME}.sigstore"
    SIGSTORE_DATA=$(wget -qO- "$SIGSTORE_URL" 2>/dev/null || true)
    if [[ -n "$SIGSTORE_DATA" ]]; then
        SIGSTORE_B64=$(echo "$SIGSTORE_DATA" | jq -r '
            .messageSignature.messageDigest
            | if .algorithm != "SHA2_256" then
                error("sigstore bundle not using SHA2_256")
              else .digest end
        ' 2>/dev/null || true)
        if [[ -n "$SIGSTORE_B64" ]]; then
            SHA256=$(base64 -d <<<"$SIGSTORE_B64" | hexdump -ve '/1 "%02x"')
        fi
    fi
fi

# 如果都失败，尝试直接 HEAD 检查文件是否存在
if [[ -z "$SHA256" ]]; then
    if wget -q -O /dev/null -o /dev/null --spider "https://www.python.org/ftp/python/${DIR_VERSION}/${FILENAME}"; then
        echo "warning: could not fetch checksum for $VERSION, proceeding without" >&2
    else
        echo "error: Python $VERSION tarball not found" >&2
        exit 1
    fi
fi

echo "SHA256: ${SHA256:-unknown}" >&2

# === 确定 GPG key ===
# 3.10, 3.11: Pablo Galindo Salgado
# 3.12: Thomas Wouters
# 3.13+: 无 GPG 验证（PEP 761）
GPG_KEY=""
case "$MAJOR_MINOR" in
    3.10|3.11)
        GPG_KEY="A035C8C19219BA821ECEA86B64E628F8D684696D"
        ;;
    3.12)
        GPG_KEY="7169605F62C751356D054A26A821E680E5FA6305"
        ;;
    *)
        # 3.13+ 不需要 GPG 验证
        ;;
esac

# === 确定 setuptools 版本 ===
# 仅 3.10, 3.11 需要 setuptools
SETUPTOOLS_VERSION=""
case "$MAJOR_MINOR" in
    3.10|3.11)
        # 从 ensurepip 获取 setuptools 版本
        SETUPTOOLS_VERSION=$(wget -qO- "https://github.com/python/cpython/raw/v${VERSION}/Lib/ensurepip/__init__.py" 2>/dev/null \
            | sed -nre 's/^_SETUPTOOLS_VERSION[[:space:]]*=[[:space:]]*"(.*?)".*/\1/p' || true)
        if [[ -z "$SETUPTOOLS_VERSION" ]]; then
            echo "warning: could not determine setuptools version for $VERSION" >&2
        fi
        ;;
esac

echo "GPG key: ${GPG_KEY:-none}" >&2
echo "Setuptools: ${SETUPTOOLS_VERSION:-none}" >&2

# === 构建版本数据 ===
new_data=$(
    jq -n \
        --arg version "$VERSION" \
        --arg sha256 "$SHA256" \
        --arg gpg_key "$GPG_KEY" \
        --arg setuptools_version "$SETUPTOOLS_VERSION" \
        --arg alpine_versions "$alpine_versions" \
        --arg debian_version "$debian_version" \
        '{
            version: $version,
            sha256: $sha256,
            gpg_key: $gpg_key,
            setuptools_version: $setuptools_version,
            alpine_versions: $alpine_versions,
            debian_version: $debian_version
        }'
)

json=$(echo "$json" | jq -c --argjson d "$new_data" '.[$d.version] = $d')
echo "$json" | jq -S . > versions.json

echo "Version info saved to versions.json" >&2
