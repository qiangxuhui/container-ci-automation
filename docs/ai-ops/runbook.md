# AI 运维执行手册（runbook）

> 版本：v0.2（项目引用与文档路径随试点调整：docs/09、docs/10 → docs/ai-ops/）
> 日期：2026-09
> 适用：Phase 1-2 手动执行；Phase 3 由 Hermes cron 包装同一套流程

## 1. 定位与原则

本手册定义「AI 运维闭环」的执行流程：**采集失败 run → 分析根因 → 修复 → 验证 → 直推 → 重跑 → 回写**。Hermes agent 在手动会话中按本文执行；确定性动作一律调用 `tools/ai-ops.py`，分析/修复决策由 agent 负责。

**两种执行模式**：

| 模式 | 触发方式 | 适用 |
|------|----------|------|
| 自动化（autofix） | `python3 tools/ai-ops.py autofix <project> [--run-id N]` | 一键闭环：脚本拉起 hermes 一次性会话完成 步骤2-5（分析→修复→验证）+ 回写维护记录；**不提交不推送**，改动留工作区，提交/直推/重跑由人工审阅后执行；会话报告（错误原因+修复过程）自动落盘 `log/ai-ops/{date}-{project}.md` |
| 逐步（手动会话） | 本会话按 §3 步骤逐条执行 | 需要人工实时确认、或 autofix 无法处理（外部凭据、平台级决策）时 |

autofix 为幂等设计：同一失败 run 在维护记录表中已有处理记录（含上次修复的 commit）时会自动跳过并说明，不重复修复。

autofix 提交边界（2026-09 确认）：**只做错误分析 + 代码修复 + 验证，不提交、不推送**；修复改动与维护记录回写保留在工作区，由人工审阅后按步骤 6-7 提交、直推、重跑。

配套文档：`docs/ai-ops/README.md`（决策与阶段计划）、`docs/08-migration-experience.md`（迁移规范）、`docs/07-agents-md.md`（项目 AGENTS.md 规范，回写时参考）、仓库根 `AGENTS.md`（含「AI 修复须知」，autofix 会话与本文一并遵守）。

**执行原则**（与 README §6 一致，违反任意一条视为流程错误）：

1. 先读后改：动任何项目文件前必读 `library/<project>/AGENTS.md` 与 docs/08
2. 验证前置：未经 `build.py --test` 验证的修改不得提交；`.sh` 先 `bash -n`
3. 幂等：同一失败 run 不重复修复；已处理过的 run id 出现在维护记录中则跳过
4. 止损：同一 run 修复后仍未转绿累计 3 轮 → 停止，产出交接报告

## 2. 前置检查

```bash
cd /work/loongson-project/container-ci-automation
gh auth status                 # 需已登录且有本仓库权限
git status --short             # 工作区应干净（或确认无未提交冲突改动）
python3 tools/ai-ops.py --help # 工具可用
```

## 3. 执行流程（主循环）

### 步骤 1 — 读上下文（必做）

```bash
cat library/<project>/AGENTS.md
```

关注：已知问题表（命中即先套用既定解法）、本地适应性调整、维护记录（历史失败模式）、上游映射。必要时补看 `docs/08-migration-experience.md` 中与问题相关的约束（forky、变体命名、FROM 不带 registry 等）。

### 步骤 2 — 采集失败 run

```bash
python3 tools/ai-ops.py fetch library/<project> --since-hours 24
```

- 无失败 run → 本次闭环结束（空跑，幂等）
- 有失败 run → 记录 `run_id` 清单与日志路径 `.ai-ops/fetch/<project>/<run_id>.log`

### 步骤 3 — 分析分类（agent 决策）

读失败日志尾部（`tail -100 <log>`），对照以下分类：

| 分类 | 典型特征 / 触发点 | 常见修复 |
|------|-------------------|----------|
| 上游版本/模板漂移 | 上游发新版，update.sh 取到新版本但模板缺变量/渲染错 | 对比上游模板合并占位符；修 apply-templates.sh |
| 下载失败 | URL 404、checksum 不匹配、网络超时 | 核对下载站 URL/sha256 获取方式（对照项目 AGENTS.md） |
| 基础镜像问题 | forky/registry 拉取失败、基础镜像损坏 | 等待/重试 registry；检查宿主机 Docker 配置（见已知问题表） |
| Dockerfile 构建错误 | 编译失败、依赖缺失、loong64 约束 | 补依赖/改构建参数，遵循 docs/08 LoongArch64 约束 |
| 基础设施 | runner 掉线、并发提交 processed_versions.txt 冲突 | pull --rebase 重试；人工关注 runner |

输出结论：`最可能的根因 + 修复切入点 + 是否命中已知问题`。

### 步骤 4 — 修复计划（先简述）

列出准备改动的文件（按频率：`template/update.sh`、`apply-templates.sh`、`Dockerfile-*.template`、`config.yml`、`get_versions.sh`；`tools/build.py` 仅当自身有 bug）。手动模式下先向用户简述改动与理由再动手。

### 步骤 5 — 修复 + 验证链

```bash
bash -n library/<project>/template/*.sh              # 改 .sh 必做
python3 tools/build.py --test library/<project> <version>   # loong64 真实构建，不推送
```

- `--test` 会联网执行 update.sh（版本/checksum 获取）并实际 buildx 构建，是最强验证
- 渲染产物检查：`dockerfiles/<version>/<variant>/Dockerfile` 内容是否符合预期
- 完整 loong64 构建耗时长时，可退化为只验证版本获取/模板渲染链路，并在报告中如实说明
- 验证不过 → 继续修，同一 run 累计 3 轮不过 → 交接（§5）

### 步骤 6 — 提交直推（手动模式；autofix 模式下由人工执行）

```bash
python3 tools/ai-ops.py commit -m "fix(<project>): <一句话描述>"
git push origin main
```

注意：CI（build.yml）可能同时向 main 提交 processed_versions.txt，push 前先 `git pull --rebase origin main`。autofix 模式不执行本步：agent 只产出工作区改动与验证结果，由人工审阅后在此提交并直推。

### 步骤 7 — 重跑确认（手动模式；autofix 模式下由人工执行）

```bash
python3 tools/ai-ops.py rerun <run_id>     # 重跑失败 jobs
gh run watch <run_id>                      # 或轮询 gh run view <run_id>
```

- 转绿 → 进入步骤 8
- 仍失败 → 回到步骤 3 分析新日志（重跑轮数计入止损计数）

### 步骤 8 — 回写知识

1. 项目 AGENTS.md「维护记录」表加一行：`| 日期 | 问题 | 修复 | commit |`；表不存在则按 docs/07 规范建立
2. 新失败模式 →「已知问题」表（问题/影响/解决方案）
3. 影响到全局的发现（tools/、build.yml、registry）→ 在 `docs/ai-ops/README.md` §8 证据附录补充

## 4. 演练模式（Phase 1 验收用）

目的：闭环尚未有真实失败可修时，主动制造失败验证工具链。方式（任选其一，改后确认可复现）：

1. `update.sh` 中 sha256 下载 URL 改为不存在的路径（构建必失败，且根因清晰）
2. 模板中引入语法错误（渲染或构建阶段失败）
3. `config.yml` 变体 tags 写坏（渲染/进 registry 前失败）

流程：制造坏状态 → `tools/ai-ops.py dispatch library/alpine`（触发真实 CI 失败 run）→ 按 §3 主循环执行 → 闭环验收标准见 README §4 Phase 1（转绿 + commit 在 main + 维护记录更新 + 幂等）→ 还原坏状态改动（与修复冲突时以修复为准）。

## 5. 止损与交接

- 同一 run 连续 3 轮未转绿，或遇到需要上游/外部决策的问题（如 loong64 不可解的平台约束）→ 停止自动修复
- 交接报告内容：run_id、项目、失败分类、尝试过的修复与结果、残留问题、建议（禁用变体/跳过版本/转人工）

## 6. 命令速查

| 动作 | 命令 |
|------|------|
| 一键闭环（分析+修复+验证，不提交） | `python3 tools/ai-ops.py autofix library/alpine [--run-id <id>]` |
| 采集失败 run | `python3 tools/ai-ops.py fetch library/alpine --since-hours 24` |
| 查看失败日志 | `gh run view <run_id> --log-failed` / `tail -100 .ai-ops/fetch/alpine/<run_id>.log` |
| 重跑失败 jobs | `python3 tools/ai-ops.py rerun <run_id>` |
| 手动触发构建 | `python3 tools/ai-ops.py dispatch library/alpine [version]` |
| 提交 | `python3 tools/ai-ops.py commit -m "fix(alpine): ..."` |
| 构建验证 | `python3 tools/build.py --test library/alpine <version>` |
| 查看 autofix 会话记录 | `ls log/ai-ops/` → `cat log/ai-ops/2026-09-02-alpine.md` |

## 7. 待确认/后续同步项

- Phase 3 前再定：执行时点、通知渠道、修复确认粒度（当前手动模式天然可确认，无阻塞）
- 止损阈值 N=3 为建议值，运营一段后按真实失败频率调整
- autofix 提交边界已确认（2026-09）：不提交不推送，由人工审阅改动后执行步骤 6-7
- runbook 与 docs/ai-ops/README.md 保持一致；计划变更时优先更新 README，本文仅同步执行细节