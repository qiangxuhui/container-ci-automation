# Container CI Automation — AGENTS.md

## 项目用途

将 container-ci 中 76+ 个项目的流水线管理从「每个项目手写脚本」转变为「声明式配置 + 统一工具」。

## 当前目标：AI 运维工具（2026-09 起）

项目最终形态是「**全部已迁移项目每天定时构建并推送 lcr.loongnix.cn**」。构建进入每日定时后，失败 CI 的排查修复会从偶发变成日常负担：上游版本变更、模板变量缺失、下载链接失效、基础镜像变动、Dockerfile 语法等问题，都需要有人去 GitHub 页面查看、定位、修复。

本阶段为其构建一套 **AI 运维工具，目标是每天获取构建失败的 CI 流水线并进行修复**，采用增量策略：**先走通 library/alpine 单项目的 ai-ops 闭环，再推广到其他项目，最后接入每日定时自动巡检（当前不做定时任务）**：

1. 获取构建失败的 CI 流水线（当前：指定项目手动采集；终态：每日自动全仓）
2. 结合 `library/<project>/AGENTS.md` 上下文定位失败根因
3. 在约束内自动修复（template/、config.yml 等），`build.py --test` 本地验证（**autofix 自动模式只到验证为止，不提交不推送**，改动留工作区由人工审阅）
4. 修复提交并重跑失败的 workflow 至转绿（autofix 模式下由人工在审阅改动后提交并触发重跑）；无法定位/连续失败时产出交接报告交人工
5. 修复经验沉淀：完整会话报告落盘 `log/ai-ops/`（不入库）越修越快；`docs/ai-ops/ci-fix.md` 为历史沉淀（2026-09-09 起 autofix 不再自动回写）

**试点项目**：`library/alpine` —— 唯一已接入每日定时 CI 的项目（schedule `0 16 * * *`），每日有真实构建与失败样本；单变体、无编译，闭环链路最简。推广期第一个项目选编译型（httpd/golang）补齐编译失败模式。

**开发计划**：`docs/ai-ops/README.md`（决策记录、三阶段计划、待确认项清单）。
**修复执行手册**：`docs/ai-ops/runbook.md`（Hermes 会话 / autofix 按此执行闭环）。

**当前进度**：10 个项目已迁移；仅 library/alpine 接入每日定时 CI（终态再启用其余 schedule）；tools/ai-ops.py 已落地（fetch/rerun/dispatch/commit/branch/commit-pr/autofix 子命令），docs/ai-ops/ 方案与手册已建立；下一步：library/alpine 试点闭环；**tools/ai-ops.py 重构进行中**：目标文件 tools/ai-ops-1.py（fetch/autofix/branch/commit-msg/commit-pr 已落地：均从状态文件 .aiops-fix-info.json 读取 run 上下文/分支名/文件路径（process-error、commit-msg），commit-pr 只 add 项目目录并推送状态文件中的修复分支发起 PR，方案见 docs/ai-ops/refactor-ai-ops.md，重构期间勿再直接改 tools/ai-ops.py）。

## 核心工具

| 文件 | 用途 |
|------|------|
| `config.yml` | 全局配置（registry 等） |
| `tools/build.py` | 统一入口，所有项目共用（--test / --dry-run / --versions / --push） |
| `tools/ai-ops.py` | AI 运维工具：确定性动作（fetch/rerun/dispatch/commit/branch/commit-pr）+ autofix 一键闭环（分析+修复+验证，不提交；会话报告落盘 log/ai-ops/）；commit-pr：只 add 项目目录 → commit -F commit-msg → push → gh pr create |
| `.github/workflows/build.yml` | 可复用 CI workflow（构建 + 推送 + 提交版本跟踪） |
| `.github/workflows/library-*.yml` | 每个项目一个定时 workflow（试点期仅 alpine 启用 schedule） |

## 调用方式

```bash
python3 tools/build.py library/debian
python3 tools/build.py --dry-run library/ruby
python3 tools/build.py --versions library/ruby
```

## 项目结构

```
config.yml                      ← 全局配置（registry）
.github/workflows/              ← 每日定时构建 CI
library/{project}/
├── AGENTS.md                   ← AI agent 上下文（修复前必读）
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

## 文档索引

| 文档 | 内容 |
|------|------|
| `docs/06-architecture.md` | 整体架构与 config.yml 强约束 |
| `docs/07-agents-md.md` | 项目 AGENTS.md 编写规范（含维护记录表） |
| `docs/08-migration-experience.md` | 迁移规范（模板变量提取与验证流程） |
| `docs/ai-ops/README.md` | **AI 运维工具开发计划（当前目标）**：决策、三阶段计划、待确认项 |
| `docs/ai-ops/runbook.md` | **AI 修复执行手册**：闭环流程、失败分类表、演练/止损、命令速查 |
| `docs/ai-ops/ci-fix.md` | **CI 修复记录（历史）**：迁移期结构化沉淀；2026-09-09 起 autofix 不再自动回写，新沉淀以 log/ai-ops/ 会话报告为准 |
| `docs/ai-ops/refactor-ai-ops.md` | **ai-ops.py 重构方案**：现状结构、动机、目标形态、兼容性清单、待确认项（重构期间前置信息入口） |
| `migration-status.md` | 迁移进度跟踪（本地个人使用，被 .gitignore 忽略，仓库内不存在） |

## AI 修复须知

执行 ai-ops 修复（autofix 会话 / 手动会话）必须遵守：

1. 修项目前必读 `library/<project>/AGENTS.md`（已知问题 / 本地调整 / 维护记录）与 docs/08 迁移规范
2. 幂等：无查重（2026-09-09 移除 write_ci_fix 后不再检查已回写记录，同一失败 run 可重复修复；避免重复靠 fetch→人工审阅→提交的流程节奏）
3. 只改与根因相关的文件（项目 template/、config.yml、get_versions.sh；tools/build.py 仅当其自身有 bug）；**严禁改全局 config.yml 的 registry；严禁 git add -A 卷入无关改动**，只 add 本次相关文件
4. 改 .sh 先 `bash -n`；构建验证用 `python3 tools/build.py --test library/<project> <version>`（不推送）；完整 loong64 构建耗时长时可只验证版本获取/模板渲染链路并如实说明
5. Debian 基础镜像统一 forky；FROM 不加 registry 前缀；变体/标签命名规范见 docs/08
6. **autofix 会话不写任何项目的 AGENTS.md**（受保护文件，一次性会话写入会审批超时被拒）；修复后只自动落盘会话报告 `log/ai-ops/{date}-{project}.md`（不入库），**不再自动回写 `docs/ai-ops/ci-fix.md`**（2026-09-09 移除脚本回写）
7. autofix 会话不执行 git add / git commit / git push（只分析+修复+验证）；`commit-pr` 子命令（只 add 项目目录 → commit -F commit-msg → push → gh pr create）用于人工审阅改动后提交并发起 PR；`commit` 子命令（git add -A）仅用于人工审阅改动后的手动提交
8. autofix 每次会话自动落盘 `log/ai-ops/{date}-{project}.md`（错误原因+修复过程，不入库）；`docs/ai-ops/ci-fix.md` 保留为历史沉淀，不再自动追加

## 迁移经验文档与待迁移项目

未迁移项目清单见 `migration-status.md`；迁移经验见 `docs/08-migration-experience.md`（含模板变量提取和验证流程），迁移时参考其中的经验。