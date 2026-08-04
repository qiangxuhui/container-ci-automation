# library/php

## 上游仓库

- https://github.com/docker-library/php
- 分支: master
- 模板: Dockerfile-linux.template (jq-template.awk 渲染)

## 上游结构

- versions.sh → 查询 PHP API 获取每个大版本最新版本
- apply-templates.sh → 使用 jq-template.awk 渲染模板
- 模板使用 `{{ }}` 语法，支持条件逻辑 (is_alpine, variant 等)

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
- 使用 jq-template.awk 渲染（与上游一致，保证 Dockerfile 内容一致）
