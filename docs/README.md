# Container CI Automation — 设计文档索引（v6.2）

## 核心目标

**用声明式配置 + 统一工具，替代 76+ 个项目各自手写的 process_version.sh 和 lib.sh**

## 文档列表

| 文件 | 内容 | 版本 |
|------|------|------|
| 00-overview.md | 目标、核心约束 | v6.2 |
| 01-declarative-config.md | config.yml + versions.json 格式 | v6.2 |
| 02-template-standardization.md | 模板目录结构统一规范 | v6 |
| 03-unified-tools.md | 统一工具设计 | v6.2 |
| 04-git-merge-strategy.md | processed_versions.txt 并发处理 | v6 |
| 06-architecture.md | 整体架构 | v6.2 |

## 核心设计

### 三脚本模式

| 脚本 | 职责 |
|------|------|
| versions.sh | 生成 versions.json（版本列表） |
| update.sh | 接收版本号，处理模板变量 |
| apply-templates.sh | 使用变量，应用模板生成 Dockerfile |

process_version.sh 统一调用这三个脚本。

### 目录结构

```
library/ruby/template/
├── versions.sh
├── update.sh
├── apply-templates.sh
├── versions.json
├── variables.json
├── Dockerfile-forky.template
├── Dockerfile-slim-forky.template
├── Dockerfile-alpine.template
└── 4.0.6/
    ├── forky/Dockerfile
    ├── slim-forky/Dockerfile
    └── alpine/Dockerfile
```
