#!/usr/bin/env bash
# library/erlang/template/apply-templates.sh
# 接收版本号，读取 versions.json，使用 Python 渲染模板生成 Dockerfile
set -Eeuo pipefail

VERSION="$1"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 28.5.0.4"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKERFILES_DIR="$PROJECT_DIR/dockerfiles"

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
V_OTP_VERSION=$(echo "$V" | jq -r '.otp_version')
V_REBAR3_VERSION=$(echo "$V" | jq -r '.rebar3_version')
V_OTP_DOWNLOAD_URL=$(echo "$V" | jq -r '.otp_download_url')
V_OTP_DOWNLOAD_SHA256=$(echo "$V" | jq -r '.otp_download_sha256')
V_REBAR3_SHA256_DEFAULT=$(echo "$V" | jq -r '.rebar3_sha256_default')
V_REBAR3_SHA256_ALPINE=$(echo "$V" | jq -r '.rebar3_sha256_alpine')
V_DEBIAN=$(echo "$V" | jq -r '.debian_version')
V_ALPINE=$(echo "$V" | jq -r '.alpine_version')
V_RUNTIME_DEPS=$(echo "$V" | jq -r '.runtime_deps')
V_BUILD_DEPS=$(echo "$V" | jq -r '.build_deps')
V_SLIM_RUNTIME_DEPS=$(echo "$V" | jq -r '.slim_runtime_deps')

echo "生成 Dockerfiles: erlang $V_OTP_VERSION" >&2

# === 使用 Python 渲染模板 ===
export SCRIPT_DIR DOCKERFILES_DIR VERSION
export V_OTP_VERSION V_REBAR3_VERSION V_OTP_DOWNLOAD_URL V_OTP_DOWNLOAD_SHA256
export V_REBAR3_SHA256_DEFAULT V_REBAR3_SHA256_ALPINE V_DEBIAN V_ALPINE
export V_RUNTIME_DEPS V_BUILD_DEPS V_SLIM_RUNTIME_DEPS

python3 -c '
import os
import re
import sys

# 从环境变量读取
variables = {
    "OTP_VERSION": os.environ["V_OTP_VERSION"],
    "REBAR3_VERSION": os.environ["V_REBAR3_VERSION"],
    "OTP_DOWNLOAD_URL": os.environ["V_OTP_DOWNLOAD_URL"],
    "OTP_DOWNLOAD_SHA256": os.environ["V_OTP_DOWNLOAD_SHA256"],
    "DEBIAN_VERSION": os.environ["V_DEBIAN"],
    "ALPINE_VERSION": os.environ["V_ALPINE"],
    "RUNTIME_DEPS": os.environ["V_RUNTIME_DEPS"],
    "BUILD_DEPS": os.environ["V_BUILD_DEPS"],
    "SLIM_RUNTIME_DEPS": os.environ["V_SLIM_RUNTIME_DEPS"],
    "REBAR3_SHA256_DEFAULT": os.environ["V_REBAR3_SHA256_DEFAULT"],
    "REBAR3_SHA256_ALPINE": os.environ["V_REBAR3_SHA256_ALPINE"],
}

script_dir = os.environ["SCRIPT_DIR"]
dockerfiles_dir = os.environ["DOCKERFILES_DIR"]
version = os.environ["VERSION"]

def render_template(template_path, output_path):
    """渲染模板文件"""
    os.makedirs(os.path.dirname(output_path), exist_ok=True)

    with open(template_path) as f:
        content = f.read()

    # 使用正则表达式替换 {VAR} 格式的占位符
    # 匹配 {VAR} 但不匹配 ${VAR}（Docker ENV 变量）
    def replace_var(match):
        var_name = match.group(1)
        return variables.get(var_name, match.group(0))

    content = re.sub(r"(?<!\$)\{(\w+)\}", replace_var, content)

    with open(output_path, "w") as f:
        f.write(content)

    print(f"  ✓ {output_path}", file=sys.stderr)

# debian（默认变体）
render_template(
    os.path.join(script_dir, "Dockerfile-debian.template"),
    os.path.join(dockerfiles_dir, version, "debian", "Dockerfile")
)

# debian-slim
render_template(
    os.path.join(script_dir, "Dockerfile-debian-slim.template"),
    os.path.join(dockerfiles_dir, version, "debian-slim", "Dockerfile")
)

# alpine（使用不同的 REBAR3 SHA256）
render_template(
    os.path.join(script_dir, "Dockerfile-alpine.template"),
    os.path.join(dockerfiles_dir, version, "alpine", "Dockerfile")
)

print("✓ 所有变体 Dockerfile 已生成", file=sys.stderr)
'
