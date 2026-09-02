#!/usr/bin/env python3
"""tools/ai-ops.py — AI 运维工具

子命令：
  fetch    <project_dir> [--since-hours N] [--limit N] [--out DIR]
                                    采集目标项目失败/取消的 workflow run，并拉取失败日志落盘
  rerun    <run-id>                 重跑指定 run（仅失败 jobs）
  dispatch <project_dir> [version]  手动触发项目 workflow（workflow_dispatch）
  commit   -m <msg>                 git add -A + commit（不 push）
  autofix  <project_dir> [--run-id ID] [--max-turns N] [--timeout S]
                                    脚本化闭环：调 `hermes chat -q` 分析失败日志 →
                                    修复 → 验证（不提交、不推送；改动留工作区，
                                    由人工审阅后提交并重跑），会话后核对工作区状态；
                                    会话报告（错误原因+修复过程）自动落盘
                                    log/ai-ops/{date}-{project}.md

原则：fetch/rerun/dispatch/commit 只做确定性动作（无需判断）；
autofix 把「分析 + 修复决策」委托给 Hermes agent 的一次性会话执行，
脚本负责组装上下文、调用、核对结果、落盘会话记录。autofix 边界
（2026-09 确认）：只做错误分析 + 代码修复 + 验证，不提交不推送，
提交时机由人工决定。
"""

import argparse
import json
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

FAIL_CONCLUSIONS = {"failure", "cancelled", "timed_out", "startup_failure"}

REPO_ROOT = Path(__file__).resolve().parent.parent
LOG_DIR = REPO_ROOT / "log" / "ai-ops"


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


def build_autofix_prompt(project, run_id, log_path):
    """构造传给 hermes chat -q 的自包含任务 prompt（一次性会话无记忆）。

    autofix 边界（2026-09 确认）：只做错误分析 + 代码修复 + 验证，
    不提交、不推送；改动保留在工作区，由人工审阅后提交并重跑。
    """
    return f"""你是 container-ci-automation 仓库的 AI 运维 agent，执行一次「失败分析 → 代码修复 → 验证」闭环任务。

工作目录即仓库根（AGENTS.md 已注入项目背景与「AI 修复须知」）。任务上下文：
- 项目目录：{project}
- 失败 CI run id：{run_id}
- 失败日志：{log_path}

执行步骤（必须遵守 docs/ai-ops/runbook.md 与 AGENTS.md「AI 修复须知」）：
1. 读失败日志（tail 关键段），对照 runbook 失败分类表确定根因；
2. 读 {project}/AGENTS.md 的已知问题与维护记录：若该 run 已处理过，直接报告并退出（幂等，不重复修复）；
3. 修复：只改与根因相关的文件（{project}/template/、config.yml、get_versions.sh 等；tools/build.py 仅当其自身有 bug）。严禁改全局 config.yml 的 registry；修复改动一律留在工作区，不 git add；
4. 验证（前置，通不过不结束）：
   - 改过 .sh 先 bash -n；
   - 能跑则 python3 tools/build.py --test {project} <version>（不推送）；完整 loong64 镜像构建耗时长，若预计超时可改为只验证版本获取/模板渲染链路，并在结果中如实说明未跑完整构建的原因；
5. 回写 {project}/AGENTS.md 维护记录表，追加一行（日期 / 问题 / 修复 / commit）；表不存在则按 docs/07 规范建立。因改动未提交，commit 列暂填「待提交」；
6. 结束：不执行 git add / git commit / git push（本次会话任何情况下都不提交、不推送，提交由人工审阅改动后执行）。

最终回复将被脚本归档到 log/ai-ops/{{date}}-{{project}}.md（本地不入库），请保持结构清晰、内容自包含。最终回复（中文，简明）必须包含：
- 根因分类 + 一句话根因
- 修改的文件与要点（若无需修改，说明原因：幂等命中 / 外部凭据缺失 / 已修复等）
- 验证执行情况（bash -n / --test 结果，或未跑的原因）
- 工作区改动清单（git status --short + 关键 diff 摘要）
- 维护记录是否已回写

若无法修复或验证不过，不要结束任务，给出原因与建议（是否需人工或外部配置，如 registry 凭据 secrets）。"""


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

    prompt = build_autofix_prompt(args.project_dir, run_id, log_path)
    head_before = run(["git", "rev-parse", "--short", "HEAD"])

    cmdv = ["hermes", "chat", "-q", prompt, "-Q",
            "--in", str(REPO_ROOT), "--yolo",
            "--max-turns", str(args.max_turns),
            "-t", "file,terminal"]
    log("调用 hermes chat -q（一次性会话，典型耗时 1-10 分钟）...")
    try:
        r = subprocess.run(cmdv, capture_output=True, text=True, timeout=args.timeout)
    except subprocess.TimeoutExpired:
        log(f"hermes 会话超时（>{args.timeout}s）。可调大 --timeout 重试，或手动跑 fetch+修复。")
        log_file = write_autofix_log(args.project_dir, entry, "", rc=124,
                                     session_id="超时，无会话 id")
        log(f"超时已记录到 {log_file}")
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

    pa = sub.add_parser("autofix", help="脚本化闭环：调 hermes 分析日志→修复→验证（不提交）")
    pa.add_argument("project_dir", help="项目目录，如 library/alpine")
    pa.add_argument("--run-id", type=int, default=None, help="指定 run（默认取最新失败 run）")
    pa.add_argument("--since-hours", type=int, default=24, help="失败 run 时间窗口（小时），默认 24")
    pa.add_argument("--limit", type=int, default=30, help="拉取 run 上限，默认 30")
    pa.add_argument("--out", default=".ai-ops", help="日志输出目录")
    pa.add_argument("--max-turns", type=int, default=60, help="hermes 会话最大轮数，默认 60")
    pa.add_argument("--timeout", type=int, default=1500, help="hermes 会话超时（秒），默认 1500")
    pa.set_defaults(fn=cmd_autofix)

    args = p.parse_args()
    sys.exit(args.fn(args))


if __name__ == "__main__":
    main()
