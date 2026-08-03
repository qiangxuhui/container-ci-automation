#!/bin/bash
# tools/lib.sh — 统一共享函数

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

    python3 - "$config_file" << 'PYEOF'
import yaml
import sys

config_file = sys.argv[1]
with open(config_file) as f:
    config = yaml.safe_load(f)
print(f'PROJECT_ORG="{config["project"]["org"]}"')
print(f'PROJECT_NAME="{config["project"]["name"]}"')
print(f'REGISTRY="{config["push"]["registry"]}"')
print(f'REPOSITORY="{config["push"]["repository"]}"')
vs = config.get('version_source', {})
print(f'VERSION_SOURCE_TYPE="{vs.get("type", "github_releases")}"')
print(f'VERSION_SOURCE_REPO="{vs.get("repository", "")}"')
print(f'VERSION_SOURCE_SCRIPT="{vs.get("script", "")}"')
PYEOF
}
