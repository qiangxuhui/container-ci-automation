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
    local variant_name="$1"
    local from="$2"
    local php_variant="$3"
    local cmd="$4"

    local output_dir="$DOCKERFILES_DIR/$V_VERSION/$variant_name"
    mkdir -p "$output_dir"

    echo "  processing $V_VERSION/$variant_name ..." >&2

    # from 保持原始值（alpine:3.24 / debian:forky-slim）
    # 模板中 is_alpine 通过 startswith("alpine") 判断，不能加 registry 前缀
    export from="$from"
    export version="$RC_VERSION"
    export variant="$php_variant"
    export cmd="$cmd"
    export alpineVer=""
    export suite=""

    local docker_image_from=""
    if [[ "$from" == alpine:* ]]; then
        alpineVer="${from#alpine:}"
        suite="alpine${alpineVer}"
        docker_image_from="lcr.loongnix.cn/library/alpine:${alpineVer}"
    else
        suite="${from#debian:}"
        suite="${suite%-slim}"
        docker_image_from="lcr.loongnix.cn/library/debian:${suite}-slim"
    fi
    export alpineVer suite

    # 使用 jq-template.awk 渲染模板
    # jq-template.awk 内部读取当前目录的 versions.json，必须 cd 到 template 目录
    {
        cat <<-'EOH'
	#
	# NOTE: THIS DOCKERFILE IS GENERATED VIA "apply-templates.sh"
	#
	# PLEASE DO NOT EDIT IT DIRECTLY.
	#

EOH
        cd "$SCRIPT_DIR" && gawk -f "$JQT" Dockerfile-linux.template
    } > "$output_dir/Dockerfile"

    # 替换 FROM 行，添加 registry 前缀
    if [[ -n "$docker_image_from" ]]; then
        sed -i "s|^FROM ${from}$|FROM ${docker_image_from}|" "$output_dir/Dockerfile"
    fi

    # 复制辅助脚本
    cp -a \
        "$SCRIPT_DIR/docker-php-entrypoint" \
        "$SCRIPT_DIR/docker-php-ext-configure" \
        "$SCRIPT_DIR/docker-php-ext-enable" \
        "$SCRIPT_DIR/docker-php-ext-install" \
        "$SCRIPT_DIR/docker-php-source" \
        "$output_dir/"

    if [[ "$php_variant" == "apache" ]]; then
        cp -a "$SCRIPT_DIR/apache2-foreground" "$output_dir/"
    fi

    local cmd_first
    cmd_first=$(jq -r '.[0]' <<< "$cmd")
    if [[ "$cmd_first" != "php" ]]; then
        sed -i -e "s! php ! $cmd_first !g" "$output_dir/docker-php-entrypoint"
    fi

    # === LoongArch64 适配 ===
    local dockerfile="$output_dir/Dockerfile"

    # 1) PHP 8.2 loongarch64 fiber 支持
    if [[ "$RC_VERSION" == "8.2" ]]; then
        cp "$SCRIPT_DIR/jump_loongarch64_sysv_elf_gas.S" "$output_dir/"
        cp "$SCRIPT_DIR/make_loongarch64_sysv_elf_gas.S" "$output_dir/"

        # COPY 必须在 RUN 块之前（顶层指令）
        local run_line
        run_line=$(grep -nP '^RUN set -eux; ' "$dockerfile" | tail -1 | cut -d: -f1)
        if [[ -n "$run_line" ]]; then
            local insert_line=$((run_line - 1))
            sed -i "${insert_line}a COPY jump_loongarch64_sysv_elf_gas.S make_loongarch64_sysv_elf_gas.S /usr/src/php/Zend/asm/" "$dockerfile"
        fi

        # sed 修改 configure.ac（在 RUN 块内）
        local tmpfile
        tmpfile=$(mktemp)
        cat > "$tmpfile" <<'LOONGPATCH'
	# Apply loongarch64 fiber support for PHP 8.2
	if [ "$(uname -m)" = "loongarch64" ]; then \
		sed -i '/s390x\*\], \[fiber_cpu/a\  [loongarch64*], [fiber_cpu="loongarch64"],' configure.ac; \
		sed -i '/s390x\], \[fiber_asm_file_prefix/a\  [loongarch64], [fiber_asm_file_prefix="loongarch64_sysv"],' configure.ac; \
	fi; \
LOONGPATCH
        local line_num
        line_num=$(grep -nP '^\tcd /usr/src/php; ' "$dockerfile" | head -1 | cut -d: -f1)
        if [[ -n "$line_num" ]]; then
            sed -i "${line_num}r $tmpfile" "$dockerfile"
        fi
        rm -f "$tmpfile"
    fi

    # 2) 禁用 pcre-jit（loongarch64 不支持）
    local pcre_tmpfile
    pcre_tmpfile=$(mktemp)
    cat > "$pcre_tmpfile" <<'PCREBLOCK'
	# bundled pcre does not support JIT on loongarch64
	$(case "$gnuArch" in *loongarch64*) echo '--without-pcre-jit' ;; esac) \
PCREBLOCK
    local configure_line
    configure_line=$(grep -nP '^\t\.\/configure ' "$dockerfile" | head -1 | cut -d: -f1)
    if [[ -n "$configure_line" ]]; then
        sed -i "${configure_line}r $pcre_tmpfile" "$dockerfile"
    fi
    rm -f "$pcre_tmpfile"

    echo "  dockerfiles/$V_VERSION/$variant_name/Dockerfile" >&2
}

# === 生成所有变体 ===

generate_variant "debian" "debian:${V_DEBIAN}-slim" "cli" '["php", "-a"]'
generate_variant "debian-apache" "debian:${V_DEBIAN}-slim" "apache" '["apache2-foreground"]'
generate_variant "debian-fpm" "debian:${V_DEBIAN}-slim" "fpm" '["php-fpm"]'
generate_variant "debian-zts" "debian:${V_DEBIAN}-slim" "zts" '["php", "-a"]'

generate_variant "alpine" "alpine:${V_ALPINE}" "cli" '["php", "-a"]'
generate_variant "alpine-fpm" "alpine:${V_ALPINE}" "fpm" '["php-fpm"]'
generate_variant "alpine-zts" "alpine:${V_ALPINE}" "zts" '["php", "-a"]'

echo "Done." >&2
