#!/bin/bash
# tools/process_version.sh — 统一入口
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

PROJECT_DIR="$1"

if [[ -z "$PROJECT_DIR" ]]; then
    echo "Usage: $0 <project_dir>"
    echo "Example: $0 library/ruby"
    exit 1
fi

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
DRY_RUN="${DRY_RUN:-false}"

# 加载配置
eval "$(parse_config "$PROJECT_DIR/config.yml")"

main() {
    log INFO "========================================="
    log INFO "Processing: $PROJECT_ORG/$PROJECT_NAME"
    log INFO "========================================="

    # 1. 获取最新版本
    local version
    version=$(get_latest_version)

    if [[ -z "$version" ]]; then
        log INFO "No version found"
        return 0
    fi

    log INFO "Latest version: $version"

    # 2. 检查是否已处理
    if grep -qxF "$version" "$PROJECT_DIR/processed_versions.txt" 2>/dev/null; then
        log INFO "Version $version already built, skipping"
        return 0
    fi

    log INFO "Version $version is new, building..."

    # 3. update.sh <version>
    run_update_script "$version"

    # 4. apply-templates.sh <version>
    run_apply_templates "$version"

    # 5. 构建并推送
    build_all_variants "$version"

    # 6. 更新 processed_versions.txt
    update_versions_file "$PROJECT_DIR/processed_versions.txt" "$version"

    # 7. 提交并推送
    git_commit_with_retry "$PROJECT_DIR" "$version"
}

# ===== 获取最新版本 =====
get_latest_version() {
    case "$VERSION_SOURCE_TYPE" in
        github_releases)
            fetch_from_github_releases
            ;;
        script)
            fetch_from_script
            ;;
        *)
            log ERROR "Unknown version source type: $VERSION_SOURCE_TYPE"
            exit 1
            ;;
    esac
}

# ===== 从 GitHub releases 获取最新版本 =====
fetch_from_github_releases() {
    log INFO "Fetching latest version from github.com/$VERSION_SOURCE_REPO"

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
        log ERROR "Version script not found: $script"
        exit 1
    fi

    log INFO "Fetching latest version from script: $VERSION_SOURCE_SCRIPT"

    chmod +x "$script"
    "$script"
}

# ===== 执行 update.sh =====
run_update_script() {
    local version="$1"

    log INFO "  Running update.sh $version"

    if [[ "$DRY_RUN" == "true" ]]; then
        log INFO "  [DRY RUN] Would run: ./template/update.sh $version"
        return 0
    fi

    cd "$PROJECT_DIR/template"
    ./update.sh "$version"
    cd - > /dev/null
}

# ===== 执行 apply-templates.sh =====
run_apply_templates() {
    local version="$1"

    log INFO "  Running apply-templates.sh $version"

    if [[ "$DRY_RUN" == "true" ]]; then
        log INFO "  [DRY RUN] Would run: ./template/apply-templates.sh $version"
        return 0
    fi

    cd "$PROJECT_DIR/template"
    ./apply-templates.sh "$version"
    cd - > /dev/null
}

# ===== 构建所有变体 =====
build_all_variants() {
    local version="$1"

    for variant_dir in "$PROJECT_DIR/template/$version"/*/; do
        [[ -d "$variant_dir" ]] || continue
        local variant
        variant=$(basename "$variant_dir")
        build_variant "$version" "$variant"
    done
}

# ===== buildx 构建单个变体 =====
build_variant() {
    local version="$1"
    local variant="$2"
    local build_dir="$PROJECT_DIR/template/$version/$variant"

    if [[ ! -f "$build_dir/Dockerfile" ]]; then
        log WARN "Dockerfile not found: $build_dir/Dockerfile, skipping"
        return 0
    fi

    # 构建 tags
    local tags=()
    tags+=("$REGISTRY/$REPOSITORY:$version")

    # 第一个变体不加后缀，其他变体加后缀
    local first_variant
    first_variant=$(ls "$PROJECT_DIR/template/$version/" | head -1)
    if [[ "$variant" != "$first_variant" ]]; then
        tags[0]="$REGISTRY/$REPOSITORY:$version-$variant"
    fi

    # latest tag 逻辑：只在版本 >= 最新版本时更新
    if should_update_latest "$version"; then
        tags+=("$REGISTRY/$REPOSITORY:latest")
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log INFO "  [DRY RUN] Would build:"
        printf '    %s\n' "${tags[@]}"
        return 0
    fi

    # 构建 tag 参数
    local tag_args=""
    for tag in "${tags[@]}"; do
        tag_args="$tag_args -t $tag"
    done

    log INFO "  Building with buildx: ${tags[0]}"
    docker buildx build \
        --platform linux/loong64 \
        --load \
        $tag_args \
        "$build_dir"

    # 推送所有 tags
    if [[ "$DRY_RUN" != "local" ]]; then
        log INFO "  Pushing..."
        docker buildx build \
            --platform linux/loong64 \
            --push \
            $tag_args \
            "$build_dir"
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

        git add processed_versions.txt
        git config user.name "github-actions[bot]"
        git config user.email "github-actions[bot]@users.noreply.github.com"
        git commit -m "$(basename "$(pwd)"): add version $version" 2>/dev/null || true

        if git pull --rebase && git push origin main; then
            log INFO "Successfully pushed"
            cd - > /dev/null
            return 0
        fi

        retry=$((retry + 1))
        if [ $retry -lt $max_retries ]; then
            log WARN "Push failed (attempt $retry/$max_retries), retrying..."
            git reset --soft HEAD~1 2>/dev/null || true
            git pull --rebase
            sleep $((retry * 2))
        fi
    done

    log ERROR "Push failed after $max_retries attempts"
    cd - > /dev/null
    return 1
}

main
