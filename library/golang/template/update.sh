#!/usr/bin/env bash
# library/golang/template/update.sh
# 接收完整版本号，从 go.dev API 获取下载信息，生成 versions.json
set -Eeuo pipefail

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

VERSION="$1"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 1.26.5"
    exit 1
fi

if [[ -f versions.json ]] && [[ -s versions.json ]]; then
    json=$(< versions.json)
else
    json='{}'
fi

# 变体版本（按需修改）
alpine_version="3.24"
debian_version="forky"

# 从 API 获取数据
new_data=$(
    wget -qO- 'https://golang.org/dl/?mode=json&include=all' \
    | jq -c --arg ver "$VERSION" '
        [.[] | select(.version == ("go" + $ver))]
        | first
        | if . then
            {
                version: (.version | ltrimstr("go")),
                amd64_url:   ([.files[] | select(.kind=="archive" and .os=="linux" and .arch=="amd64")]   | first | "https://dl.google.com/go/" + .filename),
                amd64_sha256: ([.files[] | select(.kind=="archive" and .os=="linux" and .arch=="amd64")]   | first | .sha256),
                armhf_url:   ([.files[] | select(.kind=="archive" and .os=="linux" and .arch=="armv6l")]  | first | "https://dl.google.com/go/" + .filename),
                armhf_sha256: ([.files[] | select(.kind=="archive" and .os=="linux" and .arch=="armv6l")]  | first | .sha256),
                arm64_url:   ([.files[] | select(.kind=="archive" and .os=="linux" and .arch=="arm64")]   | first | "https://dl.google.com/go/" + .filename),
                arm64_sha256: ([.files[] | select(.kind=="archive" and .os=="linux" and .arch=="arm64")]   | first | .sha256),
                i386_url:    ([.files[] | select(.kind=="archive" and .os=="linux" and .arch=="386")]     | first | "https://dl.google.com/go/" + .filename),
                i386_sha256: ([.files[] | select(.kind=="archive" and .os=="linux" and .arch=="386")]     | first | .sha256),
                loong64_url:   ([.files[] | select(.kind=="archive" and .os=="linux" and .arch=="loong64")] | first | "https://dl.google.com/go/" + .filename),
                loong64_sha256: ([.files[] | select(.kind=="archive" and .os=="linux" and .arch=="loong64")] | first | .sha256),
                mips64el_url:   ([.files[] | select(.kind=="archive" and .os=="linux" and .arch=="mips64le")] | first | "https://dl.google.com/go/" + .filename),
                mips64el_sha256: ([.files[] | select(.kind=="archive" and .os=="linux" and .arch=="mips64le")] | first | .sha256),
                ppc64el_url:   ([.files[] | select(.kind=="archive" and .os=="linux" and .arch=="ppc64le")] | first | "https://dl.google.com/go/" + .filename),
                ppc64el_sha256: ([.files[] | select(.kind=="archive" and .os=="linux" and .arch=="ppc64le")] | first | .sha256),
                riscv64_url:   ([.files[] | select(.kind=="archive" and .os=="linux" and .arch=="riscv64")] | first | "https://dl.google.com/go/" + .filename),
                riscv64_sha256: ([.files[] | select(.kind=="archive" and .os=="linux" and .arch=="riscv64")] | first | .sha256),
                s390x_url:   ([.files[] | select(.kind=="archive" and .os=="linux" and .arch=="s390x")]   | first | "https://dl.google.com/go/" + .filename),
                s390x_sha256: ([.files[] | select(.kind=="archive" and .os=="linux" and .arch=="s390x")]   | first | .sha256)
            }
          else
            empty
          end
    '
)

if [[ -z "$new_data" ]]; then
    echo "error: version $VERSION not found" >&2
    exit 1
fi

echo "version: $VERSION" >&2

# 添加变体版本信息
new_data=$(echo "$new_data" | jq -c \
    --arg alpine "$alpine_version" \
    --arg debian "$debian_version" \
    '. + {alpine_version: $alpine, debian_version: $debian}')

json=$(echo "$json" | jq -c --argjson d "$new_data" '.[$d.version] = $d')
echo "$json" | jq -S . > versions.json

echo "Version info saved to versions.json"
