#!/usr/bin/env bash
# library/golang/template/apply-templates.sh
# 接收版本号，读取 versions.json，使用 sed 渲染模板生成 Dockerfile
set -Eeuo pipefail

VERSION="$1"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 1.26.5"
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
    "V_DEBIAN=\(.debian_version)",
    "V_URL_AMD64=\(.amd64_url)",
    "V_SHA256_AMD64=\(.amd64_sha256)",
    "V_URL_ARMHF=\(.armhf_url)",
    "V_SHA256_ARMHF=\(.armhf_sha256)",
    "V_URL_ARM64=\(.arm64_url)",
    "V_SHA256_ARM64=\(.arm64_sha256)",
    "V_URL_I386=\(.i386_url)",
    "V_SHA256_I386=\(.i386_sha256)",
    "V_URL_LOONG64=\(.loong64_url)",
    "V_SHA256_LOONG64=\(.loong64_sha256)",
    "V_URL_MIPS64EL=\(.mips64el_url)",
    "V_SHA256_MIPS64EL=\(.mips64el_sha256)",
    "V_URL_PPC64EL=\(.ppc64el_url)",
    "V_SHA256_PPC64EL=\(.ppc64el_sha256)",
    "V_URL_RISCV64=\(.riscv64_url)",
    "V_SHA256_RISCV64=\(.riscv64_sha256)",
    "V_URL_S390X=\(.s390x_url)",
    "V_SHA256_S390X=\(.s390x_sha256)"
')"

# 从 versions.json 读取 alpine 版本列表
V_ALPINE=$(echo "$V" | jq -r '.alpine_version')

echo "Generating Dockerfiles for golang $V_VERSION"

# 通用 sed 替换参数
SED_ARGS=(
    -e "s/{VERSION}/$V_VERSION/g"
    -e "s/{DEBIAN_VARIANT}/$V_DEBIAN/g"
    -e "s|{URL_AMD64}|$V_URL_AMD64|g"
    -e "s/{SHA256_AMD64}/$V_SHA256_AMD64/g"
    -e "s|{URL_ARMHF}|$V_URL_ARMHF|g"
    -e "s/{SHA256_ARMHF}/$V_SHA256_ARMHF/g"
    -e "s|{URL_ARM64}|$V_URL_ARM64|g"
    -e "s/{SHA256_ARM64}/$V_SHA256_ARM64/g"
    -e "s|{URL_I386}|$V_URL_I386|g"
    -e "s/{SHA256_I386}/$V_SHA256_I386/g"
    -e "s|{URL_LOONG64}|$V_URL_LOONG64|g"
    -e "s/{SHA256_LOONG64}/$V_SHA256_LOONG64/g"
    -e "s|{URL_MIPS64EL}|$V_URL_MIPS64EL|g"
    -e "s/{SHA256_MIPS64EL}/$V_SHA256_MIPS64EL/g"
    -e "s|{URL_PPC64EL}|$V_URL_PPC64EL|g"
    -e "s/{SHA256_PPC64EL}/$V_SHA256_PPC64EL/g"
    -e "s|{URL_RISCV64}|$V_URL_RISCV64|g"
    -e "s/{SHA256_RISCV64}/$V_SHA256_RISCV64/g"
    -e "s|{URL_S390X}|$V_URL_S390X|g"
    -e "s/{SHA256_S390X}/$V_SHA256_S390X/g"
)

# Debian 变体
mkdir -p "$DOCKERFILES_DIR/$VERSION/$V_DEBIAN"
sed "${SED_ARGS[@]}" \
    "$SCRIPT_DIR/Dockerfile-debian.template" > "$DOCKERFILES_DIR/$VERSION/$V_DEBIAN/Dockerfile"
echo "  dockerfiles/$VERSION/$V_DEBIAN/Dockerfile"

# Alpine 变体
mkdir -p "$DOCKERFILES_DIR/$VERSION/alpine"
sed "${SED_ARGS[@]}" -e "s/{ALPINE_VERSION}/$V_ALPINE/g" \
    "$SCRIPT_DIR/Dockerfile-alpine.template" > "$DOCKERFILES_DIR/$VERSION/alpine/Dockerfile"
echo "  dockerfiles/$VERSION/alpine/Dockerfile"

echo "Done."
