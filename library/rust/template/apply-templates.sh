#!/usr/bin/env bash
# library/rust/template/apply-templates.sh
# 接收版本号，读取 versions.json，使用 sed 渲染模板生成 Dockerfile
set -Eeuo pipefail

VERSION="$1"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 1.97.1"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKERFILES_DIR="$PROJECT_DIR/dockerfiles"

if [[ ! -f "$SCRIPT_DIR/versions.json" ]]; then
    echo "ERROR: versions.json not found. Run update.sh first."
    exit 1
fi

V=$(jq -r --arg v "$VERSION" '.[$v] // empty' "$SCRIPT_DIR/versions.json")
if [[ -z "$V" ]]; then
    echo "ERROR: Version $VERSION not found in versions.json"
    exit 1
fi

# 提取变量
eval "$(echo "$V" | jq -r '
    "V_VERSION=\(.version)",
    "V_RUSTUP_VERSION=\(.rustup_version)",
    "V_DEBIAN=\(.debian_version)",
    "V_ALPINE=\(.alpine_version)",
    "V_SHA256_AMD64=\(.sha256_amd64)",
    "V_SHA256_ARMHF=\(.sha256_armhf)",
    "V_SHA256_ARM64=\(.sha256_arm64)",
    "V_SHA256_I386=\(.sha256_i386)",
    "V_SHA256_PPC64EL=\(.sha256_ppc64el)",
    "V_SHA256_S390X=\(.sha256_s390x)",
    "V_SHA256_RISCV64=\(.sha256_riscv64)",
    "V_SHA256_LOONG64=\(.sha256_loong64)",
    "V_SHA256_X86_64_MUSL=\(.sha256_x86_64_musl)",
    "V_SHA256_AARCH64_MUSL=\(.sha256_aarch64_musl)",
    "V_SHA256_PPC64LE_MUSL=\(.sha256_ppc64le_musl)",
    "V_SHA256_LOONGARCH64_MUSL=\(.sha256_loongarch64_musl)"
')"

echo "Generating Dockerfiles for rust $V_VERSION"

# 通用 sed 替换参数
SED_ARGS=(
    -e "s/{VERSION}/$V_VERSION/g"
    -e "s/{RUSTUP_VERSION}/$V_RUSTUP_VERSION/g"
    -e "s/{DEBIAN_VERSION}/$V_DEBIAN/g"
    -e "s/{ALPINE_VERSION}/$V_ALPINE/g"
    -e "s/{SHA256_AMD64}/$V_SHA256_AMD64/g"
    -e "s/{SHA256_ARMHF}/$V_SHA256_ARMHF/g"
    -e "s/{SHA256_ARM64}/$V_SHA256_ARM64/g"
    -e "s/{SHA256_I386}/$V_SHA256_I386/g"
    -e "s/{SHA256_PPC64EL}/$V_SHA256_PPC64EL/g"
    -e "s/{SHA256_S390X}/$V_SHA256_S390X/g"
    -e "s/{SHA256_RISCV64}/$V_SHA256_RISCV64/g"
    -e "s/{SHA256_LOONG64}/$V_SHA256_LOONG64/g"
    -e "s/{SHA256_X86_64_MUSL}/$V_SHA256_X86_64_MUSL/g"
    -e "s/{SHA256_AARCH64_MUSL}/$V_SHA256_AARCH64_MUSL/g"
    -e "s/{SHA256_PPC64LE_MUSL}/$V_SHA256_PPC64LE_MUSL/g"
    -e "s/{SHA256_LOONGARCH64_MUSL}/$V_SHA256_LOONGARCH64_MUSL/g"
)

# Debian 变体
mkdir -p "$DOCKERFILES_DIR/$VERSION/debian"
sed "${SED_ARGS[@]}" \
    "$SCRIPT_DIR/Dockerfile-debian.template" > "$DOCKERFILES_DIR/$VERSION/debian/Dockerfile"
echo "  dockerfiles/$VERSION/debian/Dockerfile"

# Debian slim 变体
mkdir -p "$DOCKERFILES_DIR/$VERSION/debian-slim"
sed "${SED_ARGS[@]}" \
    "$SCRIPT_DIR/Dockerfile-debian-slim.template" > "$DOCKERFILES_DIR/$VERSION/debian-slim/Dockerfile"
echo "  dockerfiles/$VERSION/debian-slim/Dockerfile"

# Alpine 变体
mkdir -p "$DOCKERFILES_DIR/$VERSION/alpine"
sed "${SED_ARGS[@]}" \
    "$SCRIPT_DIR/Dockerfile-alpine.template" > "$DOCKERFILES_DIR/$VERSION/alpine/Dockerfile"
echo "  dockerfiles/$VERSION/alpine/Dockerfile"

echo "Done."
