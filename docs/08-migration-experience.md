# 迁移规范

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
