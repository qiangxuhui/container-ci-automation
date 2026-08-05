# 07 — AGENTS.md 规范

## 目的

为 AI agent 后续自动化修复构建报错提供必要的上下文信息。

## 文件位置

每个项目目录下：

```
library/ruby/
├── AGENTS.md          ← AI agent 上下文
├── config.yml
├── processed_versions.txt
└── template/
    └── ...
```

## 文件结构

```markdown
# {project} — AGENTS.md

## 模板上游信息

| 字段 | 值 |
|------|-----|
| 上游仓库 | docker-library/ruby |
| 上游分支 | master |
| 上次同步 commit | abc123def |
| 上次同步时间 | 2026-07-30 |

### 上游模板路径映射

| 上游路径 | 本地路径 |
|----------|----------|
| template/Dockerfile.template | Dockerfile-forky.template |
| template/Dockerfile-alpine.template | Dockerfile-alpine.template |

## 本地适应性调整

### Dockerfile-forky.template

- **基础镜像替换**: `buildpack-deps:forky` → `lcr.loongnix.cn/library/buildpack-deps:forky`
- **添加编译依赖**: `gcc-12-loongarch64-linux-gnu`
- **其他调整**: 无

### Dockerfile-alpine.template

- **基础镜像替换**: `alpine:3.24` → `lcr.loongnix.cn/library/alpine:3.24`
- **其他调整**: 无

## 已知问题

| 问题 | 影响 | 解决方案 |
|------|------|----------|
| PECL imagick PHP 8.5 不可用 | WordPress 构建失败 | 跳过 imagick 安装 |
| V8 LoongArch64 内存 bug | Node.js npm install 崩溃 | 在 x86 上编译 JS |

## 构建信息

- **构建命令**: `python3 tools/build.py library/ruby`
- **Dry run**: `DRY_RUN=true python3 tools/build.py library/ruby`
- **Registry**: `lcr.loongnix.cn`
- **Repository**: `library/ruby`
- **平台**: `linux/loong64`

## 维护记录

| 日期 | 问题 | 修复 | Commit |
|------|------|------|--------|
| 2026-07-30 | 基础镜像损坏 | 切换 trixie → forky | abc123 |
| 2026-07-15 | PECL 安装失败 | 跳过 imagick | def456 |
```

## 字段说明

### 模板上游信息

记录模板来源，便于 AI 理解上游变更：

- `上游仓库`: 模板来源的 GitHub 仓库
- `上游分支`: 跟踪的分支
- `上次同步 commit`: 上次从上游同步的 commit
- `上次同步时间`: 同步时间

### 本地适应性调整

记录每个模板的本地修改，便于 AI 理解差异：

- **基础镜像替换**: 从官方镜像替换为 Loongnix registry
- **添加编译依赖**: 添加 LoongArch64 特定的编译工具
- **其他调整**: 任何其他本地修改

### 已知问题

记录已知的构建问题和解决方案，便于 AI 快速定位和修复：

- **问题**: 问题描述
- **影响**: 影响范围
- **解决方案**: 如何修复

## 自动生成

AGENTS.md 可以从以下信息自动生成：

1. config.yml 中的配置
2. 模板文件的 diff（与上游对比）
3. processed_versions.txt 中的历史记录
4. 构建日志中的错误记录

```bash
# 自动生成 AGENTS.md
./tools/generate_agents_md.sh library/ruby
```

## AI Agent 使用

AI agent 在修复构建错误时：

1. 读取 AGENTS.md 了解项目背景
2. 检查已知问题列表
3. 理解本地适应性调整
4. 执行修复

```bash
# AI agent 读取 AGENTS.md
cat library/ruby/AGENTS.md

# AI agent 修复构建错误
# 基于 AGENTS.md 中的信息进行修复
```
