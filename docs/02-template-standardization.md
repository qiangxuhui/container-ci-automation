# 02 — 模板目录结构统一规范（v6）

## 目标

所有项目的模板目录遵循相同结构，使 process_version.sh 可以统一处理。

## 统一目录结构

```
{project}/template/
├── Dockerfile-{variant}.template   ← 模板文件
├── versions.json                   ← 版本数据
└── {full_version}/                 ← 生成的版本目录
    └── {variant}/
        └── Dockerfile              ← 渲染后的 Dockerfile
```

## 模板文件规范

### 命名规范

```
Dockerfile-{variant}.template

示例：
  Dockerfile-forky.template
  Dockerfile-slim-forky.template
  Dockerfile-alpine.template
```

### 变量规范（sed 替换）

所有模板使用统一的变量占位符：

| 变量 | 含义 | 示例值 |
|------|------|--------|
| `{VERSION}` | full version | 4.0.6 |
| `{MAJOR_VERSION}` | major version | 4.0 |
| `{VARIANT}` | variant 名称 | forky |
| `{REGISTRY}` | registry 地址 | lcr.loongnix.cn |
| `{REPOSITORY}` | 镜像仓库 | library/ruby |
| `{CUSTOM_*}` | 自定义变量 | 由 config.yml 定义 |

渲染命令：
```bash
sed -e "s/{VERSION}/$version/g" \
    -e "s/{MAJOR_VERSION}/$major_version/g" \
    -e "s/{VARIANT}/$variant/g" \
    -e "s/{REGISTRY}/$REGISTRY/g" \
    -e "s/{REPOSITORY}/$REPOSITORY/g" \
    template/Dockerfile-$VARIANT.template > output/Dockerfile
```

## 上游模板拆分规则

如果上游使用 jinja 混合 debian 和 alpine 模板，拆分为两个独立模板：

### 示例：上游混合模板

```dockerfile
# upstream/Dockerfile.template（jinja）
{% if variant == 'alpine' %}
FROM alpine:3.24
RUN apk add --no-cache ruby
{% else %}
FROM buildpack-deps:forky
RUN apt-get update && apt-get install -y ruby
{% endif %}
```

### 拆分后

```dockerfile
# template/Dockerfile-forky.template
FROM buildpack-deps:forky
RUN apt-get update && apt-get install -y ruby
```

```dockerfile
# template/Dockerfile-alpine.template
FROM alpine:3.24
RUN apk add --no-cache ruby
```

### 拆分原则

1. 每个模板文件只包含一个变体的内容
2. 移除所有 jinja/条件逻辑
3. 保留完整的 Dockerfile 语法
4. 使用统一的变量占位符

## 模板示例

### Dockerfile-forky.template

```dockerfile
ARG VERSION

FROM {REGISTRY}/library/buildpack-deps:forky

ARG VERSION
LABEL org.opencontainers.image.version="{VERSION}"

RUN apt-get update && apt-get install -y \
    ruby-{VERSION} \
    && rm -rf /var/lib/apt/lists/*

CMD ["ruby", "--version"]
```

### Dockerfile-alpine.template

```dockerfile
ARG VERSION

FROM {REGISTRY}/library/alpine:3.24

ARG VERSION
LABEL org.opencontainers.image.version="{VERSION}"

RUN apk add --no-cache ruby={VERSION}

CMD ["ruby", "--version"]
```

## versions.json 格式

```json
{
  "versions": [
    {
      "full_version": "4.0.6",
      "major_version": "4.0",
      "status": "active",
      "variants": ["forky", "slim-forky", "alpine"]
    }
  ]
}
```

## 验证

```bash
# 检查模板文件是否存在
for template in Dockerfile-forky.template Dockerfile-alpine.template; do
    if [[ -f "library/ruby/template/$template" ]]; then
        echo "✓ $template exists"
    else
        echo "✗ $template missing"
    fi
done

# 检查变量占位符是否统一
grep -E '\{VERSION\}|\{MAJOR_VERSION\}|\{VARIANT\}' library/ruby/template/*.template
```
