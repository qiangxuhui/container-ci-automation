# tools/ai-ops.py 重构方案（目标：tools/ai-ops-1.py）

> 日期：2026-09-08（v2：方案定案——JSON 状态文件设计，fetch 先行实现中；v3：2026-09-10 branch 落地；v4：2026-09-10 commit-msg 落地）
> 状态：**方案已定案，fetch/autofix/branch/commit-msg 已在 tools/ai-ops-1.py 落地**；其余子命令待后续迭代
> 本文件是后续 agent 打开项目时了解该重构的**前置信息入口**：现状、动机、目标形态、兼容性清单、待确认项。

## 0. 前置信息（已确认事实）

- **重构源**：`tools/ai-ops.py`（511 行 / 23837 字节），已被 git 跟踪，功能正常使用中；**重构期间勿再直接改它**
- **目标文件**：`tools/ai-ops-1.py`（2026-09-08 创建，已写入 fetch 实现，其余子命令未实现）
- **原则**：不在原文件上直接重构；新文件单独演进；CLI 兼容（子命令名/参数/退出码语义不变）
- **已定案设计**（2026-09-08 用户确认）：**状态文件 `.aiops-fix-info.json`**（仓库根、gitignore）：fetch 采集后写入本次修复上下文；后续操作（rerun/dispatch/branch/commit/commit-pr/autofix）一律从该文件读取信息，不再靠位置参数；每个操作支持 `--dry-run/-n` 输出全部将执行的 shell 命令
- **已迭代范围**：fetch（2026-09-08）、autofix（2026-09-09）、branch（2026-09-10）、commit-msg（2026-09-10）已移植；其余命令逻辑不变、留待后续迭代

## 1. 现状结构（原 tools/ai-ops.py）

单文件 511 行，职责分层（行号以 2026-09-08 版为准）：

| 层 | 内容 | 行号 |
|----|------|------|
| 模块常量 | FAIL_CONCLUSIONS、REPO_ROOT、LOG_DIR、CI_FIX_FILE、CI_FIX_FALLBACK | 47-52 |
| 通用辅助 | `log`（stderr 打印）、`run`（subprocess 封装，失败即 sys.exit(1)）、`project_info`（library/x → (org, name)） | 55-72 |
| GitHub 采集 | `collect_failed_runs`：gh run list 查询失败/取消 run → gh run view 拉日志落盘 `.ai-ops/fetch/{name}/{run_id}.log`，返回 entry 列表 | 75-129 |
| autofix 上下文 | `build_autofix_prompt`：拼 hermes chat -q 的一次性会话 prompt（多行 f-string） | 132-156 |
| 落盘/沉淀 | `write_autofix_log`（→ log/ai-ops/{date}-{project}.md，不入库）、`write_ci_fix`（→ docs/ai-ops/ci-fix.md，入库、按 run id 幂等）、`extract_session_id`（-Q 模式 stderr 首行） | 159-251 |
| 命令函数 | cmd_fetch / cmd_rerun / cmd_dispatch / cmd_branch / cmd_commit / cmd_commit_pr / cmd_autofix；每个返回退出码 int | 254-450 |
| 入口 | `main`：argparse subparsers，`set_defaults(fn=...)` 分发 | 453-511 |

子命令一览（7 个）：`fetch`、`rerun`、`dispatch`、`commit`、`branch`、`commit-pr`、`autofix`。

## 2. 问题点（重构动机，原文件）

1. 单文件混合三类职责：确定性动作、autofix 编排、GitHub/git 交互细节
2. cmd_autofix 过长（约 67 行）：采集 → 选 entry → 拼 prompt → hermes 子进程 → 超时兜底 → 落盘 → 回写 → HEAD 比对
3. 错误处理不统一：`run()` 失败即 sys.exit(1) 无法降级；gh log-failed 回退又是手写 subprocess
4. 零可测试性：gh/git/hermes 直接 subprocess，无注入点
5. 上下文靠命令行位置参数反复传（project_dir、run_id、commit-msg 日期通配查找），命令间无共享状态
6. 新增子命令要改 parser + cmd 函数 + 文档索引三处

## 3. 重构目标与不变量

- **CLI 完全兼容**：7 个子命令名称、位置参数、选项名称与默认值、退出码语义（0 成功 / 1 失败）不变；runbook.md / AGENTS.md 中引用的命令不受影响
- **零新依赖**：纯 Python 标准库（argparse/json/shlex/subprocess/datetime/pathlib/re）
- **状态单点**：fetch 产出 `.aiops-fix-info.json`，后续命令只认该文件（不再靠位置参数拼 commit-msg 文件名等）
- **dry-run 全覆盖**：每个子命令 `--dry-run/-n` 打印全部将执行的 shell 命令，不执行、不写文件
- **职责分层清晰**：常量 → 工具函数 → 数据采集/落盘 → 命令函数 → main；单函数可控（cmd_autofix 后续拆分）
- **注释里的坑全量移植**：§5 兼容性清单

## 4. 方案定案（2026-09-08 用户确认）

### 4.1 状态文件 `.aiops-fix-info.json`（仓库根，.gitignore 已追加）

一次 fetch 会话的修复上下文，后续命令全部从它读：

```json
{
  "org": "library",
  "project": "alpine",
  "runid": "34050474275",
  "url": "https://github.com/<owner>/<repo>/actions/runs/34050474275",
  "date": "20260908",
  "branch": "fix-library-alpine-20260908-34050474275",
  "process-error-file": "library-alpine-20260908-34050474275-process-error.md",
  "commit-msg-file": "library-alpine-20260908-34050474275-commit-msg.md",
  "versions": ["3.21.3"]
}
```

- org/project：由 project_dir（library/alpine）拆分（org 不带斜杠，供 branch 名拼接）
- runid：选中的失败 run（默认最新失败，`--run-id` 可指定；指定值不在失败列表时列出候选并 exit 1）
- url：失败 run 的 GitHub Actions 页面链接（gh run list 的 url 字段；后续 autofix 拼 prompt 用）
- date：fetch 执行当天日期 YYYYMMDD（本地时区 datetime.now()，不随 run 创建时间；commit-msg/process-error 文件名与 branch 的日期段即此日期）
- branch：`fix-{org}-{project}-{date}-{runid}`（后续 branch 子命令使用，仅本地/推送用）
- process-error-file / commit-msg-file：文件名（使用时拼 LOG_DIR=log/ai-ops/）；autofix 提示词要求 agent 把报错原因+修复方法写入 process-error-file 对应文件，commit-msg-file 对应 commit message
- versions：本次修复涉及的版本号（从 run 标题提取 x.y.z，提取不到为 []）
- 追加字段（如需）：由后续迭代决定，保持本结构即可

### 4.2 fetch（当前唯一实现）

流程：gh run list 查询（过滤 FAIL_CONCLUSIONS + 时间窗）→ 选中 run → gh run view --log-failed（失败回退 --log）落盘 `.ai-ops/fetch/{name}/{runid}.log` → 写 `.aiops-fix-info.json` → stdout 输出 json 内容。

- 无失败 run：不更新 json（保持上次状态）、提示幂等退出 0
- `--dry-run/-n`：打印 gh run list / gh run view 两条命令（run view 的 run-id 未指定时为 `<run-id>` 占位）及将写入的文件说明；不执行任何命令、不写文件
- 参数：`fetch <project_dir> [--since-hours N] [--limit N] [--run-id ID] [--out DIR] [--dry-run/-n]`

### 4.3 后续命令（已落地：branch 2026-09-10、commit-msg 2026-09-10；剩余 rerun/dispatch/commit/commit-pr 待迭代）

- 已落地的 branch：从 `.aiops-fix-info.json` 读 `branch` 字段（fetch 写入时按
  `fix-{org}-{project}-{date}-{runid}` 生成），`git checkout -b <branch>` 仅本地不推送；支持 `--dry-run/-n`；
  状态文件缺失时 load_fix_info 提示先 fetch 并 exit 1（与 autofix 一致）
- 已落地的 commit-msg（重构版新增子命令，原文件该子命令已于 e0de8ee 删除）：从
  `.aiops-fix-info.json` 读 org/project/process-error-file/commit-msg-file；输入 =
  `log/ai-ops/{process-error-file}`（autofix 会话中 agent 写入的报错原因+修复方法），
  调 hermes 一次性会话总结为 commit message（标题形如 `fix library/alpine: ...`），
  落盘 `log/ai-ops/{commit-msg-file}`；process-error 文件缺失时列出 log/ai-ops 候选并
  exit 1；`--max-turns`(60)/`--timeout`(600)/`--dry-run/-n`；hermes 超时 exit 1、
  非零退出仍落盘、无输出不落盘 return 1、已存在覆盖
- 剩余命令（rerun/dispatch/commit/commit-pr）均改为：**从 `.aiops-fix-info.json` 读 org/project/runid/date/文件路径**，不再接收 project_dir/run_id 位置参数（autofix 的 --version 改为可选且允许为空：缺省取状态文件 versions 首个版本，versions 为空则默认空字符串）
- 全部支持 `--dry-run/-n`
- 读取时文件缺失 → 明确报错提示先执行 fetch

## 5. 移植时必须保留的行为清单（兼容性细节）

- **fetch**：FAIL_CONCLUSIONS={failure, cancelled, timed_out, startup_failure}；时间窗过滤比较 createdAt（UTC ISO）；`gh run list --workflow library-{name}.yml --branch main --status completed`；`gh run view --log-failed` 失败回退 `--log`；日志落盘父目录自动创建；提示走 stderr、数据走 stdout
- **autofix**（原逻辑，迭代时保留）：--version 可选且允许为空（缺省取状态文件 versions 首个版本；versions 为空则默认空字符串；不做自动探测）；--run-id 不在失败列表时列出候选并 exit 1；默认取最新失败；hermes 命令形如 `hermes chat -q <prompt> -Q --in <REPO_ROOT> --yolo --max-turns N`；超时 TimeoutExpired → rc=124 落盘并 exit 1；会话后 HEAD 比对，有新提交则告警；--dry-run 仍先采集 run 再只打印命令
- **commit-pr**（原逻辑，迭代时保留）：commit-msg 文件按 `{org}-{name}-*-{runid}-commit-msg.md` 通配日期、取最新，无命中列出 log/ai-ops 候选并 exit 1；当前分支为 main/master 拒绝；仅 `git add {project_dir}/`；dry-run 打印全部命令不执行
- **branch**（✅ 已移植 2026-09-10）：分支名改为 `fix-{org}-{project}-{date}-{runid}`（随状态文件）；dry-run 仅打印
- **dispatch**：version 通过 `-f version=` 传入；留空为自动检测；workflow 文件名 `library-{name}.yml`
- **commit**：无改动时提示并返回 0；`git add -A`（仅人工手动提交路径使用）
- **write_ci_fix 幂等**：ci-fix.md 已含 `| {runid} |` 时跳过；报告里 CI-FIX-ROOTCAUSE/CI-FIX-FIX 标记提取，缺失回退占位文案
- **write_autofix_log 追加语义**：当日多次执行按 `## HH:MM — run #id` 追加分段；文件不存在/空时先写标题与提示头

## 6. 验证方式（迭代落地时执行；不跑正式测试）

- 语法：`python3 -m py_compile tools/ai-ops-1.py`
- CLI 结构对照：`python3 tools/ai-ops-1.py --help` 与各子命令 --help，与原文件逐项对照
- 行为对照：dry-run 场景输出一致（fetch/autofix/commit-pr --dry-run）
- 真实闭环验证：由用户决定是否跑（构建验证耗时长，如实说明验证范围）

## 7. 待确认项清单

已定案（✅）：
- ✅ 状态文件设计（§4.1 JSON 结构）与存放位置（仓库根 .aiops-fix-info.json，.gitignore）
- ✅ fetch 先行，后续命令从状态文件读取
- ✅ 每个操作支持 `--dry-run/-n` 输出 shell 命令
- ✅ 原文件不动，新文件 tools/ai-ops-1.py 独立演进

待确认：
1. 后续命令迭代顺序与批次（rerun/dispatch/branch/commit/commit-pr/autofix 一次一个还是按组）
2. 交接方式：ai-ops-1.py 全部子命令验证通过后——替换 tools/ai-ops.py（改名/调用方文案更新）、还是并存观察、还是手动指定？需要用户定
3. `ai-ops-1.py` 的 `-1` 后缀是临时占位还是最终名（最终名如 ai-ops.py 何时改）
4. remote/CI 相关：.aiops-fix-info.json 若需跨机器使用（终态 cron 在构建机 vs 本机），是否要支持 --out/路径可配（当前固定仓库根）
5. 文档回写：重构落地后，本文件、README.md、AGENTS.md 中相关"当前进度/工具形态"描述需同步更新

## 8. 证据附录（现状事实，2026-09-08 采集）

- 原文件：511 行 / 23837 字节；仓库当前 main 分支 HEAD a939f0a
- 主要函数行数与行号区间（原文件实测）：
  - `main` 54 行（453-507）；`cmd_autofix` 67 行（384-450）；`collect_failed_runs` 55 行（75-129）；`cmd_commit_pr` 52 行（330-381）；`write_autofix_log` 41 行（159-199）；`write_ci_fix` 39 行（202-240）；`build_autofix_prompt` 25 行（132-156）；`find_commit_msg_file` 15 行（313-327）
- 调用关系：cmd_fetch/cmd_autofix 共用 collect_failed_runs；cmd_autofix 独占 build_autofix_prompt/write_autofix_log/write_ci_fix/extract_session_id；cmd_commit_pr 独占 find_commit_msg_file
- 重构版 tools/ai-ops-1.py 当前实现（2026-09-10）：常量（FAIL_CONCLUSIONS、REPO_ROOT、LOG_DIR、FIX_INFO_FILE）+ log/run/project_info/build_fix_info/extract_versions_from_title/collect_failed_runs/fetch_run_log/write_fix_info/load_fix_info/entry_from_fix_info/build_autofix_prompt/write_autofix_log/extract_session_id/build_commit_msg_prompt + cmd_fetch / cmd_branch / cmd_autofix / cmd_commit_msg + main（注册 fetch/branch/autofix/commit-msg）；date 字段取 fetch 执行当天（datetime.now()，本地时区）；branch 分支名 = 状态文件 branch 字段（fix-{org}-{project}-{date}-{runid}）；commit-msg 输入/输出 = 状态文件 process-error-file / commit-msg-file（拼 log/ai-ops/）
- 文档挂接点：AGENTS.md 当前进度行与文档索引表、docs/ai-ops/README.md 文档位置行均已有本文件入口