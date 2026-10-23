#!/usr/bin/env bash
# Arquivo independente: nao precisa de biblioteca nem dos outros instaladores.
# Fontes oficiais e limites de validacao estao no README.md do pacote.
set -Eeuo pipefail
umask 077

ADDON="serena"
SCRIPT_NAME="${0##*/}"
HOME_DIR="${HOME:?HOME precisa estar definido}"
LOCAL_BIN="$HOME_DIR/.local/bin"
ORIGINAL_PATH="$PATH"
STATE_ROOT="${XDG_STATE_HOME:-$HOME_DIR/.local/state}/six-addons-installer"
TMP_WORKDIR=""
LOG_FILE=""
BACKUP_DIR=""

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME_DIR/.claude}"
CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_JSON="${CLAUDE_CONFIG_DIR:-$HOME_DIR}/.claude.json"
CODEX_DIR="${CODEX_HOME:-$HOME_DIR/.codex}"
CODEX_CONFIG="$CODEX_DIR/config.toml"
CLIENTS="claude,codex"
PROJECT_DIR=""
WITH_GO=0
CHECK_GO_PROJECT=""
SERENA_BACKEND=""
SERENA_INTERFACE=""
SERENA_DASHBOARD=""
SERENA_OPEN_DASHBOARD=""
SERENA_LOG_LEVEL=""
SERENA_TOOL_TIMEOUT=""
SERENA_MODES=""
SERENA_LS_DEPS=""
SERENA_EXTRA=()
CLINE_CONFIG="${CLINE_MCP_SETTINGS_PATH:-$HOME_DIR/.cline/data/settings/cline_mcp_settings.json}"
OPENCODE_DIR="${XDG_CONFIG_HOME:-$HOME_DIR/.config}/opencode"
OC_CONFIG_FILE=""
OPENCODE_MAJOR=""
COPILOT_DIR="${COPILOT_HOME:-$HOME_DIR/.copilot}"
VSCODE_USER_DIR="${XDG_CONFIG_HOME:-$HOME_DIR/.config}/Code/User"
selected() { [[ ",$CLIENTS," == *",$1,"* ]]; }


usage() {
  cat <<EOF
Uso: $SCRIPT_NAME [opcoes]

Instala e configura somente Serena no escopo do usuario do Ubuntu.
Integra somente os clientes selecionados. Consulte a matriz de compatibilidade no README.

  --dry-run  Mostra o plano, sem rede, arquivos, logs ou alteracoes.
  --help     Mostra esta ajuda.
  --with-go  Prepara Go e gopls para projetos Go (preserva instalacoes existentes).
  --check-go-project DIR  Testa o LSP lendo simbolos de um projeto Go existente.
  --clients LISTA  claude,codex,cline,opencode,copilot,vscode ou all.
                   Padrao: claude,codex. copilot = CLI; vscode = Copilot VS Code.
  --cline-config ARQUIVO  MCP do Cline CLI ou extensao (caminho absoluto).
  --vscode-user-dir DIR   Pasta User do perfil VS Code no Ubuntu.
  --opencode-major 1|2    Schema instalado; senao detecta opencode --version.
  --project-dir DIR      Projeto fixo do Serena nos novos clientes (opcional).
  --language-backend LSP|JetBrains  Backend de analise de codigo.
  --agent-interface tools|REPL      Uma ferramenta por operacao ou serena_repl.
  --enable-web-dashboard true|false Dashboard web do Serena.
  --open-web-dashboard true|false   Abrir o dashboard no navegador ao iniciar.
  --log-level NIVEL      DEBUG, INFO, WARNING, ERROR ou CRITICAL.
  --tool-timeout SEG     Tempo limite das ferramentas, em segundos.
  --modes LISTA          Modos extras (ex.: planning,editing), alem de no-memories.
  --ls-dependencies LISTA  Pre-baixa language servers (ex.: python,typescript).
                         Sem estas opcoes, valem os padroes do Serena.
OpenRouter: selecione cline/opencode e configure o provedor no proprio cliente.
RTK/Ponytail nos novos clientes: regras, sem hooks nem comandos de plugin.

Pre-requisitos: curl, python3, sha256sum, flock.
Nao usa sudo. Requer apenas os clientes selecionados; veja limites no README.
Baixa uv estavel com SHA-256; instala/atualiza serena-agent com Python 3.13 via uv.
Backup e log privados: \${XDG_STATE_HOME:-~/.local/state}/six-addons-installer.
Os seis scripts compartilham um bloqueio; execute um de cada vez.
Conflitos existentes sao informados, sem sobrescrever entradas MCP diferentes.
EOF
}

die() {
  printf '\n[ERRO] %s\n' "$*" >&2
  [[ -z "$LOG_FILE" ]] || printf '[ERRO] Log: %s\n' "$LOG_FILE" >&2
  [[ -z "$BACKUP_DIR" ]] || printf '[ERRO] Backup: %s\n' "$BACKUP_DIR" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TMP_WORKDIR" && -d "$TMP_WORKDIR" ]]; then
    rm -rf -- "$TMP_WORKDIR"
  fi
}

on_error() {
  local rc=$1 line=$2
  printf '\n[FALHA] %s: linha %s, codigo %s.\n' "$ADDON" "$line" "$rc" >&2
  [[ -z "$LOG_FILE" ]] || printf '[FALHA] Log: %s\n' "$LOG_FILE" >&2
  [[ -z "$BACKUP_DIR" ]] || printf '[FALHA] Backup: %s\n' "$BACKUP_DIR" >&2
  exit "$rc"
}
trap cleanup EXIT
trap 'on_error "$?" "$LINENO"' ERR

DRY_RUN=0
while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --with-go) WITH_GO=1; shift ;;
    --clients|--cline-config|--vscode-user-dir|--opencode-major|--project-dir|--check-go-project|--language-backend|--agent-interface|--enable-web-dashboard|--open-web-dashboard|--log-level|--tool-timeout|--modes|--ls-dependencies)
      (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || { printf 'Falta valor para %s\n' "$1" >&2; exit 2; }
      case "$1" in
        --clients) CLIENTS="$2" ;;
        --language-backend) SERENA_BACKEND="$2" ;;
        --agent-interface) SERENA_INTERFACE="$2" ;;
        --enable-web-dashboard) SERENA_DASHBOARD="$2" ;;
        --open-web-dashboard) SERENA_OPEN_DASHBOARD="$2" ;;
        --log-level) SERENA_LOG_LEVEL="$2" ;;
        --tool-timeout) SERENA_TOOL_TIMEOUT="$2" ;;
        --modes) SERENA_MODES="$2" ;;
        --ls-dependencies) SERENA_LS_DEPS="$2" ;;
        --cline-config) CLINE_CONFIG="$2" ;;
        --vscode-user-dir) VSCODE_USER_DIR="$2" ;;
        --opencode-major) OPENCODE_MAJOR="$2" ;;
        --project-dir) PROJECT_DIR="$2" ;;
        --check-go-project) CHECK_GO_PROJECT="$2" ;;
      esac
      shift 2 ;;
    *) printf 'Opcao desconhecida: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[[ "$CLIENTS" != all ]] || CLIENTS='claude,codex,cline,opencode,copilot,vscode'
[[ -n "$CLIENTS" && "$CLIENTS" != ,* && "$CLIENTS" != *, && "$CLIENTS" != *,,* ]] || { printf 'Lista de clientes invalida\n' >&2; exit 2; }
IFS=, read -r -a CLIENT_LIST <<< "$CLIENTS"
for client in "${CLIENT_LIST[@]}"; do
  case "$client" in
    claude|codex|cline|opencode|copilot|vscode) ;;
    openrouter) printf 'OpenRouter e provedor: use --clients cline,opencode e escolha OpenRouter no cliente.\n' >&2; exit 2 ;;
    *) printf 'Cliente desconhecido: %s\n' "$client" >&2; exit 2 ;;
  esac
done
case "$OPENCODE_MAJOR" in ''|1|2) ;; *) printf 'Use --opencode-major 1 ou 2\n' >&2; exit 2 ;; esac
# Opcoes repassadas ao start-mcp-server oficial em todos os clientes.
case "$SERENA_BACKEND" in ''|LSP|JetBrains) ;; *) printf 'Use --language-backend LSP ou JetBrains\n' >&2; exit 2 ;; esac
case "$SERENA_INTERFACE" in ''|tools|REPL) ;; *) printf 'Use --agent-interface tools ou REPL\n' >&2; exit 2 ;; esac
for value in "$SERENA_DASHBOARD" "$SERENA_OPEN_DASHBOARD"; do
  case "$value" in ''|true|false) ;; *) printf 'Use true ou false nas opcoes de dashboard\n' >&2; exit 2 ;; esac
done
case "$SERENA_LOG_LEVEL" in ''|DEBUG|INFO|WARNING|ERROR|CRITICAL) ;; *) printf 'Use --log-level DEBUG, INFO, WARNING, ERROR ou CRITICAL\n' >&2; exit 2 ;; esac
[[ -z "$SERENA_TOOL_TIMEOUT" || "$SERENA_TOOL_TIMEOUT" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { printf 'Use --tool-timeout em segundos\n' >&2; exit 2; }
for value in "$SERENA_MODES" "$SERENA_LS_DEPS"; do
  [[ -z "$value" || "$value" =~ ^[A-Za-z0-9_-]+(,[A-Za-z0-9_-]+)*$ ]] || { printf 'Use listas separadas por virgulas em --modes/--ls-dependencies\n' >&2; exit 2; }
done
[[ ",$SERENA_MODES," != *",no-memories,"* ]] || { printf 'no-memories ja e sempre aplicado; remova-o de --modes\n' >&2; exit 2; }
[[ -z "$SERENA_BACKEND" ]] || SERENA_EXTRA+=(--language-backend "$SERENA_BACKEND")
[[ -z "$SERENA_INTERFACE" ]] || SERENA_EXTRA+=(--agent-interface "$SERENA_INTERFACE")
[[ -z "$SERENA_DASHBOARD" ]] || SERENA_EXTRA+=(--enable-web-dashboard "$SERENA_DASHBOARD")
[[ -z "$SERENA_OPEN_DASHBOARD" ]] || SERENA_EXTRA+=(--open-web-dashboard "$SERENA_OPEN_DASHBOARD")
[[ -z "$SERENA_LOG_LEVEL" ]] || SERENA_EXTRA+=(--log-level "$SERENA_LOG_LEVEL")
[[ -z "$SERENA_TOOL_TIMEOUT" ]] || SERENA_EXTRA+=(--tool-timeout "$SERENA_TOOL_TIMEOUT")
if [[ -n "$SERENA_MODES" ]]; then
  IFS=, read -r -a serena_modes <<< "$SERENA_MODES"
  for mode in "${serena_modes[@]}"; do SERENA_EXTRA+=(--add-mode "$mode"); done
fi
for path in "$CLINE_CONFIG" "$VSCODE_USER_DIR" "$OPENCODE_DIR" "$COPILOT_DIR" "${PROJECT_DIR:-/}" "${CHECK_GO_PROJECT:-/}"; do
  [[ "$path" == /* && "$path" != *$'\n'* ]] || { printf 'Caminho precisa ser absoluto, sem quebra de linha: %s\n' "$path" >&2; exit 2; }
done
if [[ "$DRY_RUN" == 1 ]]; then
  cat <<EOF
Simulacao de Serena: sem alteracoes e sem acesso a rede.
  Clientes: $CLIENTS
  Cline MCP: $CLINE_CONFIG
  OpenCode: $OPENCODE_DIR (major: ${OPENCODE_MAJOR:-detectar})
  Copilot CLI: $COPILOT_DIR
  VS Code User: $VSCODE_USER_DIR
  Serena projeto novos clientes: ${PROJECT_DIR:-OpenCode ativa por cwd; Cline/VS Code ativam na sessao}
  • Exigir Ubuntu, usuario sem sudo e: curl, python3, sha256sum, flock.
  • Instalar uv/uvx e Serena isolado com Python 3.13.
  • Registrar MCP com contexto de cada cliente e --add-mode no-memories.
  • Claude: garantir env.MCP_TIMEOUT >= 60000 no settings.json (partida a frio do uv).
  • Opcoes extras do MCP: ${SERENA_EXTRA[*]:-nenhuma}; language servers pre-baixados: ${SERENA_LS_DEPS:-nenhum}.
  • Bloquear execucao simultanea dos seis instaladores.
  • Fazer backup antes de alterar configuracoes e criar log privado.
  • Conferir Serena depois da instalacao.
  • Preparar Go/gopls: $WITH_GO; teste Go: ${CHECK_GO_PROJECT:-nao solicitado}.
  • Registrar instrucoes de uso do Serena em todos os clientes selecionados.
Somente este addon sera instalado; uv/Python e Go/gopls opcionais sao pre-requisitos.
EOF
  exit 0
fi

((BASH_VERSINFO[0] >= 4)) || die 'Use Bash 4 ou superior no Ubuntu.'
((EUID != 0)) || die 'Execute com seu usuario normal, sem sudo ou root.'
[[ -r /etc/os-release ]] || die 'Este instalador requer Ubuntu Linux.'
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == ubuntu && "$(uname -s)" == Linux ]] || die "Destino precisa ser Ubuntu Linux; detectado: ${PRETTY_NAME:-desconhecido}."
for path in "$HOME_DIR" "$STATE_ROOT" "${TMPDIR:-/tmp}" "$CLAUDE_DIR" "$CODEX_DIR"; do
  [[ "$path" == /* ]] || die "Diretorio precisa ser absoluto: $path"
done
case "$(uname -m)" in
  x86_64|amd64) UV_ASSET='uv-x86_64-unknown-linux-gnu.tar.gz' ;;
  aarch64|arm64) UV_ASSET='uv-aarch64-unknown-linux-gnu.tar.gz' ;;
  *) die "Arquitetura nao suportada: $(uname -m). Use x86_64 ou aarch64." ;;
esac

export PATH="$LOCAL_BIN:$PATH"
MISSING=()
for cmd in curl python3 sha256sum flock; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
if [[ "$ADDON" != ccusage ]]; then
  for client in claude codex; do
    if selected "$client"; then command -v "$client" >/dev/null 2>&1 || MISSING+=("$client"); fi
  done
fi
if ((${#MISSING[@]})); then
  die "Pre-requisitos ausentes: ${MISSING[*]}. Instale pelo gerenciador oficial do Ubuntu/fornecedor e reexecute."
fi

if selected opencode && [[ "$ADDON" != ccusage ]]; then
  [[ -z "${OPENCODE_CONFIG:-}" && -z "${OPENCODE_CONFIG_CONTENT:-}" && -z "${OPENCODE_CONFIG_DIR:-}" ]] || die 'Remova os overrides OPENCODE_CONFIG/CONTENT/DIR e execute para a configuracao global, ou adapte o destino manualmente.' 
  if [[ -z "$OPENCODE_MAJOR" ]]; then
    command -v opencode >/dev/null || die 'Instale OpenCode ou informe --opencode-major 1|2.'
    opencode_version="$(opencode --version)"
    case "$opencode_version" in 1.*|v1.*) OPENCODE_MAJOR=1 ;; 2.*|v2.*) OPENCODE_MAJOR=2 ;; *) die 'Versao OpenCode nao reconhecida: informe --opencode-major 1|2.' ;; esac
  fi
  [[ ! -e "$OPENCODE_DIR/opencode.json" || ! -e "$OPENCODE_DIR/opencode.jsonc" ]] || die 'Existem opencode.json e opencode.jsonc: consolide as configuracoes antes de prosseguir.'
  OC_CONFIG_FILE="$OPENCODE_DIR/opencode.json"
  [[ ! -e "$OPENCODE_DIR/opencode.jsonc" ]] || OC_CONFIG_FILE="$OPENCODE_DIR/opencode.jsonc"
  printf 'OpenCode %s: %s\n' "$OPENCODE_MAJOR" "$OC_CONFIG_FILE"

fi
[[ -z "$PROJECT_DIR" || -d "$PROJECT_DIR" ]] || die 'O projeto precisa ser um diretorio existente.'
mkdir -p "$LOCAL_BIN" "$STATE_ROOT/backups"
chmod 700 "$STATE_ROOT" "$STATE_ROOT/backups"
[[ ! -L "$STATE_ROOT/install.lock" ]] || die 'O arquivo de bloqueio nao pode ser link simbolico.'
[[ ! -e "$STATE_ROOT/install.lock" || -f "$STATE_ROOT/install.lock" ]] || die 'O arquivo de bloqueio precisa ser regular.'
exec 9>"$STATE_ROOT/install.lock"
flock -n 9 || die 'Outro instalador de addon esta em execucao. Aguarde e reexecute.'

RUN_ID="$ADDON-$(date -u +%Y%m%dT%H%M%SZ)-$$"
BACKUP_DIR="$STATE_ROOT/backups/$RUN_ID"
mkdir "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
LOG_FILE="$STATE_ROOT/install-$RUN_ID.log"
: > "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
TMP_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/addon-$ADDON.XXXXXXXX")"
chmod 700 "$TMP_WORKDIR"
# Executar CLIs fora de repositorios evita misturar configuracao de projeto.
cd "$TMP_WORKDIR"
printf 'Instalador de %s — Ubuntu %s\nUsuario: %s\nLog: %s\n' "$ADDON" "${VERSION_ID:-?}" "$HOME_DIR" "$LOG_FILE"
if [[ "$ADDON" != ccusage ]]; then
printf 'Clientes selecionados: %s\n' "$CLIENTS"
if selected claude; then claude --version; fi
if selected codex; then codex --version; fi
fi

backup_path() {
  local path="$1" safe destination
  [[ -e "$path" || -L "$path" ]] || return 0
  safe="$(printf '%s' "$path" | sed 's#/#_#g; s/[^A-Za-z0-9_.-]/_/g')"
  destination="$BACKUP_DIR/$safe"
  [[ ! -e "$destination" && ! -L "$destination" ]] || return 0
  cp -a --reflink=auto -- "$path" "$destination"
  printf 'Backup: %s -> %s\n' "$path" "$destination"
}

assert_regular_or_absent() {
  local path="$1"
  [[ ! -L "$path" ]] || die "Revise o link simbolico antes de prosseguir: $path"
  [[ ! -e "$path" || -f "$path" ]] || die "Caminho nao e arquivo regular: $path"
}

backup_plugins_dir() {
  local entry
  # cache/ and marketplaces/ are re-downloaded by the plugin CLIs; skip their bulk.
  for entry in "$1"/*; do
    case "${entry##*/}" in cache|marketplaces) ;; *) backup_path "$entry" ;; esac
  done
}

if [[ "$ADDON" != ccusage ]]; then

if selected claude; then
  for path in "$CLAUDE_SETTINGS" "$CLAUDE_JSON" "$CLAUDE_DIR/CLAUDE.md" "$CLAUDE_DIR/RTK.md" "$CLAUDE_DIR/hooks/rtk-rewrite.sh" "$CLAUDE_DIR/hooks/.rtk-hook.sha256"; do assert_regular_or_absent "$path"; backup_path "$path"; done
  backup_plugins_dir "$CLAUDE_DIR/plugins"
fi
if selected codex; then
  for path in "$CODEX_CONFIG" "$CODEX_DIR/hooks.json" "$CODEX_DIR/AGENTS.md" "$CODEX_DIR/RTK.md" "$CODEX_DIR/engram-instructions.md" "$CODEX_DIR/engram-compact-prompt.md"; do assert_regular_or_absent "$path"; backup_path "$path"; done
  backup_plugins_dir "$CODEX_DIR/plugins"
  backup_plugins_dir "$HOME_DIR/.agents/plugins"
fi

fi
assert_regular_or_absent "$LOCAL_BIN/uv"
backup_path "$LOCAL_BIN/uv"
assert_regular_or_absent "$LOCAL_BIN/uvx"
backup_path "$LOCAL_BIN/uvx"

# Resolve an official release asset and its GitHub API SHA-256 digest.
release_asset_metadata() {
  local repo="$1" asset="$2" api_json="$TMP_WORKDIR/release.json" auth=()
  # GITHUB_TOKEN opcional evita o limite anonimo da API; vai por arquivo, fora da linha de comando.
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" > "$TMP_WORKDIR/github-auth.header"
    auth=(-H "@$TMP_WORKDIR/github-auth.header")
  fi
  curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 \
    ${auth[@]+"${auth[@]}"} \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    -H 'User-Agent: six-addons-ubuntu-installer' \
    "https://api.github.com/repos/$repo/releases/latest" -o "$api_json"
  python3 - "$repo" "$asset" "$api_json" <<'PY'
import json, pathlib, sys, urllib.parse
repo, wanted, path = sys.argv[1:]
data = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
if data.get("draft") or data.get("prerelease"):
    raise SystemExit("GitHub API retornou release nao-estavel")
tag = data.get("tag_name", "")
if wanted.startswith("@engram-linux-"):
    arch = wanted.rsplit("-", 1)[1]
    version = tag[1:] if tag.startswith("v") else tag
    wanted = f"engram_{version}_linux_{arch}.tar.gz"
hits = [a for a in data.get("assets", []) if a.get("name") == wanted]
if len(hits) != 1:
    raise SystemExit(f"Asset {wanted!r} nao existe unicamente na ultima release estavel de {repo}")
a = hits[0]
digest = a.get("digest", "")
if not digest.startswith("sha256:"):
    raise SystemExit(f"Release {repo}/{tag} nao publicou digest SHA-256 pela API do GitHub")
url = a.get("browser_download_url", "")
parsed = urllib.parse.urlparse(url)
if parsed.scheme != "https" or parsed.netloc != "github.com" or not parsed.path.startswith(f"/{repo}/releases/download/"):
    raise SystemExit("URL do asset nao corresponde ao repositorio oficial esperado")
print(tag + "\t" + url + "\t" + digest.split(":", 1)[1])
PY
}

download_verified_release_asset() {
  local repo="$1" asset="$2" destination="$3" metadata tag url expected actual
  metadata="$(release_asset_metadata "$repo" "$asset")"
  IFS=$'\t' read -r tag url expected <<< "$metadata"
  [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || die "Digest SHA-256 invalido recebido para $repo/$asset"
  printf 'Baixando %s (%s) de %s\n' "$asset" "$tag" "$repo" >&2
  curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 \
    -H 'User-Agent: six-addons-ubuntu-installer' "$url" -o "$destination"
  actual="$(sha256sum "$destination" | awk '{print $1}')"
  [[ "${actual,,}" == "${expected,,}" ]] || die "SHA-256 nao confere para $repo/$asset; arquivo descartado"
  printf 'SHA-256 validado: %s\n' "$asset" >&2
  printf '%s\n' "$tag"
}

extract_archive_binary() {
  local archive="$1" binary="$2" output="$3"
  python3 - "$archive" "$binary" "$output" <<'PY'
import os, pathlib, sys, tarfile
archive, wanted, output = sys.argv[1:]
matches = []
with tarfile.open(archive, "r:gz") as tf:
    for member in tf.getmembers():
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit(f"Caminho inseguro no arquivo: {member.name}")
        if path.name == wanted:
            if not member.isfile():
                raise SystemExit(f"O item {wanted} nao e arquivo regular")
            matches.append(member)
    if len(matches) != 1:
        raise SystemExit(f"Esperava um unico binario {wanted}; achei {len(matches)}")
    source = tf.extractfile(matches[0])
    if source is None:
        raise SystemExit(f"Nao foi possivel ler o binario {wanted}")
    data = source.read()
if not data:
    raise SystemExit(f"Binario vazio: {wanted}")
fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o700)
with os.fdopen(fd, "wb") as f:
    f.write(data)
PY
}

claude_mcp_state() {
  local name="$1" command_name="$2"; shift 2
  python3 - "$CLAUDE_JSON" "$name" "$command_name" "$@" <<'PY'
import json, os, pathlib, sys

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Chave JSON duplicada: {key}; revise manualmente")
        result[key] = value
    return result
path, name, command = sys.argv[1:4]
args = sys.argv[4:]
legacy = json.loads(os.environ.get("LEGACY_MCP_ARGV") or "[]")
if not isinstance(legacy, list) or not all(isinstance(x, str) for x in legacy):
    raise SystemExit("LEGACY_MCP_ARGV precisa ser lista JSON de strings")
p = pathlib.Path(path)
if not p.exists():
    print("absent"); raise SystemExit(0)
try:
    root = json.loads(p.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
except Exception as exc:
    raise SystemExit(f"{path} nao e JSON valido: {exc}")
if not isinstance(root, dict):
    raise SystemExit(f"{path} nao contem objeto JSON")
servers = root.get("mcpServers", {})
if not isinstance(servers, dict):
    raise SystemExit(f"mcpServers em {path} nao e um objeto")
if name not in servers:
    print("absent"); raise SystemExit(0)
server = servers[name]
if not isinstance(server, dict):
    raise SystemExit(f"Entrada Claude MCP {name} nao e objeto")
def same(cmd, argv):
    return server.get("command") == cmd and server.get("args", []) == argv and server.get("type", "stdio") == "stdio"
if same(command, args):
    print("matching")
elif legacy and same(legacy[0], legacy[1:]):
    print("legacy")
elif command.startswith("/") and server.get("command") == command and server.get("type", "stdio") == "stdio":
    # Mesmo binario instalado por este pacote, com outros argumentos: atualiza as opcoes.
    print("legacy")
else:
    raise SystemExit(f"Conflito: Claude MCP {name} ja existe com outra configuracao; nenhuma entrada foi sobrescrita")
PY
}

codex_mcp_state() {
  local name="$1" command_name="$2"; shift 2
  codex mcp list --json > "$TMP_WORKDIR/codex-mcp.json" || return
  python3 - "$TMP_WORKDIR/codex-mcp.json" "$name" "$command_name" "$@" <<'PY'
import json, os, pathlib, sys
path, name, command = sys.argv[1:4]
args = sys.argv[4:]
legacy = json.loads(os.environ.get("LEGACY_MCP_ARGV") or "[]")
if not isinstance(legacy, list) or not all(isinstance(x, str) for x in legacy):
    raise SystemExit("LEGACY_MCP_ARGV precisa ser lista JSON de strings")
entries = json.loads(pathlib.Path(path).read_text())
if not isinstance(entries, list):
    raise SystemExit("Formato de codex mcp list --json nao reconhecido")
hits = [e for e in entries if isinstance(e, dict) and e.get("name") == name]
if not hits:
    print("absent"); raise SystemExit(0)
if len(hits) != 1:
    raise SystemExit(f"Conflito: mais de uma entrada MCP Codex {name}")
server = hits[0]
transport = server.get("transport", {})
def same(cmd, argv):
    return (transport.get("type") == "stdio" and transport.get("command") == cmd
            and transport.get("args", []) == argv and server.get("enabled") is True)
if same(command, args):
    print("matching")
elif legacy and same(legacy[0], legacy[1:]):
    print("legacy")
elif (command.startswith("/") and transport.get("type") == "stdio" and transport.get("command") == command
      and server.get("enabled") is True):
    # Mesmo binario instalado por este pacote, com outros argumentos: atualiza as opcoes.
    print("legacy")
else:
    raise SystemExit(f"Conflito: MCP Codex {name} diferente ou desabilitado; nenhuma entrada sobrescrita")
PY
}

ensure_claude_mcp() {
  local name="$1" command_name="$2" state; shift 2
  state="$(claude_mcp_state "$name" "$command_name" "$@")" || die "Nao foi possivel validar a entrada Claude MCP $name."
  if [[ "$state" == absent || "$state" == legacy ]]; then
    # Only the exact entry an older installer wrote is replaced (LEGACY_MCP_ARGV).
    if [[ "$state" == legacy ]]; then claude mcp remove --scope user "$name"; fi
    claude mcp add --transport stdio --scope user "$name" -- "$command_name" "$@"
    [[ "$state" == absent ]] && state=registrado || state=migrado
    [[ "$(claude_mcp_state "$name" "$command_name" "$@")" == matching ]] || die "Claude nao registrou $name como esperado."
    printf 'Claude MCP %s: %s\n' "$state" "$name"
  else
    printf 'Claude MCP ja confere: %s\n' "$name"
  fi
}

# Cold MCP server starts (node, uv) can exceed Claude's default 30s connect timeout.
set_claude_mcp_timeout() {
  python3 - "$CLAUDE_SETTINGS" <<'PY'
import json, os, pathlib, stat, sys, tempfile

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Chave JSON duplicada: {key}; revise manualmente")
        result[key] = value
    return result
p = pathlib.Path(sys.argv[1])
p.parent.mkdir(parents=True, exist_ok=True)
if p.exists():
    try:
        data = json.loads(p.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    except Exception as exc:
        raise SystemExit(f"settings.json nao e JSON valido; nenhuma alteracao feita: {exc}")
    if not isinstance(data, dict):
        raise SystemExit("settings.json precisa conter um objeto JSON no topo")
    mode = stat.S_IMODE(p.stat().st_mode)
else:
    data, mode = {}, 0o600
env = data.setdefault("env", {})
if not isinstance(env, dict):
    raise SystemExit("env em settings.json nao e um objeto; nenhuma alteracao feita")
current = str(env.get("MCP_TIMEOUT", ""))
if current and not (current.isdigit() and int(current) < 60000):
    print(f"MCP_TIMEOUT do Claude mantido: {current}"); raise SystemExit(0)
env["MCP_TIMEOUT"] = "60000"
fd, tmp = tempfile.mkstemp(prefix=".settings.json.", dir=str(p.parent))
try:
    os.fchmod(fd, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, p)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
print(f"MCP_TIMEOUT do Claude: 60000 em {p}")
PY
}

update_codex_mcp() {
  local name="$1" command_name="$2"; shift 2
  assert_regular_or_absent "$CODEX_CONFIG"
  backup_path "$CODEX_CONFIG"
  python3 - "$CODEX_CONFIG" "$name" "$command_name" "$@" <<'PY'
import copy, json, os, pathlib, re, stat, sys, tempfile
try:
    import tomllib
except ImportError:
    raise SystemExit("Atualizar MCP existente requer Python 3.11+; config.toml nao alterado")
p = pathlib.Path(sys.argv[1]); name, command = sys.argv[2:4]; args = sys.argv[4:]
old = p.read_text(encoding="utf-8")
before = tomllib.loads(old)
server = before.get("mcp_servers", {}).get(name, {})
legacy = json.loads(os.environ.get("LEGACY_MCP_ARGV") or "[]")
owned = (command.startswith("/") and server.get("command") == command
         or legacy and [server.get("command")] + server.get("args", []) == legacy)
if not owned or server.get("enabled", True) is not True:
    raise SystemExit("Entrada MCP mudou ou conflita; config.toml nao alterado")
# shortcut: TOML incomum exige revisao manual; ampliar o editor quando houver um caso real.
header = re.search(r"(?m)^[ \t]*\[[ \t]*mcp_servers[ \t]*\.[ \t]*(?:"
                   + re.escape(name) + "|" + re.escape(json.dumps(name)) + "|'"
                   + re.escape(name) + r"')[ \t]*\][ \t]*(?:#[^\n]*)?$", old)
if not header:
    raise SystemExit("Tabela MCP fora do formato suportado; config.toml nao alterado")
start = header.end()
next_header = re.search(r"(?m)^[ \t]*\[", old[start:])
end = start + next_header.start() if next_header else len(old)
body = old[start:end]
string = r'"(?:\\[^\n]|[^"\\\n])*"|\'[^\'\n]*\''
array = r"\[(?:\s|,|" + string + r")*\]"
edits = []
expected = copy.deepcopy(before)
for key, value, pattern in (("command", command, string), ("args", args, array)):
    if server.get(key, [] if key == "args" else None) == value:
        continue
    expected["mcp_servers"][name][key] = value
    match = re.search(r"(?m)^[ \t]*(?:" + key + "|'" + key + "'|\"" + key
                      + r'\")[ \t]*=[ \t]*(?P<value>' + pattern + ")", body)
    if match:
        edits.append((start + match.start("value"), start + match.end("value"),
                      json.dumps(value, ensure_ascii=False)))
    elif key not in server:
        prefix = "" if old[:end].endswith("\n") else "\n"
        edits.append((end, end, prefix + key + " = " + json.dumps(value, ensure_ascii=False) + "\n"))
    else:
        raise SystemExit(f"Campo MCP {key} fora do formato suportado; config.toml nao alterado")
new = old
for a, b, value in sorted(edits, reverse=True):
    new = new[:a] + value + new[b:]
if tomllib.loads(new) != expected:
    raise SystemExit("Edicao alteraria outra configuracao MCP; config.toml nao alterado")
fd, tmp = tempfile.mkstemp(prefix=".config.toml.", dir=str(p.parent))
try:
    os.fchmod(fd, stat.S_IMODE(p.stat().st_mode))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(new)
        f.flush()
        os.fsync(f.fileno())
    if p.read_text(encoding="utf-8") != old:
        raise SystemExit("config.toml mudou durante a edicao; nenhuma alteracao feita")
    os.replace(tmp, p)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
}

ensure_codex_mcp() {
  local name="$1" command_name="$2" state; shift 2
  state="$(codex_mcp_state "$name" "$command_name" "$@")" || die "Nao foi possivel validar a entrada Codex MCP $name."
  if [[ "$state" == absent || "$state" == legacy ]]; then
    if [[ "$state" == legacy ]]; then
      update_codex_mcp "$name" "$command_name" "$@"
    else
      codex mcp add "$name" -- "$command_name" "$@"
    fi
    [[ "$state" == absent ]] && state=registrado || state=migrado
    [[ "$(codex_mcp_state "$name" "$command_name" "$@")" == matching ]] || die "Codex nao registrou $name como esperado."
    printf 'Codex MCP %s: %s\n' "$state" "$name"
  else
    printf 'Codex MCP ja confere: %s\n' "$name"
  fi
}

edit_client_json() {
  local mode="$1" file="$2" kind="$3" name="$4"; shift 4
  assert_regular_or_absent "$file"
  [[ "$mode" != apply ]] || backup_path "$file"
  python3 - "$mode" "$file" "$kind" "$name" "$OPENCODE_MAJOR" "$@" <<'PY'
import json, os, pathlib, re, shutil, stat, sys, tempfile
mode, filename, kind, name, major = sys.argv[1:6]
args = sys.argv[6:]
p = pathlib.Path(filename)
def read_config_text():
    text=p.read_text() if p.exists() else ''
    # Arquivo vazio (comum no settings.json do VS Code) equivale a objeto vazio.
    return text if text.strip() else '{}\n'
original = read_config_text()
pattern = re.compile(r'\s+|//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null|[{}\[\]:,]')
def parse(text):
    tokens=[]; pos=0
    while pos < len(text):
        m=pattern.match(text,pos)
        if not m: raise ValueError('JSONC invalido; arquivo nao alterado')
        v=m.group(); pos=m.end()
        if not (v.isspace() or v.startswith('//') or v.startswith('/*')): tokens.append((v,m.start(),m.end()))
    i=0; objects={}; spans={}
    def value(path):
        nonlocal i
        if i >= len(tokens): raise ValueError('JSONC incompleto')
        t,start,end=tokens[i]; i+=1
        if t=='{':
            out={}; trailing=False
            while tokens[i][0]!='}':
                k=json.loads(tokens[i][0]); i+=1
                if not isinstance(k,str) or k in out: raise ValueError('Chave duplicada/invalida')
                if tokens[i][0]!=':': raise ValueError('Falta dois-pontos')
                i+=1; out[k]=value(path+(k,)); trailing=False
                if tokens[i][0]==',': i+=1; trailing=True
                elif tokens[i][0]!='}': raise ValueError('Falta virgula')
            close=tokens[i][1]; end=tokens[i][2]; i+=1
            objects[path]=(close,bool(out),trailing)
        elif t=='[':
            out=[]
            while tokens[i][0]!=']':
                out.append(value(path+(len(out),)))
                if tokens[i][0]==',': i+=1
                elif tokens[i][0]!=']': raise ValueError('Falta virgula')
            end=tokens[i][2]; i+=1
        else:
            out=json.loads(t)
        spans[path]=(start,end)
        return out
    root=value(())
    if i!=len(tokens) or not isinstance(root,dict): raise ValueError('Raiz JSONC deve ser objeto unico')
    return root,objects,spans
def build(command, argv):
    if kind=='opencode':
        entry={'type':'local','command':[command]+argv}
        entry.update({'disabled':False} if major=='2' else {'enabled':True})
        return entry
    entry={'command':command,'args':argv}
    if kind=='cline': entry.update(disabled=False,autoApprove=[])
    elif kind=='copilot': entry.update(type='local',tools=['*'])
    elif kind=='vscode': entry.update(type='stdio')
    else: raise ValueError('Cliente desconhecido')
    return entry
if kind=='memory':
    changes=[((key,),False,True,None) for key in ('github.copilot.chat.tools.memory.enabled','github.copilot.chat.copilotMemory.enabled')]
else:
    paths={'cline':('mcpServers',name),'copilot':('mcpServers',name),'vscode':('servers',name),
           'opencode':('mcp','servers',name) if major=='2' else ('mcp',name)}
    if kind not in paths: raise ValueError('Cliente desconhecido')
    legacy=json.loads(os.environ.get('LEGACY_MCP_ARGV') or '[]')
    if not isinstance(legacy,list) or not all(isinstance(x,str) for x in legacy):
        raise ValueError('LEGACY_MCP_ARGV precisa ser lista JSON de strings')
    # new_client_mcp stores npx by absolute path, so the legacy entry did too.
    if legacy[:1]==['npx']: legacy[0]=shutil.which('npx') or 'npx'
    changes=[(paths[kind],build(args[0],args[1:]),False,build(legacy[0],legacy[1:]) if legacy else None)]
if kind=='opencode':
    root,_,_=parse(original)
    current=root.get('mcp',{})
    if not isinstance(current,dict): raise ValueError('mcp precisa ser objeto')
    if major=='1' and 'servers' in current: raise ValueError('Encontrado schema MCP v2; confira --opencode-major')
    if major=='2' and any(isinstance(v,dict) and 'type' in v for v in current.values()):
        raise ValueError('Encontrado schema MCP v1; migre antes de instalar no v2')
def owned(node):
    # Mesmo binario instalado por este pacote, com outros argumentos: atualiza as opcoes.
    if kind=='memory' or not isinstance(node,dict) or not args[0].startswith('/'): return False
    command=node.get('command')
    return command[:1]==[args[0]] if kind=='opencode' and isinstance(command,list) else command==args[0]
text=original
for path,expected,replace,legacy in changes:
    root,objects,spans=parse(text)
    node=root
    for depth,key in enumerate(path):
        if not isinstance(node,dict): raise ValueError('Estrutura JSONC conflitante; revise manualmente')
        if key not in node:
            nested=expected
            for child in reversed(path[depth+1:]): nested={child:nested}
            close,has,trailing=objects[path[:depth]]
            insertion=(',' if has and not trailing else '')+'\n'+json.dumps(key)+': '+json.dumps(nested,ensure_ascii=False,indent=2)+'\n'
            text=text[:close]+insertion+text[close:]; break
        if depth==len(path)-1:
            if node[key]!=expected:
                if not replace and (legacy is None or node[key]!=legacy) and not owned(node[key]): raise ValueError(f'Conflito MCP {name}: {filename}; nenhuma entrada substituida')
                a,b=spans[path]; text=text[:a]+json.dumps(expected)+text[b:]
        node=node[key]
# Verify all resulting settings before committing the file.
root,_,_=parse(text)
for path,expected,*_ in changes:
    node=root
    for key in path: node=node[key]
    if node!=expected: raise ValueError('Verificacao JSONC falhou')
if mode=='verify' and text!=original: raise ValueError('Configuracao esperada ausente')
if mode=='apply' and text!=original:
    p.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix='.'+p.name+'.',dir=str(p.parent))
    try:
        with os.fdopen(fd,'w') as f: f.write(text)
        os.chmod(tmp,stat.S_IMODE(p.stat().st_mode) if p.exists() else 0o600)
        if read_config_text()!=original: raise ValueError('Arquivo mudou durante a edicao')
        os.replace(tmp,p)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
print(f'{mode}: {kind}/{name}: {filename}')
PY
}

new_client_mcp() {
  local mode="$1" client="$2" name="$3" command_name="$4" file; shift 4
  case "$client" in
    cline) file="$CLINE_CONFIG" ;;
    opencode) file="$OC_CONFIG_FILE" ;;
    copilot) file="$COPILOT_DIR/mcp-config.json" ;;
    vscode) file="$VSCODE_USER_DIR/mcp.json" ;;
    *) die "Cliente MCP invalido: $client" ;;
  esac
  if [[ "$command_name" == npx ]]; then command_name="$(command -v npx)"; fi
  edit_client_json "$mode" "$file" "$client" "$name" "$command_name" "$@"
}

all_mcp() {
  local mode="$1" name="$2" command_name="$3" client context state; shift 3
  local argv=()
  for client in claude codex cline opencode copilot vscode; do
    selected "$client" || continue
    argv=("$@")
    if [[ "$name" == serena ]]; then
      case "$client" in claude) context=claude-code ;; codex) context=codex ;; copilot) context=copilot-cli ;; vscode) context=vscode ;; *) context=ide ;; esac
      argv=(start-mcp-server --context "$context" --add-mode no-memories)
      case "$client" in
        claude|codex|copilot) argv+=(--project-from-cwd) ;;
        opencode)
          if [[ -z "$PROJECT_DIR" ]]; then
            argv=(start-mcp-server --context "$context" --project-from-cwd --add-mode no-memories)
          else
            argv+=(--project "$PROJECT_DIR")
          fi ;;
        *) [[ -z "$PROJECT_DIR" ]] || argv+=(--project "$PROJECT_DIR") ;;
      esac
      # Keep the original argument order for existing Claude/Codex installations.
      if [[ "$client" == claude || "$client" == codex ]]; then
        argv=(start-mcp-server --context "$context" --project-from-cwd --add-mode no-memories)
      fi
      argv+=(${SERENA_EXTRA[@]+"${SERENA_EXTRA[@]}"})
    fi
    case "$client" in
      claude|codex)
        if [[ "$mode" == apply ]]; then
          "ensure_${client}_mcp" "$name" "$command_name" "${argv[@]}"
        else
          state="$("${client}_mcp_state" "$name" "$command_name" "${argv[@]}")"
          [[ "$mode" != verify || "$state" == matching ]] || die "MCP $name ausente no $client"
        fi ;;
      *) new_client_mcp "$mode" "$client" "$name" "$command_name" "${argv[@]}" ;;
    esac
  done
}
write_managed_rule() {
  local file="$1" source="$2" frontmatter="${3:-0}"
  assert_regular_or_absent "$file"
  backup_path "$file"
  python3 - "$file" "$source" "$ADDON" "$frontmatter" <<'PY'
import os,pathlib,stat,sys,tempfile
p,source,addon,frontmatter=sys.argv[1:]; p=pathlib.Path(p)
old=p.read_text() if p.exists() else ''
start=f'<!-- six-addons:{addon}:begin -->'; end=f'<!-- six-addons:{addon}:end -->'
block=start+'\n'+pathlib.Path(source).read_text().strip()+'\n'+end
if start in old or end in old:
    if old.count(start)!=1 or old.count(end)!=1 or old.index(start)>old.index(end):
        raise ValueError('Bloco gerenciado corrompido; nenhuma alteracao')
    a=old.index(start); b=old.index(end)+len(end); new=old[:a]+block+old[b:]
else:
    prefix='---\napplyTo: "**"\n---\n\n' if frontmatter=='1' and not old else ''
    if frontmatter=='1' and old: raise ValueError('Arquivo de instrucoes ja existe sem bloco gerenciado; revise manualmente')
    new=old+('\n\n' if old else prefix)+block+'\n'
if new!=old:
    p.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix='.'+p.name+'.',dir=str(p.parent))
    try:
        with os.fdopen(fd,'w') as f:f.write(new)
        os.chmod(tmp,stat.S_IMODE(p.stat().st_mode) if p.exists() else 0o600)
        if (p.read_text() if p.exists() else '')!=old: raise ValueError('Arquivo mudou durante a edicao')
        os.replace(tmp,p)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)
assert p.read_text().count(start)==1 and block in p.read_text()
print(f'Instrucoes {addon}: {p}')
PY
}

new_client_rules() {
  local source="$1"
  if selected cline; then write_managed_rule "$HOME_DIR/.cline/rules/six-addons-$ADDON.md" "$source"; fi
  if selected opencode; then write_managed_rule "$OPENCODE_DIR/AGENTS.md" "$source"; fi
  if selected copilot; then write_managed_rule "$COPILOT_DIR/copilot-instructions.md" "$source"; fi
  if selected vscode; then write_managed_rule "$VSCODE_USER_DIR/prompts/six-addons-$ADDON.instructions.md" "$source" 1; fi
}


prepare_go() {
  local go_version go_archive go_sha go_root
  local -a go_asset
  if ! command -v go >/dev/null 2>&1; then
    for binary in go gofmt; do
      [[ ! -e "$LOCAL_BIN/$binary" && ! -L "$LOCAL_BIN/$binary" ]] || die "Conflito: $LOCAL_BIN/$binary ja existe."
    done
    curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 'https://go.dev/dl/?mode=json' -o "$TMP_WORKDIR/go-releases.json"
    python3 - "$TMP_WORKDIR/go-releases.json" "$(uname -m)" > "$TMP_WORKDIR/go-asset.txt" <<'PYGO'
import json,re,sys
arch={'x86_64':'amd64','amd64':'amd64','aarch64':'arm64','arm64':'arm64'}[sys.argv[2]]
releases=json.load(open(sys.argv[1]))
release=next(r for r in releases if r['stable'])
f=next(f for f in release['files'] if f['os']=='linux' and f['arch']==arch and f['kind']=='archive')
assert re.fullmatch(r'go[0-9]+\.[0-9]+\.[0-9]+',f['version'])
assert f['filename']==f['version']+'.linux-'+arch+'.tar.gz'
assert re.fullmatch(r'[0-9a-f]{64}',f['sha256'])
print(f['version']); print(f['filename']); print(f['sha256'])
PYGO
    mapfile -t go_asset < "$TMP_WORKDIR/go-asset.txt"
    go_version="${go_asset[0]}"; go_archive="${go_asset[1]}"; go_sha="${go_asset[2]}"
    go_root="$HOME_DIR/.local/lib/go/$go_version"
    [[ ! -e "$go_root" && ! -L "$go_root" ]] || die "Destino Go ja existe: $go_root; revise antes de instalar."
    curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 "https://go.dev/dl/$go_archive" -o "$TMP_WORKDIR/go.tar.gz"
    printf '%s  %s\n' "$go_sha" "$TMP_WORKDIR/go.tar.gz" | sha256sum --check --status
    "$UV_TOOL_DIR/serena-agent/bin/python" - "$TMP_WORKDIR/go.tar.gz" "$TMP_WORKDIR/go-unpack" <<'PYGO'
import sys,tarfile
with tarfile.open(sys.argv[1]) as archive:
    archive.extractall(sys.argv[2],filter='data')
PYGO
    mkdir -p "${go_root%/*}"
    mv "$TMP_WORKDIR/go-unpack/go" "$go_root"
    ln -s "$go_root/bin/go" "$LOCAL_BIN/go"
    ln -s "$go_root/bin/gofmt" "$LOCAL_BIN/gofmt"
  fi
  go version
  if ! command -v gopls >/dev/null 2>&1; then
    [[ ! -e "$LOCAL_BIN/gopls" && ! -L "$LOCAL_BIN/gopls" ]] || die "Conflito: $LOCAL_BIN/gopls ja existe."
    # Compilacao sequencial evita esgotar memoria em maquinas pequenas.
    GOMAXPROCS=2 GOBIN="$LOCAL_BIN" go install -p=1 golang.org/x/tools/gopls@latest
  fi
  gopls version
}

check_go_project() {
  [[ -d "$CHECK_GO_PROJECT" && -f "$CHECK_GO_PROJECT/go.mod" ]] || die 'O teste requer um projeto Go com go.mod na raiz.'
  command -v go >/dev/null 2>&1 && command -v gopls >/dev/null 2>&1 || die 'Go/gopls ausentes; use --with-go ou instale-os antes do teste.'
  "$UV_TOOL_DIR/serena-agent/bin/python" - "$LOCAL_BIN/serena" "$CHECK_GO_PROJECT" <<'PYCHECK'
import asyncio,json,os,pathlib,sys,tempfile
from mcp import ClientSession,StdioServerParameters
from mcp.client.stdio import stdio_client
async def check():
    root=pathlib.Path(sys.argv[2]).resolve()
    files=sorted(p for p in root.rglob('*.go') if not any(x in {'.git','vendor','node_modules'} for x in p.relative_to(root).parts))
    if not files: raise RuntimeError('Nenhum arquivo Go encontrado para o teste')
    args=['start-mcp-server','--context','codex','--agent-interface','tools','--project',str(root),'--add-mode','no-memories','--enable-web-dashboard','False','--open-web-dashboard','False']
    params=StdioServerParameters(command=sys.argv[1],args=args,env=dict(os.environ,GOMAXPROCS='2'))
    with tempfile.TemporaryFile(mode='w+') as log:
        async with stdio_client(params,errlog=log) as (read,write):
            async with ClientSession(read,write) as session:
                await session.initialize()
                result=await session.call_tool('get_symbols_overview',{'relative_path':str(files[0].relative_to(root)),'depth':0,'max_answer_chars':10000})
                text='\n'.join(c.text for c in result.content if hasattr(c,'text'))
                # MCP v1 usa isError; v2 renomeou o atributo para is_error.
                if getattr(result,'is_error',getattr(result,'isError',False)) or 'Error executing tool' in text: raise RuntimeError(text)
                symbols=json.loads(text)
                if not isinstance(symbols,dict) or not any(symbols.values()): raise RuntimeError('LSP nao retornou simbolos; revise o arquivo/projeto')
                print('Serena: leitura real de simbolos confirmada em',files[0])
try:
    asyncio.run(asyncio.wait_for(check(),timeout=180))
except Exception as exc:
    raise SystemExit('Falha na validacao Serena/Go: '+str(exc))
PYCHECK
}

all_mcp check serena "$LOCAL_BIN/serena"
UV_TAG="$(download_verified_release_asset 'astral-sh/uv' "$UV_ASSET" "$TMP_WORKDIR/uv.tar.gz")"
extract_archive_binary "$TMP_WORKDIR/uv.tar.gz" uv "$TMP_WORKDIR/uv"
extract_archive_binary "$TMP_WORKDIR/uv.tar.gz" uvx "$TMP_WORKDIR/uvx"
install -m 0755 "$TMP_WORKDIR/uv" "$LOCAL_BIN/uv"
install -m 0755 "$TMP_WORKDIR/uvx" "$LOCAL_BIN/uvx"
printf 'uv instalado: %s\n' "$UV_TAG"
export UV_TOOL_BIN_DIR="$LOCAL_BIN"
export UV_TOOL_DIR="$HOME_DIR/.local/share/uv/tools"
export UV_CACHE_DIR="$HOME_DIR/.cache/uv"
"$LOCAL_BIN/uv" tool install --upgrade -p 3.13 serena-agent
[[ -x "$LOCAL_BIN/serena" ]] || die 'uv nao criou ~/.local/bin/serena.'
"$LOCAL_BIN/serena" start-mcp-server --help > "$TMP_WORKDIR/serena-help.txt"
for flag in --context --project-from-cwd --add-mode ${SERENA_EXTRA[@]+"${SERENA_EXTRA[@]}"}; do
  [[ "$flag" == --* ]] || continue
  grep -Fq -- "$flag" "$TMP_WORKDIR/serena-help.txt" || die "Serena nao documenta $flag; servidor nao registrado."
done
if [[ "$WITH_GO" == 1 ]]; then prepare_go; fi
if [[ -n "$SERENA_LS_DEPS" ]]; then
  "$LOCAL_BIN/serena" --help | grep -Fq download-ls-dependencies || die 'Esta versao do Serena nao tem download-ls-dependencies.'
  IFS=, read -r -a serena_ls <<< "$SERENA_LS_DEPS"
  "$LOCAL_BIN/serena" download-ls-dependencies "${serena_ls[@]}"
fi
cat > "$TMP_WORKDIR/serena-rules.md" <<'RULES'
## Serena
Before coding tasks, read the Serena initial instructions. Prefer its symbol and reference tools to explore and modify code. If the language backend fails, report it; an MCP registration does not prove the analyzer works. If a file's language is missing from `language_servers` in `.serena/project.yml`, say so and propose adding it; Serena reads that file only when its MCP server starts.
RULES
if selected claude; then write_managed_rule "$CLAUDE_DIR/CLAUDE.md" "$TMP_WORKDIR/serena-rules.md"; fi
if selected codex; then write_managed_rule "$CODEX_DIR/AGENTS.md" "$TMP_WORKDIR/serena-rules.md"; fi
new_client_rules "$TMP_WORKDIR/serena-rules.md"
if selected claude; then set_claude_mcp_timeout; fi
all_mcp apply serena "$LOCAL_BIN/serena"
"$LOCAL_BIN/serena" --version
all_mcp verify serena "$LOCAL_BIN/serena"
if [[ -n "$CHECK_GO_PROJECT" ]]; then check_go_project; fi

printf '\nConcluido: Serena instalado/configurado para o usuario.\n'
printf 'Backup: %s\nLog: %s\n' "$BACKUP_DIR" "$LOG_FILE"
printf 'Reinicie os agentes para carregar a integracao.
'
if [[ ":$ORIGINAL_PATH:" != *":$LOCAL_BIN:"* ]]; then
  printf 'Inclua %s no PATH das sessoes que iniciam os agentes.\n' "$LOCAL_BIN"
fi
