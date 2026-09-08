#!/usr/bin/env python3
"""tools/ai-ops-1.py — AI 运维工具（重构版，fetch 先行）

设计（2026-09-08 定案，详见 docs/ai-ops/refactor-ai-ops.md）：
- 状态文件 .aiops-fix-info.json（仓库根，.gitignore）：fetch 采集后写入本次
  修复上下文（org/project/runid/date/branch/process-error-file/commit-msg-file/
  versions）；后续命令（rerun/dispatch/branch/commit/commit-pr/autofix，待迭代）
  一律从该文件读取，不再靠位置参数传递
- 每个子命令支持 --dry-run/-n：打印全部将执行的 shell 命令，不执行、不写文件

当前实现：仅 fetch（其余子命令逻辑保留在 tools/ai-ops.py，待后续迭代移植）。
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
    """由选中的失败 run entry 构造 .aiops-fix-info.json 内容。"""
    # date 取 fetch 执行当天的日期（本地时区），不随 run 创建时间
    date = datetime.now().strftime("%Y%m%d")
    runid = str(entry["run_id"])
    prefix = f"{org}-{name}-{date}-{runid}"
    return {
        "org": org,
        "project": name,
        "runid": runid,
        "url": entry.get("url", ""),
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
              f"org/project/runid/url/date/branch/process-error-file/commit-msg-file/versions")
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

    fix_info = build_fix_info(org, name, entry,
                              extract_versions_from_title(entry["title"]))
    path = write_fix_info(fix_info)
    log(f"修复上下文已写入 {path}")
    print(json.dumps(fix_info, ensure_ascii=False, indent=2))
    return 0


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

    args = p.parse_args()
    sys.exit(args.fn(args))


if __name__ == "__main__":
    main()