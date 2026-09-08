# AI 运维工具（ai-ops）— 开发计划与总览

> 版本：v0.4（试点项目由 httpd 调整为 alpine，文档由 docs/09、docs/10 归并至 docs/ai-ops/）
> 日期：2026-09

## 0. 已确认决策

| 项 | 决策 |
|----|------|
| 监控范围 | 仅本仓库（qiangxuhui/container-ci-automation）的 workflow，不覆盖 container-ci 本体 |
| 提交流向 | 手动流程：修复验证通过后在修复分支（branch 子命令创建 {project_dir}-{YYYYMMDD}-{jobid}）上执行 `commit-pr` 子命令提交并发起 PR（base=main；library-alpine-pr.yml：PR 仅构建验证，merge 到 main 构建+推送）；**autofix 自动模式（2026-09 确认）不提交不推送**，改动留工作区，人工审阅后按上流程提交 |
| 每日语义 | 维持「检查新版本，有新版本才构建」（build.py 读 processed_versions.txt 去重） |
| 运行形态 | 终态方案 A：Hermes 本地 cron 每日定时执行；agent 只读 GitHub，构建验证走 loong64 机器 |
| 实施策略 | **增量验证：先 library/alpine 单项目 ai-ops 闭环 → 跑通后推广到其他项目 → 最后定时化**。当前阶段不做定时任务 |
| 工具形态 | 确定性动作（采集、拉日志、触发重跑、git 提交）脚本化为 tools/ai-ops.py；**分析+修复决策由 Hermes agent 按执行手册（runbook）驱动**；autofix 只到验证为止，不提交不推送 |
| 试点项目 | library/alpine：唯一已接入每日定时 CI 的项目，暴露真实失败样本；单变体、无编译，闭环链路最简 |
| 试点失败来源 | 优先用 alpine 每日真实构建产生的失败 run；无失败可修时按 runbook §4 主动制造失败演练闭环 |
| 文档位置 | ai-ops 文档集中于 `docs/ai-ops/`：`README.md`（本文件，计划与决策）+ `runbook.md`（执行手册） |

## 1. 背景与目标

本项目把 container-ci 中 76+ 个上游项目的镜像构建流水线收敛为「声明式配置 + 统一工具」（config.yml + tools/build.py），目前已完成 10 个项目迁移（alpine、debian、erlang、golang、httpd、node、php、python、ruby、rust），并以 GitHub Actions 定时 workflow 驱动每日构建。

**最终形态**：全部已迁移项目每天定时构建（new version 检测 + 构建 + 推送 lcr.loongnix.cn）。

随之而来的痛点：每日多项目并行构建，任何一个 workflow 失败（上游版本变更、模板变量缺失、下载链接失效、基础镜像变动、Dockerfile 语法、self-hosted runner 环境问题等）都需要人工去 GitHub 页面查看、定位、修复。构建是每日重复劳动，排查却是每次不同的「烧脑活」，正适合 AI agent 承接。

**目标**：构建一套 AI 运维工具，**每天获取构建失败的 CI 流水线并进行修复**：

1. 获取构建失败的 CI 流水线（当前阶段：指定项目手动采集；终态：每日自动全仓）
2. 结合项目上下文（library/\<project\>/AGENTS.md）定位失败原因
3. 在约束范围内自动修复（模板、脚本、配置），本地验证后提交
4. 重跑失败的 workflow 直到绿色，或明确交接人工
5. 把每次修复沉淀为结构化记录（docs/ai-ops/ci-fix.md）+ 详细会话报告（log/ai-ops/），越修越快

**实施路径（增量）**：先走通一个项目（library/alpine）的 ai-ops 闭环，验证工具与手册的可用性；再推广到其他已迁移项目；最后接入每日定时巡检（Hermes cron）。三个阶段的边界见 §4。

## 2. 组件与关系

```
                         ┌─────────────────────────────────────────┐
                         │  GitHub Actions（self-hosted runner）    │
                         │  （终态）schedule 每天 UTC 16:00 /（试点期）手动 dispatch │
                         │  library-alpine.yml ... library-rust.yml │
                         │        └─ build.yml（可复用）              │
                         │           build.py <project> --push       │
                         └──────────────────┬──────────────────────┘
                                            │ 失败 run（有新版本时才会构建，才会失败）
                                            ▼
                          gh run list / gh api  ── 拉取失败 run + 日志
                                            │
                         ┌──────────────────▼──────────────────────┐
                         │  AI 运维 agent（Hermes）                    │
                         │  1 背景读取    library/<project>/AGENTS.md │
                         │  2 原因定位    失败日志 + 已知问题表匹配     │
                         │  3 修复       template/ config.yml 等      │
                         │  4 验证       build.py --test（loong64）    │
                         │  5 提交+重跑    push + 重新触发 workflow    │
                         │  6 知识回写    项目 AGENTS.md 维护记录       │
                         └─────────────────────────────────────────┘
```

| 组件 | 位置/形态 | 作用 |
|------|-----------|------|
| 项目 workflow | `.github/workflows/library-*.yml`（试点期仅 alpine 接通 schedule；终态每项目 1 个+每日定时） | 触发构建 |
| 构建 workflow | `.github/workflows/build.yml`（workflow_call 可复用） | checkout → build.py --push → 提交版本跟踪 |
| 统一入口 | `tools/build.py` | 获取版本 → update.sh → apply-templates.sh → buildx 构建；`--test` 本地验证不推送 |
| AI 运维工具 | `tools/ai-ops.py` | 确定性动作：fetch（采集失败 run+日志）/ rerun / dispatch / commit / branch（创建修复分支）/ commit-pr（提交修改并发起 PR：只 add 项目目录 → commit -F commit-msg → push → gh pr create）；autofix 组装上下文并调用 hermes 一次性会话完成分析→修复→验证，会话报告（错误原因+修复过程）自动落盘 `log/ai-ops/{date}-{project}.md`，结构化记录（一行表格）由脚本回写 `docs/ai-ops/ci-fix.md` |
| 项目上下文 | `library/<project>/AGENTS.md` | 上游映射、本地调整、已知问题、维护记录 —— AI 修复的决策依据（规范见 docs/07-agents-md.md） |
| 修复执行手册 | `docs/ai-ops/runbook.md` | Hermes agent / autofix 会话按此执行「采集→分析→修复→验证→直推→重跑→回写」闭环 |
| 迁移规范 | `docs/08-migration-experience.md` | 修复模板/脚本时必须遵循的规则（FROM 不加 registry、变体命名、forky 约束等） |
| 失败数据源 | GitHub API（`gh` CLI） | 拉取失败 run 列表与日志 |
| AI agent | Hermes（运行形态见 §5） | 分析-修复-验证循环的执行者 |

**重要语义**：现有定时 CI 是「检查新版本，有新版本才构建」（processed_versions.txt 去重）。失败 run 通常集中在「某项目发了新版本」的日子，不是每天都必然有失败。AI 运维工具按「当天有失败才干活」设计，而非无条件全量检查。

## 3. 需求拆解

| 编号 | 需求 | 验收标准 |
|------|------|----------|
| R1 | 获取失败流水线 | 能列出指定项目（试点期：library/alpine；终态：全仓 24h）在 branch main 的失败/取消 workflow run：项目、版本、失败 job/step |
| R2 | 失败日志与上下文聚合 | 每个失败 run 产出结构化摘要：日志尾部关键错误 + 对应项目 AGENTS.md 已知问题命中情况 + 失败分类 |
| R3 | 自动修复 | 在 §6 约束内修改（模板/脚本/配置），先用 `bash -n`、再用 `build.py --test` 在 loong64 环境真实验证 |
| R4 | 提交与重跑 | 修复经过验证后提交，重新触发失败 workflow，确认转绿并记录 |
| R5 | 知识沉淀 | 每次成功修复由脚本回写 `docs/ai-ops/ci-fix.md`（一行表格：日期/项目/run/问题/修复/状态），完整报告落盘 `log/ai-ops/`；后续 session 读 ci-fix.md 幂等命中、读 log 复用历史上下文 |
| R6 | 人工兜底 | 无法定位/连续失败/验证不过的，明确产出「交接报告」而非无限循环 |

## 4. 分阶段开发计划

### Phase 1 — 单项目试点：library/alpine 手动 ai-ops 闭环

**选型理由（alpine）**：

- 唯一已接入每日定时 CI（`.github/workflows/library-alpine.yml`，schedule `0 16 * * *`）：每天真实构建，有新版本即构建，失败 run 来自真实生产场景，最贴合「每天获取构建失败的 CI 流水线并修复」的目标
- 结构最简：单变体（Dockerfile-alpine.template，FROM scratch + ADD minirootfs），无编译、无平台特殊汇编、无复杂依赖，闭环链路最容易走通
- 项目 AGENTS.md 已存在（含上游信息、构建流程、已知问题：minirootfs 下载慢），为 AI 修复提供上下文
- 注意：alpine 无编译类失败，失败模式代表性有限；推广期第一个项目应选编译型（httpd/golang），补齐该模式验证（见 Phase 2）

**目标**：开发一套「手动可执行的 ai-ops 工具」，对单个项目完成 采集失败 → 分析 → 修复 → 验证 → 直推 → 重跑 → 回写 的完整闭环。不考虑定时任务。

**产出**：

1. **试点 CI 来源**：alpine 的 workflow 已接通 schedule + workflow_dispatch（version 输入），无需新增；既有失败 run 或手动 dispatch 均可作为闭环样本
2. **确定性动作脚本（tools/ai-ops.py）**：把不需要判断的操作固化为子命令：
   - `fetch`：输入项目目录（+可选时间窗/上限）→ 该项目在 branch main 的失败/取消 run 清单（`gh run list --workflow library-alpine.yml` + 时间窗过滤），拉日志落盘（`gh run view --log-failed`，不回退打印凭据）
   - `rerun`：重新触发指定失败 run（仅失败 jobs）
   - `dispatch`：手动触发项目 workflow（可指定 version）
   - `commit`：git add + commit（消息按约定格式）
   - `autofix`：一键闭环——组装上下文 → 调 `hermes chat -q` 一次性会话执行分析与修复决策 → 会话后核对提交结果
3. **修复执行手册**：`docs/ai-ops/runbook.md`——Hermes agent 按手册步骤执行分析与修复决策：读取项目 AGENTS.md → 失败分类 → 定位根因 → 修复（§6 约束）→ `bash -n` → `build.py --test library/alpine <version>` 验证 → 直推 → 重跑 → 回写 AGENTS.md 维护记录。手册内容源于 §3 R2-R6 与 §6。

**演练闭环**（真实失败样本不足或需加速验证时）：

1. 先让 alpine 处于必然失败的坏状态并确认可复现（如把 update.sh 的下载 URL 指向不存在的文件 / 模板引入语法错误 / 写死错误 checksum），dispatch 触发真实 CI 产生失败 run
2. 手动执行一次完整 ai-ops 闭环，工具应完成：采集到该失败 → agent 定位到根因 → 按 §6 修复 → `--test` 验证 → 直推 → 重跑转绿 → 回写维护记录
3. 闭环通过后，把演练用的坏状态改动还原；若还原与原修复冲突，以修复为准（演练的目的就是让修复行为发生）

**验收标准**：

- alpine 被置为坏状态后 dispatch 构建产生失败 run（演练闭环前置条件满足）
- 手动执行一次完整闭环：失败 run 转绿（重跑成功）、修复 commit 在 main、library/alpine/AGENTS.md 维护记录已更新
- 演练坏状态已还原（或已被修复吸收），alpine 恢复正常构建
- 第二次执行相同场景不再重复修复（幂等）

### Phase 2 — 推广到全部项目

- 用 alpine 验证过的采集工具 + 手册，对第二、第三个项目跑通闭环，沉淀通用性（第一个补编译型项目验证编译失败模式）
- 为其余项目生成 `library-*.yml`（复用 alpine workflow 模板；schedule 统一留到 Phase 3）
- 验证 build.yml 并发提交 processed_versions.txt 的冲突处理（已有 pull --rebase 重试）
- 各项目的「已知问题/特殊处理」（node unofficial-builds、php GAS、ruby rust/YJIT 等）随真实修复逐步沉淀
- 验收：同一套工具不修改代码前提下，对 3+ 项目跑通；新增项目只需补 workflow + 项目 AGENTS.md

### Phase 3 — 定时化（终态，暂不实施）

- Hermes cron（方案 A）包装 Phase 2 的工具，每日自动巡检：当日无失败 run 则空跑（幂等）
- 启用全部项目 workflow 的 schedule（UTC 16:00）
- 时点、通知渠道在此阶段定案（见 §7）
- 产出周/月失败归因报表（哪类问题最多、哪些项目最不稳定）

## 5. 运行形态（两阶段）

**当前（Phase 1-2，手动执行）**：没有定时任务。用户手动发起一次 Hermes 会话（或直接运行 `tools/ai-ops.py autofix`）。autofix 自动模式按 runbook 完成「采集 → 分析 → 修复 → 验证 → 回写维护记录」，**不提交不推送**，改动留工作区；人工审阅后执行提交、直推、重跑与转绿确认（边界见 §6）。逐步模式按手册全流程执行，可随时与用户确认。设计上保持幂等，同一失败 run 重复执行不会重复修复。

**终态（Phase 3，定时自动）**：Hermes 本地 cron（方案 A）包装同一套工具每日自动执行；agent 只读 GitHub，构建验证走 loong64 机器；当日无失败 run 时空跑结束。

备选（不采用）：B — GH Actions 内嵌 agent（runner 上跑 LLM 的资源与安全边界不明）；C — 失败通知 + 人工拉起会话（半自动，不符合「自动修复」目标）。

## 6. 修复边界与安全约束

- **先读后改**：动任何项目文件前必须读 `library/<project>/AGENTS.md` 与 docs/08 迁移规范
- **不改**：全局 config.yml 的 registry、上游同步策略、processed_versions.txt 的手工内容
- **只改根因相关文件**：项目 template/、config.yml、get_versions.sh；tools/build.py 仅当其自身有 bug。严禁 `git add -A` 卷入无关改动（仓库可能有其他未提交文件，只 add 本次相关文件）
- **验证前置**：未经 `build.py --test` 验证的修改不得提交；`.sh` 修改先 `bash -n`；完整 loong64 构建耗时长时，可只验证版本获取/模板渲染链路并在结果中如实说明
- **autofix 不提交（2026-09 确认）**：自动模式只做分析+修复+验证，不执行 git add/commit/push，修复改动与维护记录回写保留在工作区；提交由人工审阅后通过 commit 子命令（或手动 git）执行
- **提交策略（手动流程，已确认）**：验证通过后直推本 fork 的 main 分支（与现有 build.yml 提交方式一致），不走 PR；push 前先 `git pull --rebase`（autofix 自动模式不在此列，见上一条）
- **止损**：单个项目连续失败 N 次（建议 3，待定）转为交接人工，禁止无限重试
- **凭据**：gh 凭据、registry 凭据仅用于采集与触发，日志中不得打印

## 7. 待确认项清单

已确认：监控范围（仅本仓库）、提交流向（直推 fork main）、每日语义（有新版本才构建）、终态运行形态（方案 A Hermes cron）、实施策略（alpine 单项目闭环先行，暂不做定时任务）、工具形态（确定性动作脚本化 + Hermes agent 按 runbook 做分析修复决策）、试点项目（library/alpine）、试点失败来源（真实失败优先，演练兜底）。

Phase 1 已无阻塞项，可开工。

Phase 3 前再定（当前不阻塞）：执行时点、通知渠道、修复确认粒度（关键动作会话内简报 vs 全自动）。

次要（实施时再定）：连续失败止损阈值 N（建议 3）；Phase 2 的其余 workflow 是否一次性补齐；试点 alpine 推广后第一个编译型项目选 httpd 还是 golang。

**工具层面的后续完善点**（2026-09 已处理）：

- ✅ autofix prompt 引用路径已改为 `docs/ai-ops/runbook.md`
- ✅ autofix 提交边界：只分析+修复+验证，不提交不推送（`--push` 参数已移除）；`commit` 子命令（git add -A）保留，仅供人工审阅改动后的手动提交，与 §6「autofix 会话严禁 add -A」口径一致
- ✅ `.gitignore` 已加入 `.ai-ops/` 与 `*.swp`
- ✅ autofix 会话报告（错误原因+修复过程）自动落盘 `log/ai-ops/{date}-{project}.md`（不入库），脚本端在会话结束后写入，当日多次追加条目
- ✅ 结构化知识沉淀改为脚本回写 `docs/ai-ops/ci-fix.md`（入库、跨项目累计、同 run 幂等）；autofix 会话**不再写任何项目的 AGENTS.md**（2026-09 确认——一次性会话写受保护文件会审批超时被拒，确定性回写归脚本）
- ✅ `commit-pr` 子命令（2026-09-08 新增）：提交修改并发起 PR——只 `git add <project_dir>/`（不 add -A）→ `git commit -F log/ai-ops/{org}-{name}-{YYYYMMDD}-{run-id}-commit-msg.md` → `git push -u origin <当前分支>` → `gh pr create --base main`；`-n/--dry-run` 打印全部命令不执行；当前分支为 main 时拒绝执行；commit-msg 文件缺失时列出 log/ai-ops 候选文件并退出
- 待观察：autofix 改动留工作区后，下一次 fetch/autofix 前需人工审阅并提交，否则新旧改动会混淆——可考虑后续在 cmd_autofix 入口加「工作区不干净则中止」检查（待讨论）

## 8. 证据附录（现状事实，2026-09 采集）

- 已迁移项目（10）：alpine、debian、erlang、golang、httpd、node、php、python、ruby、rust
- workflow 文件：`.github/workflows/build.yml`（可复用构建+提交版本跟踪）、`.github/workflows/library-alpine.yml`（唯一定时接入，schedule `0 16 * * *`，含 workflow_dispatch + version 输入）
- 定时语义：library-alpine.yml 注释「每天北京时间 00:00（UTC 16:00）检查新版本」；build.py 有 processed_versions.txt 去重（`is_already_built`）
- 构建流程：build.py 内部顺序为 update.sh → apply-templates.sh → buildx 构建各 variant →（--push 时）tag+push
- alpine 项目：单变体，Dockerfile-alpine.template（FROM scratch + ADD rootfs.tar.gz），get_versions.sh 从 cz.alpinelinux.org 获取最新版本，已知问题为 minirootfs 下载慢
- 近期相关提交：
  - `8f27755` feat(ci): 添加 GitHub Actions workflow 和 --push 参数
  - `1d8b673` docs: 更新架构文档变体命名和配置说明
  - `79ca4ad` fix(debian): apply-templates.sh jq 字符串缺少闭合引号（模板脚本 bug 的真实案例）
- migration-status.md 被 .gitignore 忽略（标注「迁移进度跟踪（个人使用）」），仓库内不存在