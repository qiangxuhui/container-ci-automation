#!/bin/bash
# tools/log.sh — 日志与辅助函数

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly NC='\033[0m'

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        INFO)  color="${GREEN}" ;;
        WARN)  color="${YELLOW}" ;;
        ERROR) color="${RED}" ;;
        *)     color="${NC}" ;;
    esac
    echo -e "${color}[${timestamp}] [${level}] ${message}${NC}" >&2
}

update_versions_file() {
    local version_file="$1"
    local new_version="$2"
    local tmp_file="${version_file}.tmp"

    [[ -z "$new_version" ]] && { log ERROR "Empty version"; return 1; }
    [[ -z "$version_file" ]] && { log ERROR "Missing version file"; return 1; }

    touch "$version_file"

    {
        echo "$new_version"
        cat "$version_file"
    } | sort -Vu > "$tmp_file"

    if ! cmp -s "$version_file" "$tmp_file"; then
        mv "$tmp_file" "$version_file"
        log INFO "Added $new_version to $version_file"
    else
        rm -f "$tmp_file"
        log INFO "No changes to $version_file"
    fi
}

parse_config() {
    local config_file="$1"
    local global_config="${BASH_SOURCE[0]%/*}/../config.yml"

    python3 - "$config_file" "$global_config" << 'PYEOF'
import yaml
import sys

config_file = sys.argv[1]
global_config_file = sys.argv[2]

# 加载全局配置
with open(global_config_file) as f:
    global_config = yaml.safe_load(f)
registry = global_config.get("registry", "")

# 加载项目配置
with open(config_file) as f:
    config = yaml.safe_load(f)

org = config["project"]["org"]
name = config["project"]["name"]

print(f'PROJECT_ORG="{org}"')
print(f'PROJECT_NAME="{name}"')
print(f'REGISTRY="{registry}"')
print(f'REPOSITORY="{org}/{name}"')

vs = config.get('version_source', {})
print(f'VERSION_SOURCE_TYPE="{vs.get("type", "github_releases")}"')
print(f'VERSION_SOURCE_REPO="{vs.get("repository", "")}"')
print(f'VERSION_SOURCE_SCRIPT="{vs.get("script", "")}"')
PYEOF
}

# 解析 variants 配置，写入临时文件供 process_version.sh 使用
# 输出格式（每行一个 variant）：
#   variant_name|template_file|tag1,tag2,...
parse_variants() {
    local config_file="$1"
    local output_file="$2"

    python3 - "$config_file" "$output_file" << 'PYEOF'
import yaml
import sys

config_file = sys.argv[1]
output_file = sys.argv[2]

with open(config_file) as f:
    config = yaml.safe_load(f)

variants = config.get('variants', [])
with open(output_file, 'w') as f:
    for v in variants:
        name = v.get('name', '')
        template = v.get('template', '')
        tags = v.get('tags', [])
        tags_str = ','.join(tags)
        f.write(f'{name}|{template}|{tags_str}\n')
PYEOF
}


