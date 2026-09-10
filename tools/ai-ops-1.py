#!/usr/bin/env python3
"""tools/ai-ops-1.py — AI 运维工具（重构版，fetch/autofix 已落地）

设计（2026-09-08 定案，详见 docs/ai-ops/refactor-ai-ops.md）：
- 状态文件 .aiops-fix-info.json（仓库根，.gitignore）：fetch 采集后写入本次
  修复上下文（org/project/runid/url/conclusion/created_at/event/log-file/date/
  branch/process-error-file/commit-msg-file/versions）；后续命令
  （rerun/dispatch/branch/commit/commit-pr/autofix，待迭代）一律从该文件读取，
  不再靠位置参数传递
- 每个子命令支持 --dry-run/-n：打印全部将执行的 shell 命令，不执行、不写文件

当前实现：fetch、autofix、branch、commit-msg（autofix/branch/commit-msg 均从状态
文件 .aiops-fix-info.json 读取 run 上下文/分支名/文件路径，不再靠位置参数；
其余子命令逻辑保留在 tools/ai-ops.py，待后续迭代移植）。
"""

import argparse
import json
import re
import shlex
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

FAIL_CONCLUSIONS = {"failure", "cancelled", "timed_out", "startup_failure"}

REPO_ROOT = Path(__file__).resolve().parent.parent
LOG_DIR = REPO_ROOT / "log" / "ai-ops"
FIX_INFO_FILE = REPO_ROOT / ".aiops-fix-info.json"


def log(msg):
    print(f"[ai-ops] {msg}", file=sys.stderr)


def run(cmd, **kw):
    """执行命令；失败打印 stderr 并退出（保留原行为）。"""
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        log(f"命令失败 (exit {r.returncode}): {' '.join(cmd)}")
        log(r.stderr.strip())
        sys.exit(1)
    return r.stdout.strip()


def project_info(project_dir):
    """library/alpine -> ('library', 'alpine')"""
    p = Path(project_dir)
    return p.parts[-2], p.parts[-1]


def extract_versions_from_title(title):
    """从 run 标题提取版本号（x.y.z 三段式）；提取不到返回 []。"""
    return list(dict.fromkeys(re.findall(r"\d+\.\d+\.\d+", title or "")))


def build_fix_info(org, name, entry, versions):
    """由选中的失败 run entry 构造 .aiops-fix-info.json 内容。

    追加字段（2026-09-09 autofix 迭代）：conclusion/created_at/event/log-file——
    供 autofix 构造会话日志（write_autofix_log）使用，避免再次调用 gh；
    旧状态文件缺这些字段时 autofix 以默认值兜底。
    """
    # date 取 fetch 执行当天的日期（本地时区），不随 run 创建时间
    date = datetime.now().strftime("%Y%m%d")
    runid = str(entry["run_id"])
    prefix = f"{org}-{name}-{date}-{runid}"
    return {
        "org": org,
        "project": name,
        "runid": runid,
        "url": entry.get("url", ""),
        "conclusion": entry.get("conclusion", ""),
        "created_at": entry.get("created_at", ""),
        "event": entry.get("event", ""),
        "log-file": entry.get("log_path", ""),
        "date": date,
        "branch": f"fix-{prefix}",
        "process-error-file": f"{prefix}-process-error.md",
        "commit-msg-file": f"{prefix}-commit-msg.md",
        "versions": versions,
    }


def collect_failed_runs(project_dir, since_hours, limit):
    """查询项目失败/取消 run，返回 entry 列表（按创建时间升序）。

    与原 ai-ops.py collect_failed_runs 行为一致，但不再在此拉日志
    （拉日志独立为 fetch_run_log）。
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
    return [{
        "run_id": r["databaseId"],
        "conclusion": r["conclusion"],
        "title": r.get("displayTitle", ""),
        "created_at": r.get("createdAt", ""),
        "event": r.get("event", ""),
        "url": r.get("url", ""),
    } for r in failed]


def fetch_run_log(entry, project_dir, out):
    """拉取失败 run 日志落盘 {out}/fetch/{name}/{run_id}.log，返回路径。

    gh run view --log-failed 失败时回退 --log（保留原行为）。
    """
    _, name = project_info(project_dir)
    fetch_dir = Path(out) / "fetch" / name
    fetch_dir.mkdir(parents=True, exist_ok=True)
    log_path = fetch_dir / f"{entry['run_id']}.log"
    r2 = subprocess.run(["gh", "run", "view", str(entry["run_id"]), "--log-failed"],
                        capture_output=True, text=True)
    if r2.returncode != 0:
        r2 = subprocess.run(["gh", "run", "view", str(entry["run_id"]), "--log"],
                            capture_output=True, text=True)
    log_path.write_text(r2.stdout or r2.stderr)
    return log_path


def write_fix_info(fix_info):
    """把修复上下文写入 .aiops-fix-info.json（仓库根，gitignore）。"""
    FIX_INFO_FILE.write_text(
        json.dumps(fix_info, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return FIX_INFO_FILE


def load_fix_info():
    """读取状态文件 .aiops-fix-info.json；缺失/损坏时提示先执行 fetch 并退出。"""
    if not FIX_INFO_FILE.exists():
        log(f"未找到状态文件 {FIX_INFO_FILE.name}：请先执行 fetch 采集失败 run")
        sys.exit(1)
    try:
        return json.loads(FIX_INFO_FILE.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        log(f"状态文件 {FIX_INFO_FILE.name} 解析失败（{e}），请重新 fetch")
        sys.exit(1)


def entry_from_fix_info(info):
    """由状态文件构造日志/回写所需的 entry dict（兼容旧状态文件缺字段）。"""
    name = info["project"]
    default_log = REPO_ROOT / ".ai-ops" / "fetch" / name / f"{info['runid']}.log"
    return {
        "run_id": str(info["runid"]),
        "conclusion": info.get("conclusion", "failure"),
        "created_at": info.get("created_at", ""),
        "event": info.get("event", ""),
        "url": info.get("url", ""),
        "log_path": info.get("log-file", str(default_log)),
    }


def build_autofix_prompt(project, url, version, process_error_file):
    """构造传给 hermes chat -q 的自包含任务 prompt（一次性会话无记忆）。

    成功标志 = `python3 tools/build.py --test {project} {version}` 通过；修复成功后
    由 agent 自己把报错原因与修复方法写入状态文件 process-error-file 对应的文件
    log/ai-ops/{process_error_file}。
    version 为可选参数且允许为空（缺省取状态文件 versions 首个版本；versions 为空
    时默认值为空字符串，成功标志行不指定版本、由修复会话自行判断；脚本不做自动探测）。
    autofix 边界（2026-09 确认）：只做失败分析 + 代码修复 + 验证，不提交、不推送；
    改动保留在工作区，由人工审阅后提交并重跑。
    """
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
    3. 在修复成功后，需要再 log/ai-ops/{process_error_file} 中记录此次报错的原因和修复方法"""


def write_autofix_log(project_dir, entry, report, rc=0, session_id=None):
    """把一次 autofix 会话记录（错误原因 + 修复过程）追加到 log/ai-ops/{date}-{project}.md。

    - {date} 为执行日（本地时区 YYYY-MM-DD），{project} 为项目名（如 alpine）
    - 当日多次执行同一项目时按条目追加（## 时间戳 — run #id 分段）
    - 文件不入库（.gitignore 的 log/ai-ops/），本地可追溯；
      不再自动回写 docs/ai-ops/ci-fix.md（2026-09-09 起移除 write_ci_fix）
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
                    ".gitignore），本地可追溯。\n\n---\n\n")
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
    workflow_file = f"library-{name}.yml"
    runid_placeholder = str(args.run_id) if args.run_id else "<run-id>"

    if args.dry_run:
        # 打印实际将执行的 gh 命令，不执行、不写文件（run view 的 run-id
        # 取决于 gh run list 的查询结果，未用 --run-id 指定时为占位符）
        print(shlex.join([
            "gh", "run", "list",
            "--workflow", workflow_file,
            "--branch", "main",
            "--status", "completed",
            "--limit", str(args.limit),
            "--json", "databaseId,workflowName,conclusion,createdAt,displayTitle,headBranch,url,event",
        ]))
        print(shlex.join(["gh", "run", "view", runid_placeholder, "--log-failed"]))
        print(f"# 失败时回退: {shlex.join(['gh', 'run', 'view', runid_placeholder, '--log'])}")
        print(f"# 将把选中失败 run 的信息写入 {FIX_INFO_FILE.name}："
              f"org/project/runid/url/conclusion/created_at/event/log-file/date/"
              f"branch/process-error-file/commit-msg-file/versions")
        log(f"dry-run：仅打印上述命令，未执行（项目 {org}/{name}）")
        return 0

    entries = collect_failed_runs(args.project_dir, args.since_hours, args.limit)
    log(f"项目 {org}/{name}：失败/取消 {len(entries)}（窗口 {args.since_hours}h）")
    if not entries:
        log(f"无失败 run，未更新 {FIX_INFO_FILE.name}（保持上次状态，幂等退出）")
        return 0
    for e in entries:
        log(f"  #{e['run_id']}  {e['conclusion']}  {e['title']}  {e['created_at']}")

    if args.run_id:
        entry = next((e for e in entries if e["run_id"] == args.run_id), None)
        if entry is None:
            log(f"run {args.run_id} 不在失败列表中（窗口 {args.since_hours}h 共 {len(entries)} 个），"
                f"可扩大 --since-hours：")
            for e in entries:
                log(f"  #{e['run_id']}  {e['conclusion']}  {e['created_at']}")
            sys.exit(1)
    else:
        entry = entries[-1]  # 最新失败

    log_path = fetch_run_log(entry, args.project_dir, args.out)
    log(f"失败日志已落盘 {log_path}")
    entry["log_path"] = str(log_path)

    fix_info = build_fix_info(org, name, entry,
                              extract_versions_from_title(entry["title"]))
    path = write_fix_info(fix_info)
    log(f"修复上下文已写入 {path}")
    print(json.dumps(fix_info, ensure_ascii=False, indent=2))
    return 0


def cmd_branch(args):
    """从状态文件取分支名，基于当前 HEAD 创建并切换修复分支（仅本地，不推送）。

    分支名 = 状态文件 .aiops-fix-info.json 的 branch 字段（fetch 写入时按
    fix-{org}-{project}-{date}-{runid} 生成，如 fix-library-alpine-20260908-34050474275）；
    状态文件缺失/损坏时 load_fix_info 提示先 fetch 并退出。先 fetch 再 branch。
    """
    info = load_fix_info()
    branch = info["branch"]
    cmdv = ["git", "checkout", "-b", branch]
    if args.dry_run:
        # 仅打印实际将执行的 git 命令，不执行（与 autofix --dry-run 语义一致）
        print(shlex.join(cmdv))
        log(f"dry-run：仅打印上述命令，未执行（分支 {branch}）")
        return 0
    run(cmdv)
    log(f"已创建并切换到分支 {branch}")
    return 0


def cmd_autofix(args):
    """从状态文件取失败 run，调 hermes 分析日志→修复→验证（不提交、不推送）。

    与原 ai-ops.py 的差异（2026-09-09 重构）：不再接收 project_dir/--run-id/
    --since-hours 等采集参数——run 上下文（org/project/runid/url/log 路径等）
    一律从 .aiops-fix-info.json 读取（先 fetch 再 autofix）；--version 可选且允许
    为空（缺省取状态文件 versions 首个版本；versions 为空则默认空字符串）。
    """
    info = load_fix_info()
    project = f"{info['org']}/{info['project']}"
    entry = entry_from_fix_info(info)
    run_id, log_path = entry["run_id"], entry["log_path"]
    log(f"开始 autofix：{project} run #{run_id}  log={log_path}"
        f"（状态文件 {FIX_INFO_FILE.name}）")

    version = args.version
    if not version:
        versions = info.get("versions") or []
        if versions:
            version = str(versions[0])
            log(f"未传 --version：取状态文件 versions[0] = {version}")
        else:
            version = ""
            log("未传 --version 且状态文件 versions 为空：version 为空字符串")
    log(f"验证版本：{version or '（空）'}")
    prompt = build_autofix_prompt(project, entry["url"], version,
                                  info["process-error-file"])
    head_before = run(["git", "rev-parse", "--short", "HEAD"])

    cmdv = ["hermes", "chat", "-q", prompt, "-Q",
            "--in", str(REPO_ROOT), "--yolo",
            "--max-turns", str(args.max_turns),
            "-t", "file,terminal"]
    if args.dry_run:
        # 打印实际将执行的 hermes 命令（含完整 prompt），不执行。
        # 与旧版差异：无需先采集失败 run（上下文已由 fetch 写入状态文件）。
        print(shlex.join(cmdv))
        log(f"dry-run：仅打印上述 hermes 命令，未执行（run #{run_id}，log={log_path}）")
        return 0
    log("调用 hermes chat -q（一次性会话，典型耗时 1-10 分钟）...")
    try:
        r = subprocess.run(cmdv, capture_output=True, text=True, timeout=args.timeout)
    except subprocess.TimeoutExpired:
        log(f"hermes 会话超时（>{args.timeout}s）。可调大 --timeout 重试，或重新 fetch 后手动修复。")
        log_file = write_autofix_log(project, entry, "", rc=124,
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
    log_file = write_autofix_log(project, entry, r.stdout, rc=r.returncode, session_id=sid)
    log(f"autofix 会话已记录到 {log_file}")

    head_after = run(["git", "rev-parse", "--short", "HEAD"])
    if head_after != head_before:
        log(f"警告：检测到新提交（autofix 设计为不提交）：{head_before} -> {head_after}，请人工核查")
        for line in run(["git", "show", "--stat", "--oneline", head_after]).splitlines():
            log(f"  {line}")
    else:
        log("未检测到新提交（符合 autofix 边界：只做分析+修复+验证，不提交）")
    return 0 if r.returncode == 0 else 1


def build_commit_msg_prompt(project, doc_path):
    """构造让 hermes chat 把修复过程记录总结为 commit message 的一次性 prompt。

    输入是 process-error-file 对应文件（log/ai-ops/{process-error-file}，autofix
    会话中 agent 写入的报错原因 + 修复方法）；输出标题形如
    `fix library/alpine: ...` 的 commit message（首行标题 + 空行 + 正文）。
    """
    return f"""你是 container-ci-automation 仓库的 AI 运维助手，任务是把一次修复闭环的过程记录总结成 git commit message。

读取修复过程记录：{doc_path}

该文档记录了 {project} 项目某次 CI 失败修复闭环的过程（含错误原因、修复方法、验证结果），是本次要总结的修复内容。

输出格式（只输出 commit message 本身，不要任何前后缀说明或代码块围栏）：
1. 第一行为标题，形如：fix library/alpine: <一句话概括本次修复>
2. 空一行
3. 正文（commit body）：用简洁中文条目提炼 错误原因 / 修复方法 / 验证结果，3-8 行为宜"""


def cmd_commit_msg(args):
    """从状态文件取项目上下文，把修复过程记录（process-error-file）总结为 commit message。

    输入 = log/ai-ops/{process-error-file}（autofix 会话中 agent 写入的报错原因
    + 修复方法）；调 hermes 一次性会话总结，输出标题形如 `fix library/alpine: ...`
    的 commit message，落盘 log/ai-ops/{commit-msg-file}（均不入库）。
    流程节奏：fetch → autofix →（人工审阅）commit-msg → commit-pr。
    """
    info = load_fix_info()
    project = f"{info['org']}/{info['project']}"
    doc = LOG_DIR / info["process-error-file"]
    out = LOG_DIR / info["commit-msg-file"]
    if not doc.exists():
        log(f"找不到修复过程记录 {doc}（{project} 需先跑 autofix 生成 process-error 文件）")
        cands = sorted(LOG_DIR.glob(f"{info['org']}-{info['project']}-*"))
        if cands:
            log("log/ai-ops/ 下相关文件：")
            for c in cands:
                log(f"  {c.name}")
        sys.exit(1)

    prompt = build_commit_msg_prompt(project, doc)
    cmdv = ["hermes", "chat", "-q", prompt, "-Q",
            "--in", str(REPO_ROOT), "--yolo",
            "--max-turns", str(args.max_turns),
            "-t", "file,terminal"]
    if args.dry_run:
        # 仅打印实际将执行的 hermes 命令（含完整 prompt），不执行、不写文件
        print(shlex.join(cmdv))
        log(f"dry-run：仅打印上述命令，未执行（读 {doc.name}，写 {out.name}）")
        return 0
    log(f"调用 hermes chat 总结 commit message（读 {doc.name}）...")
    try:
        r = subprocess.run(cmdv, capture_output=True, text=True, timeout=args.timeout)
    except subprocess.TimeoutExpired:
        log(f"hermes 会话超时（>{args.timeout}s）。可调大 --timeout 重试。")
        sys.exit(1)
    print(r.stdout)
    if r.returncode != 0:
        log(f"hermes 退出码 {r.returncode}，仍将 stdout 落盘供人工参考")
        if r.stderr.strip():
            log("stderr 片段: " + r.stderr.strip()[:1000])
    msg = (r.stdout or "").strip()
    if not msg:
        log("hermes 无输出，未生成 commit-msg 文件")
        return 1
    if out.exists():
        log(f"目标文件已存在，覆盖：{out}")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(msg + "\n", encoding="utf-8")
    log(f"commit message 已写入 {out}")
    return 0 if r.returncode == 0 else 1


def main():
    p = argparse.ArgumentParser(
        description="AI 运维工具（重构版）：状态文件 .aiops-fix-info.json，fetch 先行")
    sub = p.add_subparsers(dest="cmd", required=True)

    pf = sub.add_parser("fetch", help="采集失败 run + 拉日志，写入 .aiops-fix-info.json")
    pf.add_argument("project_dir", help="项目目录，如 library/alpine")
    pf.add_argument("--since-hours", type=int, default=24, help="时间窗口（小时），默认 24")
    pf.add_argument("--limit", type=int, default=100, help="拉取 run 上限，默认 100")
    pf.add_argument("--run-id", type=int, default=None,
                    help="指定 run（默认取最新失败 run）")
    pf.add_argument("--out", default=".ai-ops",
                    help="失败日志输出目录，默认仓库根 .ai-ops/")
    pf.add_argument("--dry-run", "-n", action="store_true",
                    help="仅打印将执行的 gh 命令，不执行、不写文件")
    pf.set_defaults(fn=cmd_fetch)

    pb = sub.add_parser(
        "branch",
        help="从状态文件取分支名，基于当前 HEAD 创建修复分支 fix-{org}-{project}-{date}-{runid}"
             "（仅本地，不推送）")
    pb.add_argument("--dry-run", "-n", action="store_true",
                    help="仅打印将执行的 git 命令，不执行")
    pb.set_defaults(fn=cmd_branch)

    pa = sub.add_parser(
        "autofix",
        help="从状态文件取失败 run，调 hermes 分析日志→修复→验证（不提交不推送）")
    pa.add_argument("--version", default=None,
                    help="验证用版本号；缺省取状态文件 versions 首个版本，"
                         "versions 为空则默认为空字符串（autofix 不做自动探测）")
    pa.add_argument("--max-turns", type=int, default=60,
                    help="hermes 会话最大轮数，默认 60")
    pa.add_argument("--timeout", type=int, default=1500,
                    help="hermes 会话超时（秒），默认 1500")
    pa.add_argument("--dry-run", "-n", action="store_true",
                    help="仅打印将执行的 hermes 命令，不执行、不写文件"
                         "（上下文已由 fetch 写入状态文件，无需先采集）")
    pa.set_defaults(fn=cmd_autofix)

    pc = sub.add_parser(
        "commit-msg",
        help="从状态文件取项目上下文，把修复过程记录（process-error-file）总结为"
             " commit message（hermes 一次性会话），落盘 commit-msg-file")
    pc.add_argument("--max-turns", type=int, default=60,
                    help="hermes 会话最大轮数，默认 60")
    pc.add_argument("--timeout", type=int, default=600,
                    help="hermes 会话超时（秒），默认 600")
    pc.add_argument("--dry-run", "-n", action="store_true",
                    help="仅打印将执行的 hermes 命令，不执行、不写文件")
    pc.set_defaults(fn=cmd_commit_msg)

    args = p.parse_args()
    sys.exit(args.fn(args))


if __name__ == "__main__":
    main()
