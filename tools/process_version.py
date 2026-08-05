#!/usr/bin/env python3
"""tools/process_version.py — 统一入口，所有项目共用"""

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import yaml


# ── 日志 ────────────────────────────────────────────────────────────

COLORS = {"INFO": "\033[0;32m", "WARN": "\033[0;33m", "ERROR": "\033[0;31m", "": "\033[0m"}


def log(level, msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    c = COLORS.get(level, COLORS[""])
    print(f"{c}[{ts}] [{level}] {msg}\033[0m", file=sys.stderr)


# ── 配置 ────────────────────────────────────────────────────────────

@dataclass
class Config:
    registry: str
    org: str
    name: str
    version_source_type: str
    version_source_repo: str
    version_source_script: str
    variants: list  # [{"name": str, "template": str, "tags": [str]}]

    @property
    def repository(self):
        return f"{self.org}/{self.name}"


def load_config(project_dir: Path) -> Config:
    """加载全局 config.yml + 项目 config.yml"""
    root = Path(__file__).resolve().parent.parent
    global_cfg_path = root / "config.yml"
    project_cfg_path = project_dir / "config.yml"

    if not global_cfg_path.exists():
        log("ERROR", f"全局配置不存在: {global_cfg_path}")
        sys.exit(2)
    if not project_cfg_path.exists():
        log("ERROR", f"项目配置不存在: {project_cfg_path}")
        sys.exit(2)

    with open(global_cfg_path) as f:
        global_cfg = yaml.safe_load(f)
    with open(project_cfg_path) as f:
        project_cfg = yaml.safe_load(f)

    vs = project_cfg.get("version_source", {})
    return Config(
        registry=global_cfg.get("registry", ""),
        org=project_cfg["project"]["org"],
        name=project_cfg["project"]["name"],
        version_source_type=vs.get("type", "github_releases"),
        version_source_repo=vs.get("repository", ""),
        version_source_script=vs.get("script", ""),
        variants=project_cfg.get("variants", []),
    )


# ── 版本获取 ────────────────────────────────────────────────────────

def get_versions(project_dir: Path, cfg: Config) -> list[str]:
    """获取版本列表，每行一个版本号"""
    if cfg.version_source_type == "script":
        script = project_dir / cfg.version_source_script
        if not script.exists():
            log("ERROR", f"版本脚本不存在: {script}")
            sys.exit(1)
        script.chmod(0o755)
        r = subprocess.run([str(script)], capture_output=True, text=True)
        if r.returncode != 0:
            log("ERROR", f"版本脚本执行失败:\n{r.stderr}")
            sys.exit(1)
        return [v.strip() for v in r.stdout.splitlines() if v.strip()]

    elif cfg.version_source_type == "github_releases":
        r = subprocess.run(
            ["gh", "api", f"repos/{cfg.version_source_repo}/releases/latest", "--jq", ".tag_name"],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            log("ERROR", f"GitHub API 调用失败:\n{r.stderr}")
            sys.exit(1)
        tag = r.stdout.strip()
        # 尝试用 tag_regex 提取版本号
        vs_cfg = yaml.safe_load((project_dir / "config.yml").read_text()).get("version_source", {})
        regex = vs_cfg.get("tag_regex")
        if regex:
            m = re.search(regex, tag)
            if m:
                return [m.group(1)]
        return [tag]

    else:
        log("ERROR", f"未知版本源类型: {cfg.version_source_type}")
        sys.exit(2)


# ── 版本跟踪 ────────────────────────────────────────────────────────

def is_already_built(project_dir: Path, version: str) -> bool:
    vf = project_dir / "processed_versions.txt"
    if not vf.exists():
        return False
    return version in vf.read_text().splitlines()


def update_versions_file(project_dir: Path, version: str):
    vf = project_dir / "processed_versions.txt"
    versions = set(vf.read_text().splitlines()) if vf.exists() else set()
    versions.add(version)
    vf.write_text("\n".join(sorted(versions)) + "\n")
    log("INFO", f"已记录版本 {version}")


# ── 版本变量 ────────────────────────────────────────────────────────

def compute_version_vars(version: str) -> dict:
    """语义版本: 3.24.1 → major=3, minor=3.24"""
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)$", version)
    if m:
        return {"version": version, "major_version": m.group(1), "minor_version": f"{m.group(1)}.{m.group(2)}"}
    return {"version": version, "major_version": version, "minor_version": version}


def render_tag(pattern: str, vars_: dict) -> str:
    tag = pattern
    for k, v in vars_.items():
        tag = tag.replace(f"{{{k}}}", v)
    return tag


# ── 外部命令 ────────────────────────────────────────────────────────

def run_script(project_dir: Path, script_name: str, version: str, dry_run: bool):
    script = project_dir / "template" / script_name
    if not script.exists():
        log("WARN", f"{script_name} 不存在: {script}，跳过")
        return
    log("INFO", f"  执行 {script_name} {version}")
    if dry_run:
        log("INFO", f"  [dry-run] cd {project_dir / 'template'} && ./{script_name} {version}")
        return
    r = subprocess.run([f"./{script_name}", version], cwd=str(project_dir / "template"))
    if r.returncode != 0:
        log("ERROR", f"{script_name} 执行失败 (exit {r.returncode})")
        sys.exit(1)


def build_variant(
    version: str,
    variant_name: str,
    tags: list[str],
    cfg: Config,
    project_dir: Path,
    test_mode: bool,
    dry_run: bool,
):
    build_dir = project_dir / "dockerfiles" / version / variant_name
    if not (build_dir / "Dockerfile").exists():
        log("WARN", f"Dockerfile 不存在: {build_dir}/Dockerfile，跳过")
        return

    vars_ = compute_version_vars(version)
    repo = f"{cfg.registry}/{cfg.repository}"
    full_tags = [f"{repo}:{render_tag(t, vars_)}" for t in tags]

    tag_args = []
    for t in full_tags:
        tag_args.extend(["-t", t])

    log("INFO", f"  构建: {full_tags[0]}")
    if dry_run:
        log("INFO", f"  [dry-run] docker buildx build --platform linux/loong64 --load {' '.join(tag_args)} {build_dir}")
        return

    subprocess.run(
        ["docker", "buildx", "build", "--platform", "linux/loong64", "--load", *tag_args, str(build_dir)],
        check=True,
    )

    if not test_mode:
        log("INFO", f"  推送...")
        subprocess.run(
            ["docker", "buildx", "build", "--platform", "linux/loong64", "--push", *tag_args, str(build_dir)],
            check=True,
        )
    else:
        log("INFO", "  测试模式: 跳过推送")


# ── 主流程 ──────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="容器镜像构建统一入口",
        epilog="示例:\n"
               "  %(prog)s library/ruby\n"
               "  %(prog)s --test library/ruby 4.0.6\n"
               "  %(prog)s --dry-run library/debian",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("project_dir", help="项目目录（如 library/ruby）")
    parser.add_argument("version", nargs="?", default=None, help="版本号（测试模式必填）")
    parser.add_argument("--test", "-t", action="store_true", help="测试模式: 强制构建，不推送，不记录")
    parser.add_argument("--dry-run", "-n", action="store_true", help="仅打印命令，不执行")
    parser.add_argument("--versions", "-V", action="store_true", help="仅获取并输出最新版本号")
    args = parser.parse_args()

    # 解析项目目录
    project_dir = Path(args.project_dir).resolve()
    if not project_dir.is_dir():
        log("ERROR", f"项目目录不存在: {project_dir}")
        sys.exit(2)

    # 测试模式必须指定版本
    if args.test and not args.version:
        log("ERROR", "测试模式必须指定版本号")
        sys.exit(2)

    # 加载配置
    cfg = load_config(project_dir)

    # --versions: 仅输出版本号
    if args.versions:
        versions = get_versions(project_dir, cfg)
        for v in versions:
            print(v)
        return

    # 获取版本
    if args.version:
        versions = [args.version]
    else:
        versions = get_versions(project_dir, cfg)

    if not versions:
        log("INFO", "未找到版本")
        return

    mode = "测试模式" if args.test else "处理"
    log("INFO", "=========================================")
    log("INFO", f"{mode}: {cfg.repository}")
    log("INFO", f"版本: {' '.join(versions)}")
    log("INFO", "=========================================")

    for version in versions:
        # 去重检查（测试模式跳过）
        if not args.test and is_already_built(project_dir, version):
            log("INFO", f"版本 {version} 已构建，跳过")
            continue

        if args.test:
            log("INFO", f"测试模式: 强制构建版本 {version}")

        log("INFO", f"版本 {version} 开始构建...")

        # update.sh → apply-templates.sh → build
        run_script(project_dir, "update.sh", version, args.dry_run)
        run_script(project_dir, "apply-templates.sh", version, args.dry_run)

        for v in cfg.variants:
            build_variant(
                version=version,
                variant_name=v["name"],
                tags=v["tags"],
                cfg=cfg,
                project_dir=project_dir,
                test_mode=args.test,
                dry_run=args.dry_run,
            )

        # 记录版本（测试模式或 dry-run 跳过）
        if args.test or args.dry_run:
            log("INFO", "跳过版本记录")
        else:
            update_versions_file(project_dir, version)


if __name__ == "__main__":
    main()
