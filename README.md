# OpenClaw API Manager (Standalone)

Extracted standalone script from `kejilion.sh` menu item **6. API管理**.

## Usage

```bash
bash openclaw-api-manager.sh
```

## One-line install to /root (with `api` shortcut command)

```bash
curl -fsSL https://raw.githubusercontent.com/jacurtwong/openclaw-api-manager/main/openclaw-api-manager.sh -o /root/openclaw-api-manager.sh && chmod +x /root/openclaw-api-manager.sh && printf '#!/usr/bin/env bash\nexec /root/openclaw-api-manager.sh "$@"\n' >/usr/local/bin/api && chmod +x /usr/local/bin/api
```

Then run directly:

```bash
api
```

## Links

- Repo: <https://github.com/jacurtwong/openclaw-api-manager>
- Raw script: <https://raw.githubusercontent.com/jacurtwong/openclaw-api-manager/main/openclaw-api-manager.sh>
