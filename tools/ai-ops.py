#!/usr/bin/env python3
"""tools/ai-ops.py — AI 运维工具

子命令：
  fetch    <project_dir> [--since-hours N] [--limit N] [--out DIR]
                                    采集目标项目失败/取消的 workflow run，并拉取失败日志落盘
  rerun    <run-id>                 重跑指定 run（仅失败 jobs）
  dispatch <project_dir> [version]  手动触发项目 workflow（workflow_dispatch）
  commit   -m <msg>                 git add -A + commit（不 push）
  branch   <project_dir> <jobid> [--dry-run]
                                   基于当前 HEAD 创建并切换到修复分支
                                   {project_dir}-{YYYYMMDD}-{jobid}（仅本地，不推送）；
                                   --dry-run：打印将执行的 git 命令但不执行
  commit-pr <project_dir> <run-id> [--dry-run]
                                   提交修改并创建 PR：git add {project_dir}/（仅项目目录，
                                   不用 add -A）→ git commit -F
                                   log/ai-ops/{org}-{name}-{YYYYMMDD}-{run-id}-commit-msg.md
                                   → git push -u origin <当前分支> → gh pr create
                                   （base=main，标题/正文取自 commit-msg 文件）；
                                   --dry-run：打印全部将执行的命令但不执行
  autofix  <project_dir> [--run-id ID] [--version V] [--max-turns N] [--timeout S] [--dry-run]
                                   脚本化闭环：调 `hermes chat -q` 分析失败日志 →
                                   修复 → 验证（不提交、不推送；改动留工作区，
                                   由人工审阅后提交并重跑），会话后核对工作区状态；
                                   会话报告（错误原因+修复过程）自动落盘
                                   log/ai-ops/{date}-{project}.md，结构化记录回写
                                   docs/ai-ops/ci-fix.md；
                                   --version V：验证用版本号（必填，如 3.24.1）；
                                   --dry-run：打印将执行的 hermes 命令但不执行
                                   （仍先采集失败 run 解析 run id 与日志路径）

原则：fetch/rerun/dispatch/branch/commit/commit-pr 只做确定性动作（无需判断）；
autofix 把「分析 + 修复决策」委托给 Hermes agent 的一次性会话执行，
脚本负责组装上下文、调用、核对结果、落盘会话记录。autofix 边界
（2026-09 确认）：只做错误分析 + 代码修复 + 验证，不提交不推送，
提交时机由人工决定。
"""

import argparse
import json
import shlex
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

FAIL_CONCLUSIONS = {"failure", "cancelled", "timed_out", "startup_failure"}

REPO_ROOT = Path(__file__).resolve().parent.parent
LOG_DIR = REPO_ROOT / "log" / "ai-ops"
CI_FIX_FILE = REPO_ROOT / "docs" / "ai-ops" / "ci-fix.md"
CI_FIX_FALLBACK = "（无 CI-FIX 标记，详见 log/ai-ops/ 会话报告）"


def log(msg):
    print(f"[ai-ops] {msg}", file=sys.stderr)


def run(cmd, **kw):
    """执行命令，失败时打印 stderr 并退出"""
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        log(f"命令失败 (exit {r.returncode}): {' '.join(cmd)}")
        log(r.stderr.strip())
        sys.exit(1)
    return r.stdout.strip()


def project_info(project_dir):
    """library/httpd -> ('library', 'httpd')"""
    p = Path(project_dir)
    return p.parts[-2], p.parts[-1]


def collect_failed_runs(project_dir, since_hours, limit, out):
    """查询项目失败/取消 run 并拉日志落盘。

    返回 [{run_id, conclusion, title, created_at, event, url, log_path}, ...]，
    按创建时间升序。无失败 run 时返回空列表。
    注意：gh run list --workflow 过滤基于 GitHub 索引，新完成的 run
    可能需短暂同步后才可见（演练实测现象）。
    """
    _, name = project_info(project_dir)
    workflow_file = f"library-{name}.yml"
    since = datetime.now(timezone.utc) - timedelta(hours=since_hours)
    since_iso = since.strftime("%Y-%m-%dT%H:%M:%SZ")

    data = run([
        "gh", "run", "list",
        "--workflow", workflow_file,
        "--branch", "main",
        "--status", "completed",
        "--limit", str(limit),
        "--json", "databaseId,workflowName,conclusion,createdAt,displayTitle,headBranch,url,event",
    ])
    runs = json.loads(data)

    failed = [r for r in runs
              if r.get("conclusion") in FAIL_CONCLUSIONS
              and r.get("createdAt", "") >= since_iso]
    failed.sort(key=lambda r: r.get("createdAt", ""))
    if not failed:
        return []

    out_dir = Path(out)
    fetch_dir = out_dir / "fetch" / name
    fetch_dir.mkdir(parents=True, exist_ok=True)

    summary = []
    for r in failed:
        run_id = r["databaseId"]
        log_path = fetch_dir / f"{run_id}.log"
        r2 = subprocess.run(["gh", "run", "view", str(run_id), "--log-failed"],
                            capture_output=True, text=True)
        if r2.returncode != 0:
            r2 = subprocess.run(["gh", "run", "view", str(run_id), "--log"],
                                capture_output=True, text=True)
        log_path.write_text(r2.stdout or r2.stderr)
        entry = {
            "run_id": run_id,
            "conclusion": r["conclusion"],
            "title": r.get("displayTitle", ""),
            "created_at": r.get("createdAt", ""),
            "event": r.get("event", ""),
            "url": r.get("url", ""),
            "log_path": str(log_path),
        }
        summary.append(entry)
    return summary


def build_autofix_prompt(project, url, version):
    """构造传给 hermes chat -q 的自包含任务 prompt（一次性会话无记忆）。

    成功标志 = `python3 tools/build.py --test {project} {version}` 通过；修复成功后
    由 agent 自己在 log/ai-ops/{org}-{name}-{yyyymmdd}.md 记录报错原因与修复方法。
    version 为必填参数：由 autofix 调用方 --version 强制传入（不做自动探测）。
    autofix 边界（2026-09 确认）：只做失败分析 + 代码修复 + 验证，不提交、不推送；
    改动保留在工作区，由人工审阅后提交并重跑。
    """
    org, name = project_info(project)
    today = datetime.now().strftime("%Y%m%d")
    return f"""你是 container-ci-automation 仓库的 AI 运维 agent，执行一次「失败分析 → 代码修复 → 验证」闭环任务。

工作目录即仓库根。任务上下文：

- 项目目录：{project}
- 失败 CI 地址：{url}
- 你目前的位置已经位于 container-ci-automation 项目根目录中
- 问题解决成功的标志是: python3 tools/build.py --test {project} {version} 可以执行通过
- {project}/AGENTS.md 中有一些关于 {project} 项目的信息你可以参考

执行要求:
    1. 只能修改 {project}/ 目录下的相关文件
    2. 不执行 git add / git commit / git push
    3. 在修复成功后，需要再 log/ai-ops/{org}-{name}-{today}.md 中记录此次报错的原因和修复方法"""


def write_autofix_log(project_dir, entry, report, rc=0, session_id=None):
    """把一次 autofix 会话记录（错误原因 + 修复过程）追加到 log/ai-ops/{date}-{project}.md。

    - {date} 为执行日（本地时区 YYYY-MM-DD），{project} 为项目名（如 alpine）
    - 当日多次执行同一项目时按条目追加（## 时间戳 — run #id 分段）
    - 文件不入库（.gitignore 的 log/ai-ops/），本地可追溯；
      结构化知识沉淀仍走项目 AGENTS.md「维护记录」表（入库）
    """
    org, name = project_info(project_dir)
    today = datetime.now().strftime("%Y-%m-%d")
    ts = datetime.now().strftime("%H:%M")
    log_file = LOG_DIR / f"{today}-{name}.md"
    log_file.parent.mkdir(parents=True, exist_ok=True)

    report = (report or "").strip() or f"（hermes 无输出，退出码 {rc}）"
    body = "\n".join([
        f"## {ts} — run #{entry['run_id']}（{entry['conclusion']}）",
        "",
        f"- 项目: {org}/{name}",
        f"- 失败日志: `{entry['log_path']}`",
        f"- 创建时间: {entry['created_at']} | 触发: {entry['event']}",
        f"- 链接: {entry['url']}",
        f"- hermes 退出码: {rc}",
        *( [f"- 会话: `hermes chat --resume {session_id}`"] if session_id else [] ),
        "",
        "### 错误原因与修复过程（autofix 会话报告）",
        "",
        report,
        "",
        "---",
        "",
    ]) + "\n"

    first = not log_file.exists() or log_file.stat().st_size == 0
    with open(log_file, "a", encoding="utf-8") as f:
        if first:
            f.write(f"# {today} {name} — AI 运维会话记录\n\n")
            f.write("> autofix 自动落盘：错误原因与修复过程。文件不入库（log/ai-ops/ 在 "
                    ".gitignore），本地可追溯；知识沉淀以项目 AGENTS.md「维护记录」表为准。\n\n---\n\n")
        f.write(body)
    return log_file


def write_ci_fix(project_dir, entry, report):
    """把一次 autofix 修复提炼为一行结构化记录，追加到 docs/ai-ops/ci-fix.md（入库）。

    从会话报告提取 CI-FIX-ROOTCAUSE / CI-FIX-FIX 两行标记（一句话根因 / 一句话修复）；
    提取失败则回退占位并指向 log/ai-ops/ 会话报告。幂等：文件已含该 run id 时跳过。
    结构化知识沉淀统一走本文件（2026-09 确认），不再写项目 AGENTS.md。
    """
    org, name = project_info(project_dir)
    today = datetime.now().strftime("%Y-%m-%d")
    run_id = entry["run_id"]

    if CI_FIX_FILE.exists():
        if f"| {run_id} |" in CI_FIX_FILE.read_text(encoding="utf-8"):
            log(f"ci-fix 已存在 run #{run_id} 的记录，跳过回写（幂等）")
            return None

    rootcause = fix = CI_FIX_FALLBACK
    for ln in (report or "").splitlines():
        if ln.startswith("CI-FIX-ROOTCAUSE:"):
            rootcause = ln.split(":", 1)[1].strip()
        elif ln.startswith("CI-FIX-FIX:"):
            fix = ln.split(":", 1)[1].strip()

    def esc(s):
        return s.replace("|", "\\|").strip()

    row = f"| {today} | {org}/{name} | {run_id} | {esc(rootcause)} | {esc(fix)} | 待提交 |"
    first = not CI_FIX_FILE.exists()
    if first:
        CI_FIX_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(CI_FIX_FILE, "a", encoding="utf-8") as f:
        if first:
            f.write("# CI 修复记录（ai-ops 结构化知识沉淀）\n\n")
            f.write("> autofix 脚本自动回写（tools/ai-ops.py），每行 = 一次修复闭环，同一 run 只记一次。\n")
            f.write("> 完整会话报告（错误原因+修复过程）见仓库根 `log/ai-ops/{date}-{project}.md`（不入库）。\n\n")
            f.write("| 日期 | 项目 | run | 问题 | 修复 | 状态 |\n")
            f.write("|------|------|-----|------|------|------|\n")
        f.write(row + "\n")
    return CI_FIX_FILE


def extract_session_id(stderr):
    """从 hermes chat -Q 的 stderr 提取 session_id（无则 None）。

    -Q 模式下 stderr 首行为 `session_id: <id>`（实测格式）。
    """
    for ln in (stderr or "").splitlines():
        if ln.startswith("session_id:"):
            return ln.split("session_id:", 1)[1].strip()
    return None


def cmd_fetch(args):
    org, name = project_info(args.project_dir)
    entries = collect_failed_runs(args.project_dir, args.since_hours, args.limit, args.out)
    log(f"项目 {org}/{name}：失败/取消 {len(entries)}（窗口 {args.since_hours}h）")
    if not entries:
        log("无失败 run，空跑结束（幂等）")
        return 0
    for e in entries:
        log(f"  #{e['run_id']}  {e['conclusion']}  {e['title']}  {e['created_at']}  log={e['log_path']}")
    print(json.dumps(entries, ensure_ascii=False, indent=2))
    return 0


def cmd_rerun(args):
    out = run(["gh", "run", "rerun", args.run_id, "--failed"])
    log(f"已重跑 #{args.run_id}（仅失败 jobs）")
    log(out)
    return 0


def cmd_dispatch(args):
    _, name = project_info(args.project_dir)
    workflow_file = f"library-{name}.yml"
    cmdv = ["gh", "workflow", "run", workflow_file, "--ref", "main"]
    if args.version:
        cmdv += ["-f", f"version={args.version}"]
    out = run(cmdv)
    log(f"已触发 {workflow_file}（version={args.version or '自动检测'}）")
    log(out)
    return 0


def cmd_branch(args):
    """基于当前 HEAD 创建并切换修复分支 {project_dir}-{YYYYMMDD}-{jobid}（仅本地，不推送）。"""
    date = datetime.now().strftime("%Y%m%d")
    branch = f"{args.project_dir}-{date}-{args.jobid}"
    cmdv = ["git", "checkout", "-b", branch]
    if args.dry_run:
        # 仅打印实际将执行的 git 命令，不执行（与 autofix --dry-run 语义一致）
        print(shlex.join(cmdv))
        log(f"dry-run：仅打印上述命令，未执行（分支 {branch}）")
        return 0
    run(cmdv)
    log(f"已创建并切换到分支 {branch}")
    return 0


def cmd_commit(args):
    stat = subprocess.run(["git", "status", "--porcelain"], capture_output=True, text=True)
    if not stat.stdout.strip():
        log("无改动可提交")
        return 0
    run(["git", "add", "-A"])
    run(["git", "commit", "-m", args.message])
    h = run(["git", "rev-parse", "--short", "HEAD"])
    log(f"已提交 {h}: {args.message}（未 push，push 由 runbook 流程执行）")
    return 0


def find_commit_msg_file(org, name, run_id):
    """定位 commit-msg 文件 log/ai-ops/{org}-{name}-{YYYYMMDD}-{run_id}-commit-msg.md。

    日期段用通配符匹配（commit-msg 的 YYYYMMDD 是 run 的日期，不一定等于今天），
    多命中取最新；无命中时列出 log/ai-ops 候选文件并 exit 1。
    """
    pattern = f"{org}-{name}-*-{run_id}-commit-msg.md"
    candidates = sorted(LOG_DIR.glob(pattern),
                        key=lambda p: p.stat().st_mtime, reverse=True)
    if not candidates:
        log(f"未找到 commit-msg 文件（搜索模式 log/ai-ops/{pattern}），log/ai-ops 候选：")
        for p in sorted(LOG_DIR.glob(f"{org}-{name}-*.md")):
            log(f"  {p.name}")
        sys.exit(1)
    return candidates[0]


def cmd_commit_pr(args):
    """提交修改并发起 PR。

    流程（--dry-run/-n 打印全部命令但均不执行）：
      1. 定位 log/ai-ops/{org}-{name}-{YYYYMMDD}-{run_id}-commit-msg.md
      2. git add {project_dir}/（只加项目目录，不用 git add -A，不卷入无关改动）
      3. git commit -F <commit-msg 文件>（首行为标题，其余为正文）
      4. git push -u origin <当前分支>
      5. gh pr create --base main --head <当前分支>（标题/正文取自 commit-msg 文件；
         PR 验证由 .github/workflows/library-alpine-pr.yml 负责：仅构建，不推送）
    安全约束：当前分支为 main/master 时拒绝执行（PR 应从修复分支发起）。
    """
    org, name = project_info(args.project_dir)
    msg_file = find_commit_msg_file(org, name, args.run_id)
    lines = msg_file.read_text(encoding="utf-8").splitlines()
    title = lines[0].strip() if lines else f"fix {org}/{name}"
    body = "\n".join(lines[2:]).strip()

    branch = run(["git", "branch", "--show-current"])
    if branch in ("main", "master"):
        log(f"当前分支是 {branch}，拒绝执行：应从修复分支（branch 子命令创建的 "
            f"{args.project_dir}-{{YYYYMMDD}}-{{jobid}}）发起 PR")
        sys.exit(1)

    cmdv = [
        ["git", "add", f"{args.project_dir}/"],
        ["git", "commit", "-F", str(msg_file)],
        ["git", "push", "-u", "origin", branch],
        ["gh", "pr", "create", "--base", "main", "--head", branch,
         "--title", title, "--body", body],
    ]
    if args.dry_run:
        for c in cmdv:
            print(shlex.join(c))
        log(f"dry-run：仅打印上述命令，未执行（commit-msg={msg_file}，分支 {branch}）")
        return 0

    stat = subprocess.run(["git", "status", "--porcelain", "--", f"{args.project_dir}/"],
                          capture_output=True, text=True)
    if not stat.stdout.strip():
        log(f"{args.project_dir}/ 无改动可提交")
        return 0

    run(cmdv[0])
    run(cmdv[1])
    h = run(["git", "rev-parse", "--short", "HEAD"])
    log(f"已提交 {h}（仅 {args.project_dir}/，消息来自 {msg_file.name}）")
    run(cmdv[2])
    log(f"已推送分支 {branch}（origin）")
    out = run(cmdv[3])
    log(out or f"已发起 PR: {branch} → main")
    return 0


def cmd_autofix(args):
    org, name = project_info(args.project_dir)
    entries = collect_failed_runs(args.project_dir, args.since_hours, args.limit, args.out)
    if not entries:
        log(f"项目 {org}/{name}：无失败 run（窗口 {args.since_hours}h），无事可修")
        return 0

    if args.run_id:
        entry = next((e for e in entries if e["run_id"] == args.run_id), None)
        if entry is None:
            log(f"run {args.run_id} 不在失败列表中（窗口 {args.since_hours}h 共 {len(entries)} 个），可扩大 --since-hours：")
            for e in entries:
                log(f"  #{e['run_id']}  {e['conclusion']}  {e['created_at']}")
            sys.exit(1)
    else:
        entry = entries[-1]  # 最新失败
    run_id, log_path = entry["run_id"], entry["log_path"]
    log(f"开始 autofix：{org}/{name} run #{run_id}  log={log_path}")

    log(f"验证版本：{args.version}（--version 强制传入）")
    prompt = build_autofix_prompt(args.project_dir, entry["url"], args.version)
    head_before = run(["git", "rev-parse", "--short", "HEAD"])

    cmdv = ["hermes", "chat", "-q", prompt, "-Q",
            "--in", str(REPO_ROOT), "--yolo",
            "--max-turns", str(args.max_turns),
            "-t", "file,terminal"]
    if args.dry_run:
        # 打印实际将执行的 hermes 命令（含完整 prompt），不执行。
        # 注意：仍已先采集失败 run（gh）并落盘日志，以解析 run id/日志路径。
        print(shlex.join(cmdv))
        log(f"dry-run：仅打印上述 hermes 命令，未执行（run #{run_id}，log={log_path}）")
        return 0
    log("调用 hermes chat -q（一次性会话，典型耗时 1-10 分钟）...")
    try:
        r = subprocess.run(cmdv, capture_output=True, text=True, timeout=args.timeout)
    except subprocess.TimeoutExpired:
        log(f"hermes 会话超时（>{args.timeout}s）。可调大 --timeout 重试，或手动跑 fetch+修复。")
        log_file = write_autofix_log(args.project_dir, entry, "", rc=124,
                                     session_id="超时，无会话 id")
        log(f"超时已记录到 {log_file}")
        write_ci_fix(args.project_dir, entry, "CI-FIX-ROOTCAUSE: 会话超时\nCI-FIX-FIX: 见 log/ai-ops/ 记录，需人工介入")
        sys.exit(1)
    print(r.stdout)
    if r.returncode != 0:
        log(f"hermes 退出码 {r.returncode}")
        if r.stderr.strip():
            log("stderr 片段: " + r.stderr.strip()[:1000])

    # 落盘会话记录（错误原因 + 修复过程）→ log/ai-ops/{date}-{project}.md
    sid = extract_session_id(r.stderr)
    log_file = write_autofix_log(args.project_dir, entry, r.stdout, rc=r.returncode, session_id=sid)
    log(f"autofix 会话已记录到 {log_file}")

    # 结构化知识沉淀 → docs/ai-ops/ci-fix.md（不写项目 AGENTS.md）
    ci_file = write_ci_fix(args.project_dir, entry, r.stdout)
    if ci_file:
        log(f"结构化记录已回写 {ci_file}")

    head_after = run(["git", "rev-parse", "--short", "HEAD"])
    if head_after != head_before:
        log(f"警告：检测到新提交（autofix 设计为不提交）：{head_before} -> {head_after}，请人工核查")
        for line in run(["git", "show", "--stat", "--oneline", head_after]).splitlines():
            log(f"  {line}")
    else:
        log("未检测到新提交（符合 autofix 边界：只做分析+修复+验证，不提交）")
    return 0 if r.returncode == 0 else 1


def main():
    p = argparse.ArgumentParser(description="AI 运维工具：确定性动作 + autofix 闭环")
    sub = p.add_subparsers(dest="cmd", required=True)

    pf = sub.add_parser("fetch", help="采集目标项目失败 run + 拉日志")
    pf.add_argument("project_dir", help="项目目录，如 library/httpd")
    pf.add_argument("--since-hours", type=int, default=24, help="时间窗口（小时），默认 24")
    pf.add_argument("--limit", type=int, default=100, help="拉取 run 上限，默认 100")
    pf.add_argument("--out", default=".ai-ops", help="日志输出目录，默认仓库根 .ai-ops/")
    pf.set_defaults(fn=cmd_fetch)

    pr = sub.add_parser("rerun", help="重跑指定 run（仅失败 jobs）")
    pr.add_argument("run_id")
    pr.set_defaults(fn=cmd_rerun)

    pd = sub.add_parser("dispatch", help="手动触发项目 workflow")
    pd.add_argument("project_dir", help="项目目录，如 library/httpd")
    pd.add_argument("version", nargs="?", default=None, help="指定版本（留空=自动检测）")
    pd.set_defaults(fn=cmd_dispatch)

    pc = sub.add_parser("commit", help="git add -A + commit（不 push）")
    pc.add_argument("-m", "--message", required=True, help="提交信息")
    pc.set_defaults(fn=cmd_commit)

    pb = sub.add_parser("branch", help="基于当前 HEAD 创建修复分支 {project_dir}-{YYYYMMDD}-{jobid}")
    pb.add_argument("project_dir", help="项目目录，如 library/alpine")
    pb.add_argument("jobid", help="job/run id，如 33604587228")
    pb.add_argument("--dry-run", "-n", action="store_true",
                    help="仅打印将执行的 git 命令，不执行")
    pb.set_defaults(fn=cmd_branch)

    pp = sub.add_parser("commit-pr",
                        help="提交修改并创建 PR：add 项目目录→commit -F commit-msg→push→gh pr create")
    pp.add_argument("project_dir", help="项目目录，如 library/alpine")
    pp.add_argument("run_id", help="run id，如 34050474275")
    pp.add_argument("--dry-run", "-n", action="store_true",
                    help="仅打印将执行的全部命令（git add/commit/push、gh pr create），不执行")
    pp.set_defaults(fn=cmd_commit_pr)

    pa = sub.add_parser("autofix", help="脚本化闭环：调 hermes 分析日志→修复→验证（不提交）")
    pa.add_argument("project_dir", help="项目目录，如 library/alpine")
    pa.add_argument("--run-id", type=int, default=None, help="指定 run（默认取最新失败 run）")
    pa.add_argument("--version", required=True,
                    help="验证用版本号（必填，如 3.24.1；autofix 不做自动探测）")
    pa.add_argument("--since-hours", type=int, default=24, help="失败 run 时间窗口（小时），默认 24")
    pa.add_argument("--limit", type=int, default=30, help="拉取 run 上限，默认 30")
    pa.add_argument("--out", default=".ai-ops", help="日志输出目录")
    pa.add_argument("--max-turns", type=int, default=60, help="hermes 会话最大轮数，默认 60")
    pa.add_argument("--timeout", type=int, default=1500, help="hermes 会话超时（秒），默认 1500")
    pa.add_argument("--dry-run", "-n", action="store_true",
                    help="仅打印将执行的 hermes 命令，不执行（仍会先采集失败 run 解析 run id 与日志路径）")
    pa.set_defaults(fn=cmd_autofix)

    args = p.parse_args()
    sys.exit(args.fn(args))


if __name__ == "__main__":
    main()
