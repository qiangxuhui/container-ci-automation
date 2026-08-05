#!/bin/bash
# library/rust/get_versions.sh
# 输出最新稳定 Rust 版本号（1 行），格式 a.b.c
set -eo pipefail

wget -qO- 'https://static.rust-lang.org/dist/channel-rust-stable.toml' \
    | grep -A1 '^\[pkg\.rust\]$' \
    | tail -1 \
    | sed 's/.*"\([0-9]*\.[0-9]*\.[0-9]*\).*/\1/'
