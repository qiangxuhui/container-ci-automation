# Container CI Automation — AGENTS.md

## 项目用途

将 container-ci 中 76+ 个项目的流水线管理从「每个项目手写脚本」转变为「声明式配置 + 统一工具」。

## 核心工具

| 文件 | 用途 |
|------|------|
| `tools/process_version.sh` | 统一入口，所有项目共用 |
| `tools/lib.sh` | 共享函数（日志、版本管理、配置解析） |

## 调用方式

```bash
./tools/process_version.sh library/debian
DRY_RUN=true ./tools/process_version.sh library/ruby
```

## 项目结构

```
library/{project}/
├── AGENTS.md              ← AI agent 上下文
├── config.yml             ← 声明式配置
├── processed_versions.txt ← 版本跟踪
├── fetch_versions.sh      ← 自定义版本脚本（可选）
└── template/
    ├── update.sh          ← 项目专属：处理变量
    ├── apply-templates.sh ← 项目专属：应用模板
    └── Dockerfile-*.template
```

## 迁移经验文档

| 文档 | 内容 |
|------|------|
| `docs/08-migration-experience.md` | debian 项目迁移经验，包含问题和解决方案 |
| `docs/01-declarative-config.md` | config.yml 格式规范 |
| `docs/03-unified-tools.md` | 统一工具设计文档 |
| `migration-status.md` | 迁移进度跟踪 |

## 待迁移项目

未迁移项目清单见 `migration-status.md`。

参考 `docs/08-migration-experience.md` 中的经验进行迁移。
