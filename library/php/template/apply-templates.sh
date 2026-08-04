#!/usr/bin/env bash
# library/php/template/apply-templates.sh
# 接收版本号，读取 versions.json，使用 jq-template.awk 渲染模板生成 Dockerfile
# 注意：versions.json 以 major.minor 为 key，模板中 env.version 使用 major.minor
set -Eeuo pipefail

VERSION="$1"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 8.4.24"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKERFILES_DIR="$PROJECT_DIR/dockerfiles"

if [[ ! -f "$SCRIPT_DIR/versions.json" ]]; then
    echo "ERROR: versions.json not found. Run update.sh first."
    exit 1
fi

# 提取 major.minor 作为 versions.json 的 key
RC_VERSION="${VERSION%.*}"

V=$(jq -r --arg v "$RC_VERSION" '.[$v] // empty' "$SCRIPT_DIR/versions.json")
if [[ -z "$V" ]]; then
    echo "ERROR: Version $VERSION (key: $RC_VERSION) not found in versions.json"
    exit 1
fi

# 提取版本元数据
V_VERSION=$(echo "$V" | jq -r '.version')
V_URL=$(echo "$V" | jq -r '.url')
V_ASC_URL=$(echo "$V" | jq -r '.ascUrl')
V_SHA256=$(echo "$V" | jq -r '.sha256')
V_MAJOR=$(echo "$V" | jq -r '.major_version')
V_MINOR=$(echo "$V" | jq -r '.minor_version')
V_ALPINE=$(echo "$V" | jq -r '.alpine_version')
V_DEBIAN=$(echo "$V" | jq -r '.debian_version')

echo "Generating Dockerfiles for PHP $V_VERSION" >&2

# === 下载 jq-template.awk ===
JQT="$SCRIPT_DIR/jq-template.awk"
if [[ ! -f "$JQT" ]]; then
    echo "Downloading jq-template.awk..." >&2
    wget -qO "$JQT" 'https://github.com/docker-library/bashbrew/raw/9f6a35772ac863a0241f147c820354e4008edf38/scripts/jq-template.awk'
fi

# === 生成 Dockerfile 的函数 ===
generate_variant() {
    local variant_name="$1"    # e.g., "debian", "debian-apache", "alpine-fpm"
    local from="$2"            # e.g., "debian:forky-slim", "alpine:3.24"
    local php_variant="$3"     # e.g., "cli", "apache", "fpm", "zts"
    local cmd="$4"             # e.g., '["php", "-a"]', '["apache2-foreground"]'

    local output_dir="$DOCKERFILES_DIR/$V_VERSION/$variant_name"
    mkdir -p "$output_dir"

    echo "  processing $V_VERSION/$variant_name ..." >&2

    # 设置 jq-template.awk 需要的环境变量
    # version: 模板中 env.version 用于 JSON 查找 .[env.version] 和 GPG keys 查找
    #          必须使用 major.minor 格式（如 "8.4"），与 versions.json 的 key 一致
    export version="$RC_VERSION"
    export from="$from"
    export variant="$php_variant"
    export cmd="$cmd"
    export alpineVer=""
    export suite=""

    if [[ "$from" == alpine:* ]]; then
        alpineVer="${from#alpine:}"
        suite="alpine${alpineVer}"
        from="lcr.loongnix.cn/library/alpine:${alpineVer}"
    else
        # debian:forky-slim → suite="forky"
        suite="${from#debian:}"
        suite="${suite%-slim}"
        from="lcr.loongnix.cn/library/debian:${suite}-slim"
    fi
    export alpineVer suite

    # 使用 jq-template.awk 渲染模板
    {
        cat <<-'EOH'
	#
	# NOTE: THIS DOCKERFILE IS GENERATED VIA "apply-templates.sh"
	#
	# PLEASE DO NOT EDIT IT DIRECTLY.
	#

EOH
        gawk -f "$JQT" "$SCRIPT_DIR/Dockerfile-linux.template"
    } > "$output_dir/Dockerfile"

    # 复制辅助脚本
    cp -a \
        "$SCRIPT_DIR/docker-php-entrypoint" \
        "$SCRIPT_DIR/docker-php-ext-configure" \
        "$SCRIPT_DIR/docker-php-ext-enable" \
        "$SCRIPT_DIR/docker-php-ext-install" \
        "$SCRIPT_DIR/docker-php-source" \
        "$output_dir/"

    # apache 变体需要额外复制 apache2-foreground
    if [[ "$php_variant" == "apache" ]]; then
        cp -a "$SCRIPT_DIR/apache2-foreground" "$output_dir/"
    fi

    # 修改 entrypoint（apache/fpm 变体）
    local cmd_first
    cmd_first=$(jq -r '.[0]' <<< "$cmd")
    if [[ "$cmd_first" != "php" ]]; then
        sed -i -e "s! php ! $cmd_first !g" "$output_dir/docker-php-entrypoint"
    fi

    # === LoongArch64 适配 ===
    local dockerfile="$output_dir/Dockerfile"

    # 1) PHP 8.2 loongarch64 补丁（在 cd /usr/src/php 之后）
    if [[ "$RC_VERSION" == "8.2" ]]; then
        sed -i '/cd \/usr\/src\/php; \\/a\
\t# Apply loongarch64 patch for PHP 8.2 only\
\tif [ "$(uname -m)" = "loongarch64" ]; then \\\
\t\tcurl -fsSL -o /php-8.2-loongarch.patch '"'"'https://patch-diff.githubusercontent.com/raw/php/php-src/pull/13914.patch'"'"'; \\\
\t\tpatch -p1 < /php-8.2-loongarch.patch || { echo "Patch failed for PHP 8.2 on loongarch64"; exit 1; }; \\\
\t\trm /php-8.2-loongarch.patch; \\\
\tfi; \\' "$dockerfile"
    fi

    # 2) 禁用 pcre-jit（loongarch64 不支持）
    # 在 ./configure 之前插入条件判断
    sed -i '/^\t\.\/configure \\/i\
\t# bundled pcre does not support JIT on loongarch64\
\t$(case "$gnuArch" in *loongarch64*) echo '"'"'--without-pcre-jit'"'"' ;; esac) \\' "$dockerfile"

    echo "  dockerfiles/$V_VERSION/$variant_name/Dockerfile" >&2
}

# === 生成所有变体 ===

# Debian 变体
generate_variant "debian" "debian:${V_DEBIAN}-slim" "cli" '["php", "-a"]'
generate_variant "debian-apache" "debian:${V_DEBIAN}-slim" "apache" '["apache2-foreground"]'
generate_variant "debian-fpm" "debian:${V_DEBIAN}-slim" "fpm" '["php-fpm"]'
generate_variant "debian-zts" "debian:${V_DEBIAN}-slim" "zts" '["php", "-a"]'

# Alpine 变体（无 apache）
generate_variant "alpine" "alpine:${V_ALPINE}" "cli" '["php", "-a"]'
generate_variant "alpine-fpm" "alpine:${V_ALPINE}" "fpm" '["php-fpm"]'
generate_variant "alpine-zts" "alpine:${V_ALPINE}" "zts" '["php", "-a"]'

echo "Done." >&2
