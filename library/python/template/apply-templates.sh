#!/usr/bin/env bash
# library/python/template/apply-templates.sh
# 接收版本号，读取 versions.json，使用 sed+awk 渲染模板生成 Dockerfile
set -Eeuo pipefail

VERSION="$1"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 3.14.6"
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
V_SHA256=$(echo "$V" | jq -r '.sha256 // empty')
V_GPG_KEY=$(echo "$V" | jq -r '.gpg_key // empty')
V_SETUPTOOLS=$(echo "$V" | jq -r '.setuptools_version // empty')
V_DEBIAN=$(echo "$V" | jq -r '.debian_version')
V_ALPINE_LIST=$(echo "$V" | jq -r '.alpine_versions')

# 提取版本信息
# VERSION="3.14.6" → MAJOR_MINOR="3.14", MINOR="14"
MAJOR_MINOR="${VERSION%.*}"
MINOR="${MAJOR_MINOR#*.}"

echo "Generating Dockerfiles for python $V_VERSION" >&2

# === awk 块替换函数 ===
# 读取 $BLOCKS_DIR/*.txt，将模板中的占位符行替换为块内容
replace_blocks() {
    local template="$1" output="$2"
    # 将所有块文件路径传给 awk，awk 动态读取
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

# 初始化所有块为空文件（条件逻辑只覆盖需要有内容的块）
for block in BLOCK_ENV_LANG BLOCK_GPG_VERIFY BLOCK_ENV_SHA256 BLOCK_ENV_SHA256_CHECK \
             BLOCK_GPG_DOWNLOAD BLOCK_SETUPTOOLS BLOCK_ALPINE_BUILD_DEPS \
             BLOCK_DEBIAN_ZSTD BLOCK_DEBIAN_BUILD_DEPS BLOCK_DEBIAN_CLEANUP BLOCK_MAKE_FLAGS; do
    : > "$BLOCKS_DIR/${block}.txt"
done

# === 写入所有块 ===

# ENV_LANG: 仅 3.10-3.12
if [[ "$MINOR" -le 12 ]]; then
    cat > "$BLOCKS_DIR/BLOCK_ENV_LANG.txt" << 'LANGEOF'
# cannot remove LANG even though https://bugs.python.org/issue19846 is fixed
# last attempted removal of LANG broke many users:
# https://github.com/docker-library/python/pull/570
ENV LANG C.UTF-8

LANGEOF
fi

# GPG key: 仅 3.10-3.12
if [[ -n "$V_GPG_KEY" ]]; then
    printf 'ENV GPG_KEY %s\n' "$V_GPG_KEY" > "$BLOCKS_DIR/BLOCK_GPG_VERIFY.txt"
fi

# ENV SHA256
if [[ -n "$V_SHA256" ]]; then
    printf 'ENV PYTHON_SHA256 %s\n' "$V_SHA256" > "$BLOCKS_DIR/BLOCK_ENV_SHA256.txt"
    printf '\techo "$PYTHON_SHA256 *python.tar.xz" | sha256sum -c -; \\\n' > "$BLOCKS_DIR/BLOCK_ENV_SHA256_CHECK.txt"
fi

# GPG 下载验证: 仅 3.10-3.12
if [[ -n "$V_GPG_KEY" ]]; then
    cat > "$BLOCKS_DIR/BLOCK_GPG_DOWNLOAD.txt" << 'GPGEOF'
	wget -O python.tar.xz.asc "https://www.python.org/ftp/python/${PYTHON_VERSION%%[a-z]*}/Python-$PYTHON_VERSION.tar.xz.asc"; \
	GNUPGHOME="$(mktemp -d)"; export GNUPGHOME; \
	gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "$GPG_KEY"; \
	gpg --batch --verify python.tar.xz.asc python.tar.xz; \
	gpgconf --kill all; \
	rm -rf "$GNUPGHOME" python.tar.xz.asc; \
GPGEOF
fi

# setuptools: 仅 3.10-3.11
if [[ -n "$V_SETUPTOOLS" ]]; then
    cat > "$BLOCKS_DIR/BLOCK_SETUPTOOLS.txt" << EOF
	\\
	pip3 install \\
		--disable-pip-version-check \\
		--no-cache-dir \\
		--no-compile \\
		'setuptools==${V_SETUPTOOLS}' \\
		'wheel==0.46.3' \\
	; \\
EOF
fi

# Frame pointers: 3.12+
if [[ "$MINOR" -ge 12 ]]; then
    # Debian variant
    cat > "$BLOCKS_DIR/BLOCK_FRAME_PTRS_DEBIAN.txt" << 'FPEOF'
	arch="$(dpkg --print-architecture)"; arch="${arch##*-}"; \
# https://docs.python.org/3.12/howto/perf_profiling.html
# https://github.com/docker-library/python/pull/1000#issuecomment-2597021615
	case "$arch" in \
		amd64|arm64) \
			# only add "-mno-omit-leaf" on arches that support it
			# https://gcc.gnu.org/onlinedocs/gcc-14.2.0/gcc/x86-Options.html#index-momit-leaf-frame-pointer-2
			# https://gcc.gnu.org/onlinedocs/gcc-14.2.0/gcc/AArch64-Options.html#index-momit-leaf-frame-pointer
			EXTRA_CFLAGS="${EXTRA_CFLAGS:-} -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer"; \
			;; \
		i386) \
			# don't enable frame-pointers on 32bit x86 due to performance drop.
			;; \
		*) \
			# other arches don't support "-mno-omit-leaf"
			EXTRA_CFLAGS="${EXTRA_CFLAGS:-} -fno-omit-frame-pointer"; \
			;; \
	esac; \
FPEOF

    # Alpine variant
    cat > "$BLOCKS_DIR/BLOCK_FRAME_PTRS_ALPINE.txt" << 'FPEOF'
	arch="$(apk --print-arch)"; \
# https://docs.python.org/3.12/howto/perf_profiling.html
# https://github.com/docker-library/python/pull/1000#issuecomment-2597021615
	case "$arch" in \
		x86_64|aarch64) \
			# only add "-mno-omit-leaf" on arches that support it
			# https://gcc.gnu.org/onlinedocs/gcc-14.2.0/gcc/x86-Options.html#index-momit-leaf-frame-pointer-2
			# https://gcc.gnu.org/onlinedocs/gcc-14.2.0/gcc/AArch64-Options.html#index-momit-leaf-frame-pointer
			EXTRA_CFLAGS="${EXTRA_CFLAGS:-} -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer"; \
			;; \
		x86) \
			# don't enable frame-pointers on 32bit x86 due to performance drop.
			;; \
		*) \
			# other arches don't support "-mno-omit-leaf"
			EXTRA_CFLAGS="${EXTRA_CFLAGS:-} -fno-omit-frame-pointer"; \
			;; \
	esac; \
FPEOF
fi

# Debian zstd-dev: 仅 3.14+
if [[ "$MINOR" -ge 14 ]]; then
    printf '\t\tlibzstd-dev \\\n' > "$BLOCKS_DIR/BLOCK_DEBIAN_ZSTD.txt"
fi

# Debian build deps: 仅 3.14+ (libzstd-dev)
if [[ "$MINOR" -ge 14 ]]; then
    cat > "$BLOCKS_DIR/BLOCK_DEBIAN_BUILD_DEPS.txt" << 'BDEOF'
	savedAptMark="$(apt-mark showmanual)"; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		libzstd-dev \
	; \
	\
BDEOF
fi

# Debian cleanup: 仅当有 build deps 时（3.14+ 有 libzstd-dev）
if [[ "$MINOR" -ge 14 ]]; then
    cat > "$BLOCKS_DIR/BLOCK_DEBIAN_CLEANUP.txt" << 'CEOF'
	ldconfig; \
	\
	apt-mark auto '.*' > /dev/null; \
	apt-mark manual $savedAptMark; \
	find /usr/local -type f -executable -not \( -name '*tkinter*' \) -exec ldd '{}' ';' \
		| awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); printf "*%s\n", so }' \
		| sort -u \
		| xargs -rt dpkg-query --search \
# https://manpages.debian.org/bookworm/dpkg/dpkg-query.1.en.html#S (we ignore diversions and it'll be really unusual for more than one package to provide any given .so file)
		| awk 'sub(":$", "", $1) { print $1 }' \
		| sort -u \
		| xargs -r apt-mark manual \
	; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
	rm -rf /var/lib/apt/lists/*; \
	\
CEOF
else
    cat > "$BLOCKS_DIR/BLOCK_DEBIAN_CLEANUP.txt" << 'CEOF'
	ldconfig; \
	\
CEOF
fi

# Alpine build dependencies
alpine_deps_base="bluez-dev
bzip2-dev
dpkg-dev dpkg
findutils
gcc
gdbm-dev
gnupg
libc-dev
libffi-dev
libnsl-dev
libtirpc-dev
linux-headers
make
ncurses-dev
openssl-dev
pax-utils
readline-dev
sqlite-dev
tar
tcl-dev
tk
tk-dev
util-linux-dev
xz
xz-dev
zlib-dev"
alpine_deps="$alpine_deps_base"
if [[ "$MINOR" -ge 14 ]]; then
    alpine_deps="${alpine_deps}
zstd-dev"
fi
echo "$alpine_deps" | while IFS= read -r dep; do
    [[ -n "$dep" ]] && printf '\t\t%s \\\n' "$dep"
done > "$BLOCKS_DIR/BLOCK_ALPINE_BUILD_DEPS.txt"

# === 生成函数 ===

generate_debian() {
    local template_name="$1" tag_dir="$2" frame_ptrs_block="$3"

    local output_dir="$DOCKERFILES_DIR/$V_VERSION/$tag_dir"
    mkdir -p "$output_dir"

    # Debian make flags: --enable-optimizations
    printf '\t\t--enable-optimizations \\\n' > "$BLOCKS_DIR/BLOCK_MAKE_FLAGS.txt"

    # 基本 sed 替换
    sed \
        -e "s/{VERSION}/$V_VERSION/g" \
        -e "s/{DEBIAN_VERSION}/$V_DEBIAN/g" \
        "$SCRIPT_DIR/$template_name" > "$output_dir/Dockerfile.tmp"

    # awk 块替换：使用 BLOCK_FRAME_PTRS 变量名
    if [[ "$MINOR" -ge 12 ]] && [[ -f "$BLOCKS_DIR/$frame_ptrs_block.txt" ]]; then
        cp "$BLOCKS_DIR/$frame_ptrs_block.txt" "$BLOCKS_DIR/BLOCK_FRAME_PTRS.txt"
    else
        : > "$BLOCKS_DIR/BLOCK_FRAME_PTRS.txt"
    fi
    replace_blocks "$output_dir/Dockerfile.tmp" "$output_dir/Dockerfile"
    rm -f "$output_dir/Dockerfile.tmp" "$BLOCKS_DIR/BLOCK_FRAME_PTRS.txt"
    echo "  dockerfiles/$V_VERSION/$tag_dir/Dockerfile" >&2
}

generate_alpine() {
    local alpine_ver="$1"
    local output_dir="$DOCKERFILES_DIR/$V_VERSION/alpine"
    mkdir -p "$output_dir"

    # 基本 sed 替换
    sed \
        -e "s/{VERSION}/$V_VERSION/g" \
        -e "s/{ALPINE_VERSION}/$alpine_ver/g" \
        "$SCRIPT_DIR/Dockerfile-alpine.template" > "$output_dir/Dockerfile.tmp"

    # awk 块替换：使用 BLOCK_FRAME_PTRS 变量名
    if [[ "$MINOR" -ge 12 ]] && [[ -f "$BLOCKS_DIR/BLOCK_FRAME_PTRS_ALPINE.txt" ]]; then
        cp "$BLOCKS_DIR/BLOCK_FRAME_PTRS_ALPINE.txt" "$BLOCKS_DIR/BLOCK_FRAME_PTRS.txt"
    else
        : > "$BLOCKS_DIR/BLOCK_FRAME_PTRS.txt"
    fi
    replace_blocks "$output_dir/Dockerfile.tmp" "$output_dir/Dockerfile"
    rm -f "$output_dir/Dockerfile.tmp" "$BLOCKS_DIR/BLOCK_FRAME_PTRS.txt"
    echo "  dockerfiles/$V_VERSION/alpine/Dockerfile" >&2
}

# === 生成所有变体 ===

# Debian 全量
generate_debian "Dockerfile-debian.template" "debian" "BLOCK_FRAME_PTRS_DEBIAN"

# Debian slim
generate_debian "Dockerfile-debian-slim.template" "debian-slim" "BLOCK_FRAME_PTRS_DEBIAN"

# Alpine
for VER in $V_ALPINE_LIST; do
    generate_alpine "$VER"
done

echo "Done." >&2
