#!/usr/bin/env bash
# library/ruby/template/apply-templates.sh
# 接收版本号，读取 versions.json，使用 sed+awk 渲染模板生成 Dockerfile
set -Eeuo pipefail

VERSION="$1"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 3.3.12"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKERFILES_DIR="$PROJECT_DIR/dockerfiles"
BLOCKS_DIR=$(mktemp -d)
trap "rm -rf $BLOCKS_DIR" EXIT

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
V_VERSION=$(echo "$V" | jq -r '.version')
V_DATE=$(echo "$V" | jq -r '.date')
V_POST=$(echo "$V" | jq -r '.post')
V_URL_XZ=$(echo "$V" | jq -r '.url_xz')
V_SHA256_XZ=$(echo "$V" | jq -r '.sha256_xz')
V_RUST_VERSION=$(echo "$V" | jq -r '.rust_version')
V_DEBIAN=$(echo "$V" | jq -r '.debian_version')
V_ALPINE=$(echo "$V" | jq -r '.alpine_version')

# 提取主版本号
MAJOR="${V_VERSION%%.*}"

echo "Generating Dockerfiles for ruby $V_VERSION" >&2

# === awk 块替换函数 ===
replace_blocks() {
    local template="$1" output="$2"
    local -a block_files=()
    for f in "$BLOCKS_DIR"/*.txt; do
        [[ -f "$f" ]] || continue
        block_files+=("$f")
    done
    awk -v bdir="$BLOCKS_DIR" '
    {
        line = $0
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)  # trim
        if (line ~ /^\{[A-Z0-9_]+\}$/) {
            # 提取块名
            name = line
            gsub(/[{]/, "", name)
            gsub(/[}]/, "", name)
            fname = bdir "/" name ".txt"
            # 文件存在则替换占位符（即使为空）
            if (system("[ -f \"" fname "\" ]") == 0) {
                while ((getline content < fname) > 0) {
                    print content
                }
                close(fname)
                next
            }
        }
        print
    }
    ' "$template" > "$output"
}

# 清理旧块文件
rm -f "$BLOCKS_DIR"/*.txt

# === 初始化所有块为空文件 ===
for block in BLOCK_ZJIT RUSTUP_CASES RUSTUP_CASES_ALPINE; do
    : > "$BLOCKS_DIR/${block}.txt"
done

# === 写入块 ===

# ZJIT: 仅 Ruby 4.0+ (不是 3.3, 3.4)
if [[ "$MAJOR" -ge 4 ]]; then
    cat > "$BLOCKS_DIR/BLOCK_ZJIT.txt" << 'ZJEOF'
		${rustArch:+--enable-zjit} \
ZJEOF
fi

# Rust case statement: loong64 无 rustup，保持空 case statement
# （与上游结构一致，rustArch 保持空，YJIT/ZJIT 不启用）

# === 生成函数 ===

generate_debian() {
    local template_name="$1" tag_dir="$2"

    local output_dir="$DOCKERFILES_DIR/$V_VERSION/$tag_dir"
    mkdir -p "$output_dir"

    # sed 替换
    sed \
        -e "s/{VERSION}/$V_VERSION/g" \
        -e "s|{POST}|$V_POST|g" \
        -e "s|{RUBY_DOWNLOAD_URL}|$V_URL_XZ|g" \
        -e "s/{RUBY_DOWNLOAD_SHA256}/$V_SHA256_XZ/g" \
        -e "s/{RUST_VERSION}/$V_RUST_VERSION/g" \
        -e "s/{DEBIAN_VERSION}/$V_DEBIAN/g" \
        -e "/{RUSTUP_CASES}/d" \
        -e "/{RUSTUP_CASES_ALPINE}/d" \
        "$SCRIPT_DIR/$template_name" > "$output_dir/Dockerfile.tmp"

    # awk 块替换
    replace_blocks "$output_dir/Dockerfile.tmp" "$output_dir/Dockerfile"
    rm -f "$output_dir/Dockerfile.tmp"
    echo "  dockerfiles/$V_VERSION/$tag_dir/Dockerfile" >&2
}

generate_alpine() {
    local output_dir="$DOCKERFILES_DIR/$V_VERSION/alpine"
    mkdir -p "$output_dir"

    # sed 替换
    sed \
        -e "s/{VERSION}/$V_VERSION/g" \
        -e "s|{POST}|$V_POST|g" \
        -e "s|{RUBY_DOWNLOAD_URL}|$V_URL_XZ|g" \
        -e "s/{RUBY_DOWNLOAD_SHA256}/$V_SHA256_XZ/g" \
        -e "s/{RUST_VERSION}/$V_RUST_VERSION/g" \
        -e "s/{ALPINE_VERSION}/$V_ALPINE/g" \
        -e "/{RUSTUP_CASES}/d" \
        -e "/{RUSTUP_CASES_ALPINE}/d" \
        "$SCRIPT_DIR/Dockerfile-alpine.template" > "$output_dir/Dockerfile.tmp"

    # awk 块替换
    replace_blocks "$output_dir/Dockerfile.tmp" "$output_dir/Dockerfile"
    rm -f "$output_dir/Dockerfile.tmp"
    echo "  dockerfiles/$V_VERSION/alpine/Dockerfile" >&2
}

# === 生成所有变体 ===

# Debian 全量
generate_debian "Dockerfile-debian.template" "debian"

# Debian slim
generate_debian "Dockerfile-debian-slim.template" "debian-slim"

# Alpine
generate_alpine

echo "Done." >&2
