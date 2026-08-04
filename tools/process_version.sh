#!/bin/bash
# tools/process_version.sh — 统一入口
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# ===== 帮助信息 =====
usage() {
    cat << 'EOF'
用法: process_version.sh <project_dir> [version]

参数:
  project_dir    项目目录（如 library/ruby, library/debian）
  version        版本号（可选，仅测试模式需要）

选项:
  --help, -h     显示此帮助信息
  --test, -t     测试模式

模式说明:
  默认模式:
    ./tools/process_version.sh library/ruby
    - 获取版本列表（支持多版本）
    - 检查是否已构建
    - 未构建则执行构建
    - 推送镜像
    - 更新 processed_versions.txt

  测试模式:
    ./tools/process_version.sh --test library/ruby 4.0.6
    ./tools/process_version.sh -t library/ruby 4.0.6
    - 必须指定版本号
    - 无论是否已构建都执行
    - 不推送镜像
    - 不更新 processed_versions.txt

示例:
  ./tools/process_version.sh library/ruby
  ./tools/process_version.sh library/debian
  ./tools/process_version.sh --test library/ruby 4.0.6
  ./tools/process_version.sh -t library/debian 20260803T022142Z
EOF
    exit 0
}

# ===== 解析参数 =====
TEST_MODE=false
PROJECT_DIR=""
VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            usage
            ;;
        --test|-t)
            TEST_MODE=true
            shift
            ;;
        -*)
            log ERROR "未知选项: $1"
            usage
            ;;
        *)
            if [[ -z "$PROJECT_DIR" ]]; then
                PROJECT_DIR="$1"
            elif [[ -z "$VERSION" ]]; then
                VERSION="$1"
            fi
            shift
            ;;
    esac
done

if [[ -z "$PROJECT_DIR" ]]; then
    log ERROR "请指定项目目录"
    usage
fi

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# 测试模式必须指定版本号
if [[ "$TEST_MODE" == "true" ]] && [[ -z "$VERSION" ]]; then
    log ERROR "测试模式必须指定版本号"
    echo "用法: $0 --test <project_dir> <version>"
    exit 1
fi

# 加载配置
eval "$(parse_config "$PROJECT_DIR/config.yml")"

# 解析 variants
VARIANTS_FILE=$(mktemp)
trap "rm -f $VARIANTS_FILE" EXIT
parse_variants "$PROJECT_DIR/config.yml" "$VARIANTS_FILE"

main() {
    log INFO "========================================="
    if [[ "$TEST_MODE" == "true" ]]; then
        log INFO "测试模式: $PROJECT_ORG/$PROJECT_NAME"
    else
        log INFO "处理: $PROJECT_ORG/$PROJECT_NAME"
    fi
    log INFO "========================================="

    # 1. 获取版本列表
    local versions=()
    if [[ -n "$VERSION" ]]; then
        versions=("$VERSION")
    else
        while IFS= read -r ver; do
            [[ -n "$ver" ]] && versions+=("$ver")
        done < <(get_versions)
    fi

    if [[ ${#versions[@]} -eq 0 ]]; then
        log INFO "未找到版本"
        return 0
    fi

    log INFO "版本: ${versions[*]}"

    # 2. 逐个处理版本
    for version in "${versions[@]}"; do
        # 检查是否已处理（测试模式跳过检查）
        if [[ "$TEST_MODE" != "true" ]]; then
            if grep -qxF "$version" "$PROJECT_DIR/processed_versions.txt" 2>/dev/null; then
                log INFO "版本 $version 已构建，跳过"
                continue
            fi
        else
            log INFO "测试模式: 强制构建版本 $version"
        fi

        log INFO "版本 $version 开始构建..."

        # 3. update.sh <version>
        run_update_script "$version"

        # 4. apply-templates.sh <version>
        run_apply_templates "$version"

        # 5. 构建（测试模式不推送）
        build_all_variants "$version"

        # 6. 更新 processed_versions.txt（测试模式跳过）
        if [[ "$TEST_MODE" != "true" ]]; then
            update_versions_file "$PROJECT_DIR/processed_versions.txt" "$version"
            git_commit_with_retry "$PROJECT_DIR" "$version"
        else
            log INFO "测试模式: 跳过 processed_versions.txt 更新"
            log INFO "测试模式: 跳过 git commit"
        fi
    done
}

# ===== 获取版本列表（支持多行输出）=====
get_versions() {
    case "$VERSION_SOURCE_TYPE" in
        github_releases)
            fetch_from_github_releases
            ;;
        script)
            fetch_from_script
            ;;
        *)
            log ERROR "未知版本源类型: $VERSION_SOURCE_TYPE"
            exit 1
            ;;
    esac
}

# ===== 从 GitHub releases 获取最新版本 =====
fetch_from_github_releases() {
    log INFO "从 github.com/$VERSION_SOURCE_REPO 获取最新版本"

    gh api "repos/$VERSION_SOURCE_REPO/releases/latest" --jq '.tag_name' | \
    while read -r tag; do
        if [[ "$tag" =~ $VERSION_SOURCE_TAG_REGEX ]]; then
            echo "${BASH_REMATCH[1]}"
        fi
    done
}

# ===== 从自定义脚本获取最新版本 =====
fetch_from_script() {
    local script="$PROJECT_DIR/$VERSION_SOURCE_SCRIPT"

    if [[ ! -f "$script" ]]; then
        log ERROR "版本脚本未找到: $script"
        exit 1
    fi

    log INFO "从脚本获取最新版本: $VERSION_SOURCE_SCRIPT"

    chmod +x "$script"
    "$script"
}

# ===== 执行 update.sh =====
run_update_script() {
    local version="$1"

    log INFO "  执行 update.sh $version"

    cd "$PROJECT_DIR/template"
    ./update.sh "$version"
    cd - > /dev/null
}

# ===== 执行 apply-templates.sh =====
run_apply_templates() {
    local version="$1"

    log INFO "  执行 apply-templates.sh $version"

    cd "$PROJECT_DIR/template"
    ./apply-templates.sh "$version"
    cd - > /dev/null
}

# ===== 构建所有变体 =====
build_all_variants() {
    local version="$1"

    while IFS='|' read -r variant_name template_file tags_str; do
        [[ -z "$variant_name" ]] && continue

        local build_dir="$PROJECT_DIR/dockerfiles/$version/$variant_name"

        if [[ ! -d "$build_dir" ]]; then
            log WARN "变体目录不存在: $build_dir，跳过"
            continue
        fi

        build_variant "$version" "$variant_name" "$tags_str"
    done < "$VARIANTS_FILE"
}

# ===== 计算版本变量 =====
compute_version_vars() {
    local version="$1"
    # 语义版本: 3.24.1 → major=3, minor=3.24
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        MAJOR_VERSION="${version%%.*}"
        MINOR_VERSION="${version%.*}"
    else
        MAJOR_VERSION="$version"
        MINOR_VERSION="$version"
    fi
}

# ===== buildx 构建单个变体 =====
build_variant() {
    local version="$1"
    local variant_name="$2"
    local tags_str="$3"
    local build_dir="$PROJECT_DIR/dockerfiles/$version/$variant_name"

    if [[ ! -f "$build_dir/Dockerfile" ]]; then
        log WARN "Dockerfile 未找到: $build_dir/Dockerfile，跳过"
        return 0
    fi

    # 计算版本变量
    compute_version_vars "$version"

    # 渲染 tags：替换 {version}, {major_version}, {minor_version}
    local tags=()
    IFS=',' read -ra tag_patterns <<< "$tags_str"
    for pattern in "${tag_patterns[@]}"; do
        local tag="$pattern"
        tag="${tag//\{version\}/$version}"
        tag="${tag//\{major_version\}/$MAJOR_VERSION}"
        tag="${tag//\{minor_version\}/$MINOR_VERSION}"
        tags+=("$REGISTRY/$REPOSITORY:$tag")
    done

    # 构建 tag 参数
    local tag_args=""
    for tag in "${tags[@]}"; do
        tag_args="$tag_args -t $tag"
    done

    log INFO "  构建: ${tags[0]}"
    docker buildx build \
        --platform linux/loong64 \
        --load \
        $tag_args \
        "$build_dir"

    # 推送（测试模式跳过）
    if [[ "$TEST_MODE" != "true" ]]; then
        log INFO "  推送..."
        docker buildx build \
            --platform linux/loong64 \
            --push \
            $tag_args \
            "$build_dir"
    else
        log INFO "  测试模式: 跳过推送"
    fi
}

# ===== latest tag 逻辑 =====
should_update_latest() {
    local version="$1"
    local latest_file="$PROJECT_DIR/processed_versions.txt"

    if [[ ! -f "$latest_file" ]] || [[ ! -s "$latest_file" ]]; then
        return 0
    fi

    local current_latest
    current_latest=$(tail -1 "$latest_file")

    # 版本比较
    local higher
    higher=$(printf '%s\n%s\n' "$version" "$current_latest" | sort -V | tail -1)
    [[ "$higher" == "$version" && "$version" != "$current_latest" ]]
}

# ===== 提交并推送（带冲突重试） =====
git_commit_with_retry() {
    local project_dir="$1"
    local version="$2"
    local max_retries=3
    local retry=0

    cd "$project_dir"
    while [ $retry -lt $max_retries ]; do
        update_versions_file processed_versions.txt "$version"

        git add processed_versions.txt dockerfiles/
        git config user.name "github-actions[bot]"
        git config user.email "github-actions[bot]@users.noreply.github.com"
        git commit -m "$(basename "$(pwd)"): add version $version" 2>/dev/null || true

        if git pull --rebase && git push origin main; then
            log INFO "推送成功"
            cd - > /dev/null
            return 0
        fi

        retry=$((retry + 1))
        if [ $retry -lt $max_retries ]; then
            log WARN "推送失败 (第 $retry/$max_retries 次)，重试中..."
            git reset --soft HEAD~1 2>/dev/null || true
            git pull --rebase
            sleep $((retry * 2))
        fi
    done

    log ERROR "推送失败，已重试 $max_retries 次"
    cd - > /dev/null
    return 1
}

main
