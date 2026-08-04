# 迁移规范

## 迁移流程（上游模板项目 → 本地模板项目）

### 第一步：分析上游仓库

1. 阅读上游 README，了解项目用途和构建方式
2. 查看目录结构，找到模板文件和渲染脚本
3. 阅读上游 `update.sh` / `versions.sh` / `apply-templates.sh`，理解版本获取和渲染逻辑
4. 运行上游脚本，查看最终生成的 Dockerfile

### 第二步：提取模板变量

1. 对比上游最终生成的 Dockerfile，找出与版本变化有关的值
2. 将这些值替换为 `{VAR}` 占位符
3. 常见变量：
   - `{VERSION}` — 软件版本号
   - `{SHA256}` — 下载文件校验和
   - `{ALPINE_VERSION}` / `{DEBIAN_VERSION}` — 基础镜像版本
   - `{URL_xxx}` — 下载链接（多架构项目）
4. 按基础系统分离模板：`Dockerfile-debian.template` / `Dockerfile-alpine.template`
5. FROM 指令添加 `lcr.loongnix.cn/library/` 前缀

### 第三步：编写 update.sh

1. 在脚本顶部定义变体版本：
   ```bash
   alpine_versions="3.22 3.23"
   debian_version="forky"
   ```
2. 从上游 API 或下载站获取版本信息
3. 生成 `versions.json`，包含：
   - `version` — 软件版本号
   - `alpine_version` / `debian_version` — 基础镜像版本
   - 模板中 `{VAR}` 对应的所有值
4. 禁止使用单独的 `.version` 文件

### 第四步：编写 apply-templates.sh

1. 从 `versions.json` 读取变量（使用 jq）
2. 使用 sed 渲染模板，替换所有 `{VAR}` 占位符
3. 输出到 `dockerfiles/$version/$variant/Dockerfile`

### 第五步：验证

1. 语法检查：`bash -n template/*.sh`
2. 运行 `update.sh` 生成 `versions.json`
3. 运行 `apply-templates.sh` 生成 Dockerfile
4. 对比生成的 Dockerfile 与上游，确认功能逻辑一致

---

## 强制流程

```
update.sh → versions.json → apply-templates.sh → Dockerfile
```

## 模板规范

1. **变量提取**: 从上游最终 Dockerfile 提取关键变量，用 `{VAR}` 占位符
2. **分离变体**: 按基础系统拆分 `Dockerfile-debian.template` / `Dockerfile-alpine.template`
3. **基础镜像前缀**: FROM 必须加 `lcr.loongnix.cn/library/`
4. **全量版本号**: 上游用 a.b 也坚持用 a.b.c

## 版本管理规范

1. **集中管理**: alpine/debian 版本在 `update.sh` 顶部定义
2. **写入 JSON**: 版本信息写入 `versions.json`，禁止使用单独的 `.version` 文件
3. **精简原则**: versions.json 只存模板渲染需要的数据

## 工具规范

- **sed**: 简单单行替换（{VERSION}, {SHA256} 等）
- **jq**: JSON 数据提取
- **Python**: 仅用于多行文本生成，尽量避免
- **执行权限**: 新建 .sh 文件必须 `chmod +x`
