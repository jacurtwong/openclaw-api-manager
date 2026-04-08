# OpenClaw API 管理器（独立版）

这是从 `kejilion.sh` 中「6. API 管理」提取出来的独立脚本。

## 功能

- 添加 API Provider
- 同步指定 Provider 的模型列表（基于上游 `/models`）
- 切换协议类型（`openai-completions` / `openai-responses`）
- 删除 Provider（带默认模型兜底逻辑）
- 启动自动检查依赖，缺失会自动安装（`python3`、`curl`）

## 一键安装（下载到 `/root`、赋权、创建 `api` 快捷命令并立即运行）

```bash
curl -fsSL https://raw.githubusercontent.com/jacurtwong/openclaw-api-manager/main/openclaw-api-manager.sh -o /root/openclaw-api-manager.sh && chmod +x /root/openclaw-api-manager.sh && printf '#!/usr/bin/env bash\nexec /root/openclaw-api-manager.sh "$@"\n' >/usr/local/bin/api && chmod +x /usr/local/bin/api && api
```

## 日常使用

```bash
api
```

## 项目链接

- 仓库：<https://github.com/jacurtwong/openclaw-api-manager>
- 原始脚本：<https://raw.githubusercontent.com/jacurtwong/openclaw-api-manager/main/openclaw-api-manager.sh>
