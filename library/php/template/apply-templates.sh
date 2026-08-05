#!/usr/bin/env bash
# library/php/template/apply-templates.sh
# 接收版本号，读取 versions.json，使用 sed 渲染模板生成 Dockerfile
# 每个变体一个独立模板，无需 blocks/ 目录
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
V_ALPINE=$(echo "$V" | jq -r '.alpine_version')

echo "Generating Dockerfiles for PHP $V_VERSION" >&2

# === GPG Keys ===
GPG_KEYS=$(jq -n --arg rc "$RC_VERSION" '
    {
        "8.6": ["D95C03BC702BE9515344AE3374E44BC9067701A5", "016895DE9A475111D537A6E69134FF30BC5A99B5", "5CFF17B64DC1C244F5D0EAC3E43535E2EB19010E"],
        "8.5": ["1198C0117593497A5EC5C199286AF1F9897469DC", "49D9AF6BC72A80D6691719C8AA23F5BE9C7097D4", "D95C03BC702BE9515344AE3374E44BC9067701A5"],
        "8.4": ["AFD8691FDAEDF03BDF6E460563F15A9B715376CA", "9D7F99A0CB8F05C8A6958D6256A97AF7600A39A6", "0616E93D95AF471243E26761770426E17EBBB3DD"],
        "8.3": ["1198C0117593497A5EC5C199286AF1F9897469DC", "C28D937575603EB4ABB725861C0779DC5C0A9DE4", "AFD8691FDAEDF03BDF6E460563F15A9B715376CA"],
        "8.2": ["39B641343D8C104B2B146DC3F9C39DC0B9698544", "E60913E4DF209907D8E30D96659A97C9CF2A795A", "1198C0117593497A5EC5C199286AF1F9897469DC"]
    }[$rc] // error("missing GPG keys for " + $rc)
    | join(" ")
' | tr -d '"')

# === 通用 sed 替换参数 ===
SED_ARGS=(
    -e "s/{PHP_VERSION}/$V_VERSION/g"
    -e "s|{PHP_URL}|$V_URL|g"
    -e "s|{PHP_ASC_URL}|$V_ASC_URL|g"
    -e "s/{PHP_SHA256}/$V_SHA256/g"
    -e "s/{ALPINE_VERSION}/$V_ALPINE/g"
)

# 用临时文件处理 GPG_KEYS 替换（含特殊字符）
gpg_tmpfile=$(mktemp)
printf 'ENV GPG_KEYS %s\n' "$GPG_KEYS" > "$gpg_tmpfile"
gpg_sed_file=$(mktemp)
cat > "$gpg_sed_file" <<'SEDEOF'
/{GPG_KEYS}/{
    r TMPFILE
    d
}
SEDEOF
sed -i "s|TMPFILE|$gpg_tmpfile|" "$gpg_sed_file"

# === 生成单个变体 ===
generate_variant() {
    local variant_name="$1"
    local template_file="$2"

    local output_dir="$DOCKERFILES_DIR/$V_VERSION/$variant_name"
    mkdir -p "$output_dir"

    echo "  processing $V_VERSION/$variant_name ..." >&2

    local output_file="$output_dir/Dockerfile"

    # 复制模板
    cp "$SCRIPT_DIR/$template_file" "$output_file"

    # 执行通用 sed 替换
    sed -i "${SED_ARGS[@]}" "$output_file"

    # 替换 GPG_KEYS
    sed -i -f "$gpg_sed_file" "$output_file"

    # 复制辅助脚本
    cp -a \
        "$SCRIPT_DIR/docker-php-entrypoint" \
        "$SCRIPT_DIR/docker-php-ext-configure" \
        "$SCRIPT_DIR/docker-php-ext-enable" \
        "$SCRIPT_DIR/docker-php-ext-install" \
        "$SCRIPT_DIR/docker-php-source" \
        "$output_dir/"

    # Apache 变体需要 apache2-foreground
    if [[ "$variant_name" == *apache* ]]; then
        cp -a "$SCRIPT_DIR/apache2-foreground" "$output_dir/"
    fi

    # === LoongArch64 适配 ===
    local dockerfile="$output_file"

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

        # Alpine loongarch64 需要 libucontext（musl 没有 swapcontext）
        if [[ "$template_file" == *alpine* ]]; then
            local uctx_tmpfile
            uctx_tmpfile=$(mktemp)
            cat > "$uctx_tmpfile" <<'UCTXBLOCK'
        # Install libucontext and set LIBS for PHP 8.2/8.3 on loongarch64
        if [ "$(uname -m)" = "loongarch64" ]; then \
            apk add --no-cache libucontext-dev; \
            export LIBS="-lucontext"; \
        fi; \
UCTXBLOCK
            # 插入在 rm -vf /usr/include/iconv.h 之后
            local iconv_line
            iconv_line=$(grep -nP 'rm -vf /usr/include/iconv.h' "$dockerfile" | head -1 | cut -d: -f1)
            if [[ -n "$iconv_line" ]]; then
                sed -i "${iconv_line}r $uctx_tmpfile" "$dockerfile"
            fi
            rm -f "$uctx_tmpfile"
        fi
    fi

    echo "  dockerfiles/$V_VERSION/$variant_name/Dockerfile" >&2
}

# === 生成所有变体 ===
# Debian 变体
generate_variant "debian"         "Dockerfile-debian-cli.template"
generate_variant "debian-apache"  "Dockerfile-debian-apache.template"
generate_variant "debian-fpm"     "Dockerfile-debian-fpm.template"
generate_variant "debian-zts"     "Dockerfile-debian-zts.template"

# Alpine 变体
generate_variant "alpine"         "Dockerfile-alpine-cli.template"
generate_variant "alpine-fpm"     "Dockerfile-alpine-fpm.template"
generate_variant "alpine-zts"     "Dockerfile-alpine-zts.template"

# 清理临时文件
rm -f "$gpg_tmpfile" "$gpg_sed_file"

echo "Done." >&2
