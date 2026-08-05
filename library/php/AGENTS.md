# library/php

## 上游仓库

- https://github.com/docker-library/php
- 分支: master
- 模板: Dockerfile-linux.template (jq-template.awk 渲染)

## 上游结构

- versions.sh → 查询 PHP API 获取每个大版本最新版本
- apply-templates.sh → 使用 jq-template.awk 渲染模板
- 模板使用 `{{ }}` 语法，支持条件逻辑 (is_alpine, variant 等)

## 本地结构

- 模板按「基础系统 + 变体」拆分为 7 个独立模板
- 每个模板包含完整的 Dockerfile 内容（无占位符拼接）
- 使用 sed 渲染模板，避免 jq-template.awk 依赖

## 目录结构

```
template/
├── Dockerfile-debian-cli.template      # Debian CLI 变体
├── Dockerfile-debian-apache.template   # Debian Apache 变体
├── Dockerfile-debian-fpm.template      # Debian FPM 变体
├── Dockerfile-debian-zts.template      # Debian ZTS 变体
├── Dockerfile-alpine-cli.template      # Alpine CLI 变体
├── Dockerfile-alpine-fpm.template      # Alpine FPM 变体
├── Dockerfile-alpine-zts.template      # Alpine ZTS 变体
├── apply-templates.sh                  # 渲染脚本
├── update.sh                           # 版本元数据更新
├── versions.json                       # 版本数据
└── ...                                 # 辅助脚本
```

## 变体

上游变体格式: `{suite}/{variant}`
- suite: trixie, bookworm, alpine3.24, alpine3.23
- variant: cli, apache, fpm, zts
- alpine 没有 apache 变体

本地简化:
- debian (cli on forky) → latest
- debian-apache, debian-fpm, debian-zts
- alpine (cli on alpine3.24)
- alpine-fpm, alpine-zts

## 辅助脚本

以下脚本从上游拷贝，随 Dockerfile 一起打包到镜像中:
- docker-php-entrypoint
- docker-php-ext-configure
- docker-php-ext-enable
- docker-php-ext-install
- docker-php-source
- apache2-foreground (仅 apache 变体)

## 本地调整

- 基础镜像: debian → forky, alpine → 3.24 (仅最新版本)
- FROM 添加 lcr.loongnix.cn/library/ 前缀（模板内处理）
- 使用 sed 渲染模板，每个变体一个独立模板文件

## LoongArch64 适配

- PHP 8.2: fiber 支持（需要 .S 汇编文件）
- Alpine PHP 8.2: 额外需要 libucontext（musl 没有 swapcontext）
- 所有版本: 禁用 pcre-jit（loongarch64 不支持）
