# 04 — processed_versions.txt 并发处理策略

## 问题

多个 workflow 并行触发时，多个 process_version.sh 实例可能同时：
1. 读取 processed_versions.txt
2. 添加新版本
3. 提交并推送

这会导致 git 冲突。

## 解决方案：乐观锁 + 自动重试

### 策略

1. 构建前保存 processed_versions.txt 的 SHA
2. 构建完成后提交时检查 SHA 是否变化
3. 如果变化（其他 workflow 已提交），自动 rebase 后重试

### 实现

```bash
git_commit() {
    local project_dir="$1"
    local versions="$2"
    local max_retries=3
    local retry=0

    cd "$project_dir"

    # 保存构建前的 SHA
    local base_sha
    base_sha=$(git rev-parse HEAD)

    while [ $retry -lt $max_retries ]; do
        # 尝试提交
        git add processed_versions.txt
        git config user.name "github-actions[bot]"
        git config user.email "github-actions[bot]@users.noreply.github.com"
        git commit -m "$(basename "$(pwd)"): add versions $versions" || true

        # 尝试推送
        if git pull --rebase && git push origin main; then
            log INFO "Successfully pushed"
            cd - > /dev/null
            return 0
        fi

        # 推送失败，可能有冲突
        retry=$((retry + 1))
        if [ $retry -lt $max_retries ]; then
            log WARN "Push failed (attempt $retry/$max_retries), retrying..."

            # 回滚本次提交
            git reset --soft HEAD~1

            # 拉取最新代码
            git pull --rebase

            # 重新添加版本
            for ver in $versions; do
                update_versions_file processed_versions.txt "$ver"
            done

            sleep $((retry * 2))
        fi
    done

    log ERROR "Push failed after $max_retries attempts"
    cd - > /dev/null
    return 1
}
```

### 流程图

```
读取 processed_versions.txt
    │
    ▼
构建镜像
    │
    ▼
添加新版本到 processed_versions.txt
    │
    ▼
git add + commit
    │
    ▼
git pull --rebase
    │
    ├── 成功 → git push → 完成
    │
    └── 失败（冲突）
            │
            ▼
        git reset --soft HEAD~1
            │
            ▼
        git pull --rebase（获取最新）
            │
            ▼
        重新添加版本
            │
            ▼
        重试 commit + push
```

## 其他策略（备选）

### 策略 2：使用 git 的 merge 而不是 rebase

```bash
# 如果 rebase 失败，使用 merge
if ! git pull --rebase; then
    git merge --no-edit origin/main
fi
git push origin main
```

### 策略 3：使用 flock 文件锁

```bash
# 在脚本开头获取锁
exec 9>/tmp/ci-build.lock
flock -n 9 || { echo "Another build is running"; exit 1; }

# ... 构建逻辑 ...

# 脚本结束自动释放锁
```

**不推荐**：flock 会阻塞其他 workflow，降低并行效率。

### 策略 4：外部存储（未来）

将 processed_versions.txt 迁移到 GitHub Actions cache 或外部数据库，
彻底消除 git 冲突。

**当前不采用**：保持简单，先用 git 冲突重试方案。

## 验证

```bash
# 模拟并发冲突
# 终端 1
./tools/process_version.sh library/ruby 4.0.6 &

# 终端 2
./tools/process_version.sh library/ruby 4.0.7 &

# 两个进程应该都能成功提交
# 最终 processed_versions.txt 包含两个版本
```
