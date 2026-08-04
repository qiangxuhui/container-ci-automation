#!/bin/bash
# library/httpd/template/apply-templates.sh
# 接收版本号，读取 versions.json，使用 sed 渲染模板生成 Dockerfile
set -eo pipefail

VERSION="$1"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 2.4.68"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKERFILES_DIR="$PROJECT_DIR/dockerfiles"

if [[ ! -f "$SCRIPT_DIR/versions.json" ]]; then
    echo "ERROR: versions.json not found. Run update.sh first."
    exit 1
fi

# 从 versions.json 提取变量（扁平结构）
V_VERSION=$(jq -r --arg v "$VERSION" '.[$v].version // empty' "$SCRIPT_DIR/versions.json")
V_SHA256=$(jq -r --arg v "$VERSION" '.[$v].sha256 // empty' "$SCRIPT_DIR/versions.json")
V_ALPINE=$(jq -r --arg v "$VERSION" '.[$v].alpine_version // empty' "$SCRIPT_DIR/versions.json")
V_DEBIAN=$(jq -r --arg v "$VERSION" '.[$v].debian_version // empty' "$SCRIPT_DIR/versions.json")
V_PATCHES=$(jq -r --arg v "$VERSION" '.[$v].patches // ""' "$SCRIPT_DIR/versions.json")

if [[ -z "$V_VERSION" ]]; then
    echo "ERROR: Version $VERSION not found in versions.json"
    exit 1
fi

echo "Generating Dockerfiles for httpd $V_VERSION"
echo "  Alpine: $V_ALPINE"
echo "  Debian: $V_DEBIAN"

# Debian 变体
mkdir -p "$DOCKERFILES_DIR/$VERSION/debian"
sed \
    -e "s/{VERSION}/$V_VERSION/g" \
    -e "s/{SHA256}/$V_SHA256/g" \
    -e "s/{DEBIAN_VERSION}/$V_DEBIAN/g" \
    -e "s/{PATCHES}/$V_PATCHES/g" \
    "$SCRIPT_DIR/Dockerfile-debian.template" > "$DOCKERFILES_DIR/$VERSION/debian/Dockerfile"
cp "$SCRIPT_DIR/httpd-foreground" "$DOCKERFILES_DIR/$VERSION/debian/"
echo "  dockerfiles/$VERSION/debian/Dockerfile"

# Alpine 变体
mkdir -p "$DOCKERFILES_DIR/$VERSION/alpine"
sed \
    -e "s/{VERSION}/$V_VERSION/g" \
    -e "s/{SHA256}/$V_SHA256/g" \
    -e "s/{ALPINE_VERSION}/$V_ALPINE/g" \
    -e "s/{PATCHES}/$V_PATCHES/g" \
    "$SCRIPT_DIR/Dockerfile-alpine.template" > "$DOCKERFILES_DIR/$VERSION/alpine/Dockerfile"
cp "$SCRIPT_DIR/httpd-foreground" "$DOCKERFILES_DIR/$VERSION/alpine/"
echo "  dockerfiles/$VERSION/alpine/Dockerfile"

echo "Done."
