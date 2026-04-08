#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${HOME}/.openclaw/openclaw.json"

color_red='\033[31m'
color_green='\033[32m'
color_yellow='\033[33m'
color_gray='\033[90m'
color_reset='\033[0m'

break_end() {
  echo
  read -erp "按回车继续..." _
}

ensure_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${color_red}❌ 未找到配置文件: $CONFIG_FILE${color_reset}"
    echo "请先安装并初始化 OpenClaw（openclaw onboard）"
    return 1
  fi
}

start_gateway() {
  if command -v openclaw >/dev/null 2>&1; then
    echo "🔄 正在重启 OpenClaw Gateway..."
    openclaw gateway stop >/dev/null 2>&1 || true
    openclaw gateway start >/dev/null 2>&1 || true
    echo "✅ Gateway 已重启"
  else
    echo "ℹ️ 未检测到 openclaw 命令，已跳过网关重启。"
  fi
}

ensure_deps() {
  local required=(python3 curl)
  local missing=()
  local c

  for c in "${required[@]}"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done

  if (( ${#missing[@]} == 0 )); then
    return 0
  fi

  echo "⚠️ 缺少依赖: ${missing[*]}"
  echo "🔧 正在自动安装依赖..."

  local installer=""
  if command -v apt-get >/dev/null 2>&1; then
    installer="apt"
  elif command -v dnf >/dev/null 2>&1; then
    installer="dnf"
  elif command -v yum >/dev/null 2>&1; then
    installer="yum"
  elif command -v zypper >/dev/null 2>&1; then
    installer="zypper"
  elif command -v apk >/dev/null 2>&1; then
    installer="apk"
  fi

  if [[ -z "$installer" ]]; then
    echo "❌ 无法识别包管理器，请手动安装: ${missing[*]}"
    return 1
  fi

  local run_prefix=()
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      run_prefix=(sudo)
    else
      echo "❌ 当前非 root 且没有 sudo，无法自动安装依赖: ${missing[*]}"
      return 1
    fi
  fi

  case "$installer" in
    apt)
      "${run_prefix[@]}" apt-get update -y
      "${run_prefix[@]}" apt-get install -y python3 curl
      ;;
    dnf)
      "${run_prefix[@]}" dnf install -y python3 curl
      ;;
    yum)
      "${run_prefix[@]}" yum install -y python3 curl
      ;;
    zypper)
      "${run_prefix[@]}" zypper --non-interactive refresh
      "${run_prefix[@]}" zypper --non-interactive install python3 curl
      ;;
    apk)
      "${run_prefix[@]}" apk add --no-cache python3 curl
      ;;
  esac

  missing=()
  for c in "${required[@]}"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done

  if (( ${#missing[@]} > 0 )); then
    echo "❌ 依赖安装失败，请手动安装: ${missing[*]}"
    return 1
  fi

  echo "✅ 依赖检查通过"
}

write_provider_models_from_ids() {
  local provider_name="$1"
  local base_url="$2"
  local api_key="$3"
  local api_type="$4"
  local model_ids_raw="$5"

  python3 - "$CONFIG_FILE" "$provider_name" "$base_url" "$api_key" "$api_type" <<'PY'
import json
import sys
from copy import deepcopy

path, provider, base_url, api_key, api_type = sys.argv[1:6]
model_ids_raw = sys.stdin.read().strip().splitlines()
model_ids = [m.strip() for m in model_ids_raw if m.strip()]

with open(path, 'r', encoding='utf-8') as f:
    obj = json.load(f)

work = deepcopy(obj)
models_cfg = work.setdefault('models', {})
providers = models_cfg.setdefault('providers', {})

models = []
for mid in model_ids:
    models.append({
        'id': mid,
        'name': f'{provider} / {mid}',
        'input': ['text', 'image'],
        'contextWindow': 128000,
        'maxTokens': 4096,
        'cost': {
            'input': 0.1,
            'output': 0.4,
            'cacheRead': 0,
            'cacheWrite': 0,
        },
    })

providers[provider] = {
    'baseUrl': base_url.rstrip('/'),
    'apiKey': api_key,
    'api': api_type,
    'models': models,
}

agents = work.setdefault('agents', {})
defaults = agents.setdefault('defaults', {})
defaults_models_raw = defaults.get('models')
if isinstance(defaults_models_raw, dict):
    defaults_models = defaults_models_raw
elif isinstance(defaults_models_raw, list):
    defaults_models = {str(x): {} for x in defaults_models_raw if isinstance(x, str)}
else:
    defaults_models = {}
defaults['models'] = defaults_models

for m in models:
    defaults_models.setdefault(f"{provider}/{m['id']}", {})

with open(path, 'w', encoding='utf-8') as f:
    json.dump(work, f, ensure_ascii=False, indent=2)
    f.write('\n')

print(f"✅ 已写入 provider: {provider}，模型数量: {len(models)}")
PY
}

fetch_models_ids() {
  local base_url="$1"
  local api_key="$2"

  local models_json
  models_json=$(curl -sS -m 12 -H "Authorization: Bearer $api_key" "${base_url%/}/models" || true)
  if [[ -z "$models_json" ]]; then
    return 1
  fi

  python3 - <<'PY' <<< "$models_json"
import json,sys
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception:
    raise SystemExit(1)
arr = data.get('data') if isinstance(data, dict) else None
if not isinstance(arr, list):
    raise SystemExit(1)
for item in arr:
    if isinstance(item, dict) and item.get('id'):
        print(str(item['id']))
PY
}

openclaw_api_manage_list() {
  ensure_config || return 0

  python3 - "$CONFIG_FILE" <<'PY'
import json
import sys
import time
import urllib.request

path = sys.argv[1]
SUPPORTED_APIS = {'openai-completions', 'openai-responses'}


def ping_models(base_url, api_key):
    req = urllib.request.Request(
        base_url.rstrip('/') + '/models',
        headers={
            'Authorization': f'Bearer {api_key}',
            'User-Agent': 'OpenClaw-API-Manage/Standalone',
        },
    )
    start = time.perf_counter()
    with urllib.request.urlopen(req, timeout=4) as resp:
        resp.read(2048)
    return int((time.perf_counter() - start) * 1000)


def classify_latency(latency):
    if latency == '不可用':
        return '不可用'
    if latency == '未检测':
        return '未检测'
    if isinstance(latency, int):
        return f'{latency}ms'
    return str(latency)


try:
    with open(path, 'r', encoding='utf-8') as f:
        obj = json.load(f)
except Exception as e:
    print(f'❌ 读取配置失败: {type(e).__name__}: {e}')
    raise SystemExit(0)

providers = ((obj.get('models') or {}).get('providers') or {})
if not isinstance(providers, dict) or not providers:
    print('ℹ️ 当前未配置任何 API provider。')
    raise SystemExit(0)

print('--- 已配置 API 列表 ---')

for idx, name in enumerate(sorted(providers.keys()), start=1):
    provider = providers.get(name)
    if not isinstance(provider, dict):
        print(f'[{idx}] {name} | 配置异常')
        continue

    base_url = provider.get('baseUrl') or provider.get('url') or provider.get('endpoint') or '-'
    models = provider.get('models') if isinstance(provider.get('models'), list) else []
    model_count = sum(1 for m in models if isinstance(m, dict) and m.get('id'))
    api = provider.get('api', '-')
    api_key = provider.get('apiKey')

    latency_raw = '未检测'
    if api in SUPPORTED_APIS:
        if isinstance(base_url, str) and base_url != '-' and isinstance(api_key, str) and api_key:
            try:
                latency_raw = ping_models(base_url, api_key)
            except Exception:
                latency_raw = '不可用'
        else:
            latency_raw = '不可用'
    else:
        latency_raw = '不可用'

    print(f'[{idx}] {name} | API: {base_url} | 协议: {api} | 模型: {model_count} | 延迟/状态: {classify_latency(latency_raw)}')
PY
}

add_openclaw_provider_interactive() {
  ensure_config || { break_end; return; }

  echo "=== 添加 OpenClaw Provider ==="
  read -erp "请输入 Provider 名称 (如: deepseek): " provider_name
  while [[ -z "${provider_name:-}" ]]; do
    echo "❌ Provider 名称不能为空"
    read -erp "请输入 Provider 名称: " provider_name
  done

  read -erp "请输入 Base URL (如: https://api.xxx.com/v1): " base_url
  while [[ -z "${base_url:-}" ]]; do
    echo "❌ Base URL 不能为空"
    read -erp "请输入 Base URL: " base_url
  done
  base_url="${base_url%/}"

  read -rsp "请输入 API Key (输入不显示): " api_key
  echo
  while [[ -z "${api_key:-}" ]]; do
    echo "❌ API Key 不能为空"
    read -rsp "请输入 API Key: " api_key
    echo
  done

  echo "请选择 API 类型："
  echo "1) openai-completions"
  echo "2) openai-responses"
  read -erp "输入 1/2 (默认 1): " proto_choice
  local api_type="openai-completions"
  [[ "$proto_choice" == "2" ]] && api_type="openai-responses"

  echo "🔍 正在获取可用模型列表..."
  local available_models
  if ! available_models=$(fetch_models_ids "$base_url" "$api_key" | sort); then
    echo "❌ 拉取 /models 失败，请检查 baseUrl / apiKey"
    break_end
    return
  fi

  if [[ -z "$available_models" ]]; then
    echo "❌ /models 返回为空，无法继续"
    break_end
    return
  fi

  local i=1
  local model_list=()
  echo "--------------------------------"
  while IFS= read -r model; do
    [[ -z "$model" ]] && continue
    echo "[$i] $model"
    model_list+=("$model")
    ((i++))
  done <<< "$available_models"
  echo "--------------------------------"

  read -erp "请输入默认 Model ID (或序号，留空=第一个): " input_model
  local default_model=""
  if [[ -z "$input_model" ]]; then
    default_model="${model_list[0]}"
  elif [[ "$input_model" =~ ^[0-9]+$ ]] && (( input_model>=1 && input_model<=${#model_list[@]} )); then
    default_model="${model_list[$((input_model-1))]}"
  else
    default_model="$input_model"
  fi

  if [[ -z "$default_model" ]]; then
    echo "❌ 默认模型不能为空"
    break_end
    return
  fi

  echo
  echo "====== 确认信息 ======"
  echo "Provider    : $provider_name"
  echo "Base URL    : $base_url"
  echo "API 类型    : $api_type"
  echo "API Key     : ${api_key:0:8}****"
  echo "默认模型    : $default_model"
  echo "模型总数    : ${#model_list[@]}"
  echo "======================"

  read -erp "是否同时添加其他所有模型？(y/N): " confirm

  local model_ids_to_write=""
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    model_ids_to_write="$available_models"
  else
    model_ids_to_write="$default_model"
  fi

  if ! write_provider_models_from_ids "$provider_name" "$base_url" "$api_key" "$api_type" <<< "$model_ids_to_write"; then
    echo "❌ 写入配置失败"
    break_end
    return
  fi

  if command -v openclaw >/dev/null 2>&1; then
    openclaw models set "$provider_name/$default_model" >/dev/null 2>&1 || true
  fi

  start_gateway
  echo "✅ 完成。默认模型：$provider_name/$default_model"
  break_end
}

sync_openclaw_provider_interactive() {
  ensure_config || { break_end; return; }

  read -erp "请输入要同步的 provider 名称: " provider_name
  if [[ -z "${provider_name:-}" ]]; then
    echo "❌ provider 名称不能为空"
    break_end
    return
  fi

  python3 - "$CONFIG_FILE" "$provider_name" <<'PY'
import copy
import json
import sys
import time
import urllib.request

path = sys.argv[1]
target = sys.argv[2]
SUPPORTED_APIS = {'openai-completions', 'openai-responses'}

with open(path, 'r', encoding='utf-8') as f:
    obj = json.load(f)

work = copy.deepcopy(obj)
models_cfg = work.setdefault('models', {})
providers = models_cfg.get('providers', {})
if not isinstance(providers, dict) or not providers:
    print('❌ 未检测到 API providers，无法同步')
    raise SystemExit(2)

provider = providers.get(target)
if not isinstance(provider, dict):
    print(f'❌ 未找到 provider: {target}')
    raise SystemExit(2)

agents = work.setdefault('agents', {})
defaults = agents.setdefault('defaults', {})
defaults_models_raw = defaults.get('models')
if isinstance(defaults_models_raw, dict):
    defaults_models = defaults_models_raw
elif isinstance(defaults_models_raw, list):
    defaults_models = {str(x): {} for x in defaults_models_raw if isinstance(x, str)}
else:
    defaults_models = {}
defaults['models'] = defaults_models


def model_ref(provider_name, model_id):
    return f"{provider_name}/{model_id}"


def get_primary_ref(defaults_obj):
    model_obj = defaults_obj.get('model')
    if isinstance(model_obj, str):
        return model_obj
    if isinstance(model_obj, dict):
        primary = model_obj.get('primary')
        if isinstance(primary, str):
            return primary
    return None


def set_primary_ref(defaults_obj, new_ref):
    model_obj = defaults_obj.get('model')
    if isinstance(model_obj, str):
        defaults_obj['model'] = new_ref
    elif isinstance(model_obj, dict):
        model_obj['primary'] = new_ref
    else:
        defaults_obj['model'] = {'primary': new_ref}


def fetch_remote_models_with_retry(base_url, api_key, retries=3):
    last_error = None
    for attempt in range(1, retries + 1):
        req = urllib.request.Request(
            base_url.rstrip('/') + '/models',
            headers={
                'Authorization': f'Bearer {api_key}',
                'User-Agent': 'OpenClaw-API-Manage/Standalone',
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=12) as resp:
                payload = resp.read().decode('utf-8', 'ignore')
            return json.loads(payload), None, attempt
        except Exception as e:
            last_error = e
            if attempt < retries:
                time.sleep(1)
    return None, last_error, retries

api = provider.get('api', '')
base_url = provider.get('baseUrl')
api_key = provider.get('apiKey')
model_list = provider.get('models', [])

if not base_url or not api_key or not isinstance(model_list, list) or not model_list:
    print(f'❌ provider {target} 缺少 baseUrl/apiKey/models，无法执行同步')
    raise SystemExit(3)

if api not in SUPPORTED_APIS:
    print(f'ℹ️ provider {target} 当前 api={api}，建议设置为 openai-completions 或 openai-responses')

data, err, attempts = fetch_remote_models_with_retry(base_url, api_key, retries=3)
if err is not None:
    print(f'❌ {target}: /models 探测失败，已重试 {attempts} 次 ({type(err).__name__}: {err})')
    raise SystemExit(4)

if not (isinstance(data, dict) and isinstance(data.get('data'), list)):
    print(f'❌ {target}: /models 返回结构不可识别')
    raise SystemExit(4)

remote_ids = []
for item in data['data']:
    if isinstance(item, dict) and item.get('id'):
        remote_ids.append(str(item['id']))
remote_set = set(remote_ids)
if not remote_set:
    print(f'❌ {target}: 上游 /models 为空，已中止同步')
    raise SystemExit(5)

local_models = [m for m in model_list if isinstance(m, dict) and m.get('id')]
local_ids = [str(m['id']) for m in local_models]
local_set = set(local_ids)

template = copy.deepcopy(local_models[0]) if local_models else None
if template is None:
    print(f'❌ {target}: 本地 models 无有效模板模型，无法补全新增模型')
    raise SystemExit(3)

removed_ids = [mid for mid in local_ids if mid not in remote_set]
added_ids = [mid for mid in remote_ids if mid not in local_set]

kept_models = [copy.deepcopy(m) for m in local_models if str(m['id']) in remote_set]
new_models = kept_models[:]
for mid in added_ids:
    nm = copy.deepcopy(template)
    nm['id'] = mid
    if isinstance(nm.get('name'), str):
        nm['name'] = f'{target} / {mid}'
    new_models.append(nm)

if not new_models:
    print(f'❌ {target}: 同步后无可用模型，已中止写入')
    raise SystemExit(5)

expected_refs = {model_ref(target, str(m['id'])) for m in new_models if isinstance(m, dict) and m.get('id')}
local_refs = {model_ref(target, mid) for mid in local_ids}
removed_refs = local_refs - expected_refs
first_ref = model_ref(target, str(new_models[0]['id']))

changed = False
primary_ref = get_primary_ref(defaults)
if isinstance(primary_ref, str) and primary_ref in removed_refs:
    set_primary_ref(defaults, first_ref)
    changed = True
    print(f'🔁 默认模型已兜底替换: {primary_ref} -> {first_ref}')

for fk in ('modelFallback', 'imageModelFallback'):
    val = defaults.get(fk)
    if isinstance(val, str) and val in removed_refs:
        defaults[fk] = first_ref
        changed = True
        print(f'🔁 {fk} 已兜底替换: {val} -> {first_ref}')

stale_refs = [r for r in list(defaults_models.keys()) if r.startswith(target + '/') and r not in expected_refs]
for r in stale_refs:
    defaults_models.pop(r, None)
    changed = True

for r in sorted(expected_refs):
    if r not in defaults_models:
        defaults_models[r] = {}
        changed = True

if removed_ids or added_ids or len(local_models) != len(new_models):
    provider['models'] = new_models
    changed = True

if changed:
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(work, f, ensure_ascii=False, indent=2)
        f.write('\n')

print(f'✅ {target}: 新增 {len(added_ids)} 个，删除 {len(removed_ids)} 个，当前 {len(new_models)} 个')

if added_ids:
    print(f'➕ 新增模型({len(added_ids)}):')
    for mid in added_ids:
        print(f'  + {mid}')
if removed_ids:
    print(f'➖ 删除模型({len(removed_ids)}):')
    for mid in removed_ids:
        print(f'  - {mid}')

if changed:
    print('✅ 指定 provider 模型一致性同步完成并已写入配置')
else:
    print('ℹ️ 无需同步：该 provider 配置已与上游 /models 保持一致')
PY

  local rc=$?
  case "$rc" in
    0) start_gateway ;;
    2) echo "❌ 同步失败：provider 不存在或未配置" ;;
    3) echo "❌ 同步失败：provider 配置不完整" ;;
    4) echo "❌ 同步失败：上游 /models 请求失败" ;;
    5) echo "❌ 同步失败：上游模型为空或同步后无可用模型" ;;
    *) echo "❌ 同步失败：请检查日志输出" ;;
  esac

  break_end
}

fix_openclaw_provider_protocol_interactive() {
  ensure_config || { break_end; return; }

  read -erp "请输入要切换协议的 provider 名称: " provider_name
  if [[ -z "${provider_name:-}" ]]; then
    echo "❌ provider 名称不能为空"
    break_end
    return
  fi

  echo "请选择要设置的 API 类型："
  echo "1. openai-completions"
  echo "2. openai-responses"
  read -erp "请输入你的选择 (1/2): " proto_choice

  local new_api=""
  case "$proto_choice" in
    1) new_api="openai-completions" ;;
    2) new_api="openai-responses" ;;
    *)
      echo "❌ 无效选择"
      break_end
      return
      ;;
  esac

  python3 - "$CONFIG_FILE" "$provider_name" "$new_api" <<'PY'
import copy
import json
import sys

path = sys.argv[1]
name = sys.argv[2]
new_api = sys.argv[3]

SUPPORTED_APIS = {'openai-completions', 'openai-responses'}
if new_api not in SUPPORTED_APIS:
    print('❌ 非法协议值')
    raise SystemExit(3)

with open(path, 'r', encoding='utf-8') as f:
    obj = json.load(f)

work = copy.deepcopy(obj)
providers = ((work.get('models') or {}).get('providers') or {})
if not isinstance(providers, dict) or name not in providers or not isinstance(providers.get(name), dict):
    print(f'❌ 未找到 provider: {name}')
    raise SystemExit(2)

providers[name]['api'] = new_api

with open(path, 'w', encoding='utf-8') as f:
    json.dump(work, f, ensure_ascii=False, indent=2)
    f.write('\n')

print(f'✅ 已更新 provider {name} 协议为: {new_api}')
PY

  local rc=$?
  case "$rc" in
    0) start_gateway ;;
    2) echo "❌ 切换失败：provider 不存在或未配置" ;;
    3) echo "❌ 切换失败：协议值非法" ;;
    *) echo "❌ 切换失败：请检查配置文件结构或日志输出" ;;
  esac

  break_end
}

delete_openclaw_provider_interactive() {
  ensure_config || { break_end; return; }

  read -erp "请输入要删除的 provider 名称: " provider_name
  if [[ -z "${provider_name:-}" ]]; then
    echo "❌ provider 名称不能为空"
    break_end
    return
  fi

  python3 - "$CONFIG_FILE" "$provider_name" <<'PY'
import copy
import json
import sys

path = sys.argv[1]
name = sys.argv[2]

with open(path, 'r', encoding='utf-8') as f:
    obj = json.load(f)

work = copy.deepcopy(obj)
models_cfg = work.setdefault('models', {})
providers = models_cfg.get('providers', {})
if not isinstance(providers, dict) or name not in providers:
    print(f'❌ 未找到 provider: {name}')
    raise SystemExit(2)

agents = work.setdefault('agents', {})
defaults = agents.setdefault('defaults', {})
defaults_models_raw = defaults.get('models')
if isinstance(defaults_models_raw, dict):
    defaults_models = defaults_models_raw
elif isinstance(defaults_models_raw, list):
    defaults_models = {str(x): {} for x in defaults_models_raw if isinstance(x, str)}
else:
    defaults_models = {}
defaults['models'] = defaults_models


def model_ref(provider_name, model_id):
    return f"{provider_name}/{model_id}"


def ref_provider(ref):
    if not isinstance(ref, str) or '/' not in ref:
        return None
    return ref.split('/', 1)[0]


def get_primary_ref(defaults_obj):
    model_obj = defaults_obj.get('model')
    if isinstance(model_obj, str):
        return model_obj
    if isinstance(model_obj, dict):
        primary = model_obj.get('primary')
        if isinstance(primary, str):
            return primary
    return None


def set_primary_ref(defaults_obj, new_ref):
    model_obj = defaults_obj.get('model')
    if isinstance(model_obj, str):
        defaults_obj['model'] = new_ref
    elif isinstance(model_obj, dict):
        model_obj['primary'] = new_ref
    else:
        defaults_obj['model'] = {'primary': new_ref}


def collect_available_refs(exclude_provider=None):
    refs = []
    if not isinstance(providers, dict):
        return refs
    for pname, p in providers.items():
        if exclude_provider and pname == exclude_provider:
            continue
        if not isinstance(p, dict):
            continue
        for m in p.get('models', []) or []:
            if isinstance(m, dict) and m.get('id'):
                refs.append(model_ref(pname, str(m['id'])))
    return refs


replacement_candidates = collect_available_refs(exclude_provider=name)
replacement = replacement_candidates[0] if replacement_candidates else None

primary_ref = get_primary_ref(defaults)
if ref_provider(primary_ref) == name:
    if not replacement:
        print('❌ 删除中止：默认主模型指向该 provider，且无可用替代模型')
        raise SystemExit(3)
    set_primary_ref(defaults, replacement)
    print(f'🔁 默认主模型切换: {primary_ref} -> {replacement}')

for fk in ('modelFallback', 'imageModelFallback'):
    val = defaults.get(fk)
    if ref_provider(val) == name:
        if not replacement:
            print(f'❌ 删除中止：{fk} 指向该 provider，且无可用替代模型')
            raise SystemExit(3)
        defaults[fk] = replacement
        print(f'🔁 {fk} 切换: {val} -> {replacement}')

removed_refs = [r for r in list(defaults_models.keys()) if r.startswith(name + '/')]
for r in removed_refs:
    defaults_models.pop(r, None)

providers.pop(name, None)

with open(path, 'w', encoding='utf-8') as f:
    json.dump(work, f, ensure_ascii=False, indent=2)
    f.write('\n')

print(f'🗑️ 已删除 provider: {name}')
print(f'🧹 已清理 defaults.models 中 {len(removed_refs)} 个关联模型引用')
PY

  local rc=$?
  case "$rc" in
    0)
      echo "✅ 删除完成"
      start_gateway
      ;;
    2) echo "❌ 删除失败：provider 不存在" ;;
    3) echo "❌ 删除失败：无可用替代模型，已保持原配置" ;;
    *) echo "❌ 删除失败：请检查配置文件结构或日志输出" ;;
  esac

  break_end
}

show_menu() {
  clear
  echo "======================================="
  echo "🦞 OpenClaw API 管理（独立版）"
  echo "======================================="
  openclaw_api_manage_list
  echo "---------------------------------------"
  echo "1. 添加API"
  echo "2. 同步API供应商模型列表"
  echo "3. 切换 API 类型（completions / responses）"
  echo "4. 删除API"
  echo "0. 退出"
  echo "---------------------------------------"
  read -erp "请输入你的选择: " api_choice
}

main() {
  ensure_deps

  while true; do
    show_menu
    case "${api_choice:-}" in
      1) add_openclaw_provider_interactive ;;
      2) sync_openclaw_provider_interactive ;;
      3) fix_openclaw_provider_protocol_interactive ;;
      4) delete_openclaw_provider_interactive ;;
      0) echo "已退出。"; exit 0 ;;
      *) echo "无效的选择，请重试。"; sleep 1 ;;
    esac
  done
}

main "$@"
