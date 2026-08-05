# Container CI Automation — AGENTS.md

## 项目用途

将 container-ci 中 76+ 个项目的流水线管理从「每个项目手写脚本」转变为「声明式配置 + 统一工具」。

## 核心工具

| 文件 | 用途 |
|------|------|
| `config.yml` | 全局配置（registry 等） |
| `tools/process_version.sh` | 统一入口，所有项目共用 |
| `tools/log.sh` | 日志与辅助函数 |

## 调用方式

```bash
./tools/process_version.sh library/debian
DRY_RUN=true ./tools/process_version.sh library/ruby
```

## 项目结构

```
config.yml                      ← 全局配置（registry）
library/{project}/
├── AGENTS.md                   ← AI agent 上下文
├── config.yml                  ← 项目声明式配置（org, name, variants）
├── processed_versions.txt      ← 版本跟踪
├── get_versions.sh             ← 自定义版本脚本（可选）
└── template/
    ├── update.sh               ← 项目专属：处理变量
    ├── apply-templates.sh      ← 项目专属：应用模板
    └── Dockerfile-*.template   ← 模板（FROM 不含 registry 前缀）
```

## 配置说明

- **全局 `config.yml`**：定义 registry（如 `lcr.loongnix.cn`），所有项目共享
- **项目 `config.yml`**：定义 org、name、version_source、variants
- **模板 FROM**：保持与上游一致，不加 registry 前缀。构建时由宿主机 Docker 配置解析基础镜像来源
- **推送目标**：由全局 registry + 项目 org/name 自动拼接（如 `lcr.loongnix.cn/library/ruby`）

## 迁移经验文档

| 文档 | 内容 |
|------|------|
| `docs/08-migration-experience.md` | 迁移规范，包含模板变量提取和验证流程 |
| `migration-status.md` | 迁移进度跟踪 |

## 待迁移项目

未迁移项目清单见 `migration-status.md`。

参考 `docs/08-migration-experience.md` 中的经验进行迁移。
