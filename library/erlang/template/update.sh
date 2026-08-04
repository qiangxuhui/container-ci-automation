#!/usr/bin/env bash
# library/erlang/template/update.sh
# 接收版本号，从上游 Dockerfile 提取元数据，生成 versions.json
set -Eeuo pipefail

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

VERSION="$1"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 28.5.0.4"
    exit 1
fi

if [[ -f versions.json ]] && [[ -s versions.json ]]; then
    json=$(< versions.json)
else
    json='{}'
fi

# 提取主版本号
MAJOR="${VERSION%%.*}"

# 变体版本（集中管理）
# 根据主版本号确定基础镜像版本
case "$MAJOR" in
    24|25)
        DEBIAN_VERSION="bullseye"
        ALPINE_VERSION="3.22"
        ;;
    26|27)
        DEBIAN_VERSION="bookworm"
        ALPINE_VERSION="3.24"
        ;;
    28|29)
        DEBIAN_VERSION="trixie"
        ALPINE_VERSION="3.24"
        ;;
    *)
        echo "ERROR: 不支持的主版本号: $MAJOR (仅支持 24-29)"
        exit 1
        ;;
esac

# 上游仓库路径（本地克隆）
UPSTREAM_DIR="${UPSTREAM_DIR:-/tmp/erlang-upstream}"

if [[ ! -d "$UPSTREAM_DIR/$MAJOR" ]]; then
    echo "ERROR: 上游目录不存在: $UPSTREAM_DIR/$MAJOR"
    echo "请设置 UPSTREAM_DIR 环境变量或确保 /tmp/erlang-upstream 存在"
    exit 1
fi

echo "提取版本 $VERSION 的元数据..." >&2

# === 使用 Python 提取元数据 ===
python3 << 'PYEOF'
import re
import json
import sys
import os

upstream_dir = os.environ.get("UPSTREAM_DIR", "/tmp/erlang-upstream")
major = os.environ.get("MAJOR")
version = os.environ.get("VERSION")
debian_version = os.environ.get("DEBIAN_VERSION")
alpine_version = os.environ.get("ALPINE_VERSION")
existing_json = os.environ.get("EXISTING_JSON", "{}")

def extract_var(content, var_name):
    """提取 Dockerfile 中的变量值"""
    pattern = rf'{var_name}="([^"]+)"'
    match = re.search(pattern, content)
    return match.group(1) if match else ""

def extract_deps(content, var_name):
    """提取多行依赖变量"""
    # 匹配 var_name='...\n...\n...' 格式
    pattern = rf"{var_name}='(.*?)'"
    match = re.search(pattern, content, re.DOTALL)
    if not match:
        return ""
    # 移除反斜杠换行和制表符
    deps = match.group(1)
    deps = re.sub(r'\\\s*\n\s*', ' ', deps)
    deps = re.sub(r'\t', ' ', deps)
    deps = ' '.join(deps.split())  # 合并多余空格
    return deps

# 读取 Dockerfiles
default_df = os.path.join(upstream_dir, major, "Dockerfile")
slim_df = os.path.join(upstream_dir, major, "slim", "Dockerfile")
alpine_df = os.path.join(upstream_dir, major, "alpine", "Dockerfile")

with open(default_df) as f:
    default_content = f.read()
with open(slim_df) as f:
    slim_content = f.read()
with open(alpine_df) as f:
    alpine_content = f.read()

# 提取变量
otp_version = extract_var(default_content, "OTP_VERSION")
rebar3_version = extract_var(default_content, "REBAR3_VERSION")
otp_download_url = extract_var(default_content, "OTP_DOWNLOAD_URL")
otp_download_url = otp_download_url.replace("${OTP_VERSION}", otp_version)
otp_download_sha256 = extract_var(default_content, "OTP_DOWNLOAD_SHA256")

# REBAR3 SHA256（默认变体取最后一个）
rebar3_matches = re.findall(r'REBAR3_DOWNLOAD_SHA256="([^"]+)"', default_content)
rebar3_sha256_default = rebar3_matches[-1] if rebar3_matches else ""

# REBAR3 SHA256（alpine 变体）
rebar3_alpine_matches = re.findall(r'REBAR3_DOWNLOAD_SHA256="([^"]+)"', alpine_content)
rebar3_sha256_alpine = rebar3_alpine_matches[-1] if rebar3_alpine_matches else ""

# 依赖
runtime_deps = extract_deps(default_content, "runtimeDeps")
build_deps = extract_deps(default_content, "buildDeps")
slim_runtime_deps = extract_deps(slim_content, "runtimeDeps")

print(f"OTP_VERSION={otp_version}", file=sys.stderr)
print(f"REBAR3_VERSION={rebar3_version}", file=sys.stderr)
print(f"OTP_DOWNLOAD_URL={otp_download_url}", file=sys.stderr)
print(f"RUNTIME_DEPS={runtime_deps}", file=sys.stderr)
print(f"BUILD_DEPS={build_deps}", file=sys.stderr)
print(f"SLIM_RUNTIME_DEPS={slim_runtime_deps}", file=sys.stderr)

# 构建 JSON
data = json.loads(existing_json)
data[version] = {
    "otp_version": otp_version,
    "rebar3_version": rebar3_version,
    "otp_download_url": otp_download_url,
    "otp_download_sha256": otp_download_sha256,
    "rebar3_sha256_default": rebar3_sha256_default,
    "rebar3_sha256_alpine": rebar3_sha256_alpine,
    "debian_version": debian_version,
    "alpine_version": alpine_version,
    "runtime_deps": runtime_deps,
    "build_deps": build_deps,
    "slim_runtime_deps": slim_runtime_deps,
}

print(json.dumps(data, indent=2))
PYEOF

# 保存结果
python3 << 'PYEOF' > versions.json
import json
import os
import sys

# 从环境变量读取
upstream_dir = os.environ.get("UPSTREAM_DIR", "/tmp/erlang-upstream")
major = os.environ.get("MAJOR")
version = os.environ.get("VERSION")
debian_version = os.environ.get("DEBIAN_VERSION")
alpine_version = os.environ.get("ALPINE_VERSION")

# 读取现有 JSON
existing_json_path = "versions.json"
if os.path.exists(existing_json_path) and os.path.getsize(existing_json_path) > 0:
    with open(existing_json_path) as f:
        data = json.load(f)
else:
    data = {}

def extract_var(content, var_name):
    import re
    pattern = rf'{var_name}="([^"]+)"'
    match = re.search(pattern, content)
    return match.group(1) if match else ""

def extract_deps(content, var_name):
    import re
    pattern = rf"{var_name}='(.*?)'"
    match = re.search(pattern, content, re.DOTALL)
    if not match:
        return ""
    deps = match.group(1)
    deps = re.sub(r'\\\s*\n\s*', ' ', deps)
    deps = re.sub(r'\t', ' ', deps)
    deps = ' '.join(deps.split())
    return deps

# 读取 Dockerfiles
default_df = os.path.join(upstream_dir, major, "Dockerfile")
slim_df = os.path.join(upstream_dir, major, "slim", "Dockerfile")
alpine_df = os.path.join(upstream_dir, major, "alpine", "Dockerfile")

with open(default_df) as f:
    default_content = f.read()
with open(slim_df) as f:
    slim_content = f.read()
with open(alpine_df) as f:
    alpine_content = f.read()

# 提取变量
otp_version = extract_var(default_content, "OTP_VERSION")
rebar3_version = extract_var(default_content, "REBAR3_VERSION")
otp_download_url = extract_var(default_content, "OTP_DOWNLOAD_URL")
otp_download_url = otp_download_url.replace("${OTP_VERSION}", otp_version)
otp_download_sha256 = extract_var(default_content, "OTP_DOWNLOAD_SHA256")

import re
rebar3_matches = re.findall(r'REBAR3_DOWNLOAD_SHA256="([^"]+)"', default_content)
rebar3_sha256_default = rebar3_matches[-1] if rebar3_matches else ""

rebar3_alpine_matches = re.findall(r'REBAR3_DOWNLOAD_SHA256="([^"]+)"', alpine_content)
rebar3_sha256_alpine = rebar3_alpine_matches[-1] if rebar3_alpine_matches else ""

runtime_deps = extract_deps(default_content, "runtimeDeps")
build_deps = extract_deps(default_content, "buildDeps")
slim_runtime_deps = extract_deps(slim_content, "runtimeDeps")

data[version] = {
    "otp_version": otp_version,
    "rebar3_version": rebar3_version,
    "otp_download_url": otp_download_url,
    "otp_download_sha256": otp_download_sha256,
    "rebar3_sha256_default": rebar3_sha256_default,
    "rebar3_sha256_alpine": rebar3_sha256_alpine,
    "debian_version": debian_version,
    "alpine_version": alpine_version,
    "runtime_deps": runtime_deps,
    "build_deps": build_deps,
    "slim_runtime_deps": slim_runtime_deps,
}

print(json.dumps(data, indent=2))
PYEOF

echo "✓ versions.json 已更新" >&2
