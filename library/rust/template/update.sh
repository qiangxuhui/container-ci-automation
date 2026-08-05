#!/usr/bin/env bash
# library/rust/template/update.sh
# 接收版本号，从 upstream 获取 rustup 版本和各架构 SHA256，生成 versions.json
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$1"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 1.97.1"
    exit 1
fi

# ===== 变体版本（集中管理）=====
ALPINE_VERSION="3.24"
DEBIAN_VERSION="forky"

# 获取 rustup 版本
RUSTUP_VERSION=$(wget -qO- 'https://static.rust-lang.org/rustup/release-stable.toml' \
    | grep '^version' \
    | sed "s/.*'\([0-9.]*\)'.*/\1/")

if [[ -z "$RUSTUP_VERSION" ]]; then
    echo "ERROR: Failed to fetch rustup version" >&2
    exit 1
fi

echo "Rust: $VERSION, Rustup: $RUSTUP_VERSION" >&2

# 获取各架构 rustup-init SHA256
# 从静态服务器下载 .sha256 文件
fetch_sha256() {
    local rust_arch="$1"
    wget -qO- "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${rust_arch}/rustup-init.sha256" \
        | awk '{print $1}'
}

echo "Fetching SHA256 checksums..." >&2

# Debian 架构（dpkg 名 → rustup 目标）
SHA256_AMD64=$(fetch_sha256 "x86_64-unknown-linux-gnu")
SHA256_ARMHF=$(fetch_sha256 "armv7-unknown-linux-gnueabihf")
SHA256_ARM64=$(fetch_sha256 "aarch64-unknown-linux-gnu")
SHA256_I386=$(fetch_sha256 "i686-unknown-linux-gnu")
SHA256_PPC64EL=$(fetch_sha256 "powerpc64le-unknown-linux-gnu")
SHA256_S390X=$(fetch_sha256 "s390x-unknown-linux-gnu")
SHA256_RISCV64=$(fetch_sha256 "riscv64gc-unknown-linux-gnu")
SHA256_LOONG64=$(fetch_sha256 "loongarch64-unknown-linux-gnu")

# Alpine 架构（apk 名 → rustup musl 目标）
SHA256_X86_64_MUSL=$(fetch_sha256 "x86_64-unknown-linux-musl")
SHA256_AARCH64_MUSL=$(fetch_sha256 "aarch64-unknown-linux-musl")
SHA256_PPC64LE_MUSL=$(fetch_sha256 "powerpc64le-unknown-linux-musl")
SHA256_LOONGARCH64_MUSL=$(fetch_sha256 "loongarch64-unknown-linux-musl")

# 合并到 versions.json
if [[ -f "$SCRIPT_DIR/versions.json" ]] && [[ -s "$SCRIPT_DIR/versions.json" ]]; then
    json=$(< "$SCRIPT_DIR/versions.json")
else
    json='{}'
fi

new_data=$(jq -n \
    --arg version "$VERSION" \
    --arg rustup_version "$RUSTUP_VERSION" \
    --arg alpine_version "$ALPINE_VERSION" \
    --arg debian_version "$DEBIAN_VERSION" \
    --arg sha256_amd64 "$SHA256_AMD64" \
    --arg sha256_armhf "$SHA256_ARMHF" \
    --arg sha256_arm64 "$SHA256_ARM64" \
    --arg sha256_i386 "$SHA256_I386" \
    --arg sha256_ppc64el "$SHA256_PPC64EL" \
    --arg sha256_s390x "$SHA256_S390X" \
    --arg sha256_riscv64 "$SHA256_RISCV64" \
    --arg sha256_loong64 "$SHA256_LOONG64" \
    --arg sha256_x86_64_musl "$SHA256_X86_64_MUSL" \
    --arg sha256_aarch64_musl "$SHA256_AARCH64_MUSL" \
    --arg sha256_ppc64le_musl "$SHA256_PPC64LE_MUSL" \
    --arg sha256_loongarch64_musl "$SHA256_LOONGARCH64_MUSL" \
    '{
        version: $version,
        rustup_version: $rustup_version,
        alpine_version: $alpine_version,
        debian_version: $debian_version,
        sha256_amd64: $sha256_amd64,
        sha256_armhf: $sha256_armhf,
        sha256_arm64: $sha256_arm64,
        sha256_i386: $sha256_i386,
        sha256_ppc64el: $sha256_ppc64el,
        sha256_s390x: $sha256_s390x,
        sha256_riscv64: $sha256_riscv64,
        sha256_loong64: $sha256_loong64,
        sha256_x86_64_musl: $sha256_x86_64_musl,
        sha256_aarch64_musl: $sha256_aarch64_musl,
        sha256_ppc64le_musl: $sha256_ppc64le_musl,
        sha256_loongarch64_musl: $sha256_loongarch64_musl
    }')

json=$(echo "$json" | jq -c --argjson d "$new_data" '.[$d.version] = $d')
echo "$json" | jq -S . > "$SCRIPT_DIR/versions.json"

echo "Version info saved to versions.json" >&2
