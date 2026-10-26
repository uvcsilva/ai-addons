# shellcheck shell=bash
# Leitura do addons.json para os instaladores. Carregue com source; os valores ficam em
# CONFIG["escopo.chave"], com escopo root, options, bootstrap ou o nome do addon.
# Valores chegam por NUL, sem eval: listas viram texto com virgulas, objetos viram JSON
# e booleanos viram true/false. Chave ausente ou null = padrao do consumidor.

((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))) \
  || { printf 'Use Bash 4.4 ou superior no Ubuntu.\n' >&2; exit 2; }
command -v python3 >/dev/null 2>&1 \
  || { printf 'python3 e necessario para ler o JSON. Instale com: sudo apt-get install -y python3\n' >&2; exit 2; }

declare -gA CONFIG=()

config_parse() {
  trap - ERR
  python3 - "$1" <<'PY'
import json, os, sys

path = sys.argv[1]
TOP_KEYS = {"$schema", "clients", "options", "bootstrap", "addons"}
CLIENTS = ["claude", "codex", "cline", "opencode", "copilot", "vscode", "antigravity"]
OPTION_KEYS = {"cline-config", "vscode-user-dir", "opencode-major", "project-dir"}
BOOTSTRAP_KEYS = {"enabled", "clients", "upgrade", "with-opencode"}
ADDON_KEYS = {
    "engram": {"tools"},
    "serena": {"with-go", "check-go-project", "language-backend", "agent-interface",
               "enable-web-dashboard", "open-web-dashboard", "log-level", "tool-timeout",
               "modes", "ls-dependencies"},
    "context7": {"api-key-from-env"},
    "rtk": {"init-mode", "trust-filters", "telemetry", "recall", "awareness",
            "exclude-commands", "tracking", "history-days"},
    "ccusage": {"settings"},
    "ponytail": {"mode", "quiet-startup", "hide-status"},
    "graphify": set(),
}
ALL_ADDONS = "todos os addons sao instalados em cada provedor"

def fail(message):
    raise SystemExit(f"{path}: {message}")

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail(f"chave duplicada: {key}")
        result[key] = value
    return result

if path:
    try:
        with open(path, encoding="utf-8-sig") as f:
            config = json.load(f, object_pairs_hook=unique_object)
    except (OSError, ValueError) as exc:
        fail(f"JSON invalido: {exc}")
else:
    config = {}
if not isinstance(config, dict):
    fail("a raiz precisa ser um objeto")
unknown = set(config) - TOP_KEYS
if unknown:
    fail(f"chaves desconhecidas na raiz: {', '.join(sorted(unknown))}")

def clients_value(value, where):
    if isinstance(value, list) and value and all(isinstance(c, str) and c for c in value):
        value = ",".join(value)
    elif not (isinstance(value, str) and value):
        fail(f"{where}.clients precisa ser texto ou lista de textos, nao vazio")
    if value == "all":
        return ",".join(CLIENTS)
    for client in value.split(","):
        if client == "openrouter":
            fail("OpenRouter e provedor: use clients cline/opencode e escolha OpenRouter no cliente")
        if client not in CLIENTS:
            fail(f"{where}.clients: cliente desconhecido ou lista invalida: {client or '(vazio)'}")
    return value

def scalar(value, where):
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return None
    if isinstance(value, list):
        # Listas viram texto separado por virgulas, como nas opcoes dos scripts.
        if not all(isinstance(v, str) and v and "," not in v for v in value):
            fail(f"{where}: lista precisa conter textos sem virgula")
        return ",".join(value) or None
    if isinstance(value, dict):
        return json.dumps(value, ensure_ascii=False) if value else None
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        if not value or "\0" in value or "\n" in value:
            fail(f"{where}: valor vazio ou com quebra de linha")
        return os.path.expanduser(value) if value == "~" or value.startswith("~/") else value
    fail(f"{where}: use texto, numero, booleano, lista, objeto ou null")

items = []
def emit(scope, key, value):
    if value is not None:
        items.extend((scope, key, value))

if "clients" in config:
    emit("root", "clients", clients_value(config["clients"], "raiz"))

options = config.get("options", {})
if not isinstance(options, dict):
    fail("options precisa ser objeto")
if "clients" in options:
    fail("use clients na raiz, nao em options")
unknown = set(options) - OPTION_KEYS
if unknown:
    fail(f"options aceita somente {', '.join(sorted(OPTION_KEYS))}; recebido: {', '.join(sorted(unknown))}")
for key, value in options.items():
    emit("options", key, scalar(value, f"options.{key}"))

bootstrap = config.get("bootstrap", True)
if isinstance(bootstrap, bool):
    bootstrap = {"enabled": bootstrap}
if not isinstance(bootstrap, dict):
    fail("bootstrap precisa ser objeto ou booleano")
unknown = set(bootstrap) - BOOTSTRAP_KEYS
if unknown:
    fail(f"bootstrap aceita somente {', '.join(sorted(BOOTSTRAP_KEYS))}; recebido: {', '.join(sorted(unknown))}")
if not isinstance(bootstrap.get("enabled", True), bool):
    fail("bootstrap.enabled precisa ser booleano")
for key, value in bootstrap.items():
    emit("bootstrap", key, clients_value(value, "bootstrap") if key == "clients" else scalar(value, f"bootstrap.{key}"))

addons = config.get("addons", {})
if not isinstance(addons, dict):
    fail("addons precisa ser objeto")
unknown = set(addons) - set(ADDON_KEYS)
if unknown:
    fail(f"addons desconhecidos: {', '.join(sorted(unknown))}")
checked = {}
for name, addon in addons.items():
    where = f"addons.{name}"
    if addon is True:
        addon = {}
    if addon is False or (isinstance(addon, dict) and addon.get("enabled", True) is False):
        fail(f"{where}: {ALL_ADDONS}; remova o false")
    if not isinstance(addon, dict):
        fail(f"{where} precisa ser objeto ou true")
    if not isinstance(addon.get("enabled", True), bool):
        fail(f"{where}.enabled precisa ser booleano")
    if "clients" in addon:
        fail(f"{where}.clients: {ALL_ADDONS}; remova clients")
    unknown = set(addon) - ADDON_KEYS[name] - OPTION_KEYS - {"enabled"}
    if unknown:
        fail(f"{where}: opcoes desconhecidas: {', '.join(sorted(unknown))}")
    for key, value in addon.items():
        if key != "enabled":
            emit(name, key, scalar(value, f"{where}.{key}"))
    checked[name] = addon
# Uma opcao de caminho no addon prevalece sobre a mesma opcao em options.
for name in ADDON_KEYS:
    for key in OPTION_KEYS:
        if key in options and key not in checked.get(name, {}):
            emit(name, key, scalar(options[key], f"options.{key}"))

if items:
    sys.stdout.write("\0".join(items) + "\0")
PY
}

# Uso: config_load [ARQUIVO]. Sem arquivo, usa os padroes; arquivo informado precisa existir.
config_load() {
  local file="${1:-}" i
  local -a items=()
  [[ -z "$file" || -f "$file" ]] || { printf 'Arquivo de configuracao nao encontrado: %s\n' "$file" >&2; exit 2; }
  mapfile -d '' -t items < <(config_parse "$file")
  wait "$!" || { printf 'Configuracao invalida: %s\n' "${file:-padrao}" >&2; exit 2; }
  CONFIG=()
  for ((i = 0; i + 2 < ${#items[@]}; i += 3)); do
    CONFIG["${items[i]}.${items[i+1]}"]="${items[i+2]}"
  done
}

# Uso: config_opt ESCOPO CHAVE [PADRAO]. ESCOPO e um addon, options ou bootstrap.
config_opt() {
  local key="$1.$2"
  if [[ -n "${CONFIG[$key]+x}" ]]; then printf '%s' "${CONFIG[$key]}"; else printf '%s' "${3:-}"; fi
}

config_option() { config_opt options "$1" "${2:-}"; }

# Clientes da raiz, ja expandidos (all) e validados; padrao claude,codex.
# config_opt root clients (sem padrao) diz se a chave estava no arquivo.
config_clients() { config_opt root clients claude,codex; }
