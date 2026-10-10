#!/usr/bin/env bash
# Arquivo independente: nao precisa de biblioteca nem dos outros instaladores.
# Fontes oficiais e limites de validacao estao no README.md do pacote.
set -Eeuo pipefail
umask 077

ADDON="context7"
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

usage() {
  cat <<EOF
Uso: $SCRIPT_NAME [--dry-run | --help]

Instala e configura somente Context7 no escopo do usuario do Ubuntu.
Registra o MCP no escopo do usuario, com npx, para Claude Code e Codex.

  --dry-run  Mostra o plano, sem rede, arquivos, logs ou alteracoes.
  --help     Mostra esta ajuda.

Pre-requisitos: node, npm, npx, python3, flock, claude, codex.
Nao usa sudo. Requer os dois CLIs ja instalados e autenticados.
O MCP usa o pacote oficial @upstash/context7-mcp; npx resolve a versao ao iniciar.
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
for arg in "$@"; do
  case "$arg" in
    --help|-h) usage; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    *) printf 'Opcao desconhecida: %s\n\n' "$arg" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ "$DRY_RUN" == 1 ]]; then
  cat <<EOF
Simulacao de Context7: sem alteracoes e sem acesso a rede.
  • Exigir Ubuntu, usuario sem sudo e: node, npm, npx, python3, flock, claude, codex.
  • Registrar o MCP Context7 nos dois agentes via npx.
  • Sem chave obrigatoria e sem instalacao npm global do servidor.
  • Bloquear execucao simultanea dos seis instaladores.
  • Fazer backup antes de alterar configuracoes e criar log privado.
  • Conferir Context7 depois da instalacao.
Somente este addon sera instalado; os outros addons nao sao necessarios para executar este script.
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


export PATH="$LOCAL_BIN:$PATH"
MISSING=()
for cmd in node npm npx python3 flock claude codex; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
if ((${#MISSING[@]})); then
  die "Pre-requisitos ausentes: ${MISSING[*]}. Instale pelo gerenciador oficial do Ubuntu/fornecedor e reexecute."
fi

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
printf 'Claude: %s
Codex: %s
' "$CLAUDE_DIR" "$CODEX_DIR"
claude --version
codex --version

backup_path() {
  local path="$1" safe destination
  [[ -e "$path" || -L "$path" ]] || return 0
  safe="$(printf '%s' "$path" | sed 's#/#_#g; s/[^A-Za-z0-9_.-]/_/g')"
  destination="$BACKUP_DIR/$safe"
  [[ ! -e "$destination" && ! -L "$destination" ]] || return 0
  cp -a -- "$path" "$destination"
  printf 'Backup: %s -> %s\n' "$path" "$destination"
}

assert_regular_or_absent() {
  local path="$1"
  [[ ! -L "$path" ]] || die "Revise o link simbolico antes de prosseguir: $path"
  [[ ! -e "$path" || -f "$path" ]] || die "Caminho nao e arquivo regular: $path"
}

assert_regular_or_absent "$CLAUDE_SETTINGS"
backup_path "$CLAUDE_SETTINGS"
assert_regular_or_absent "$CLAUDE_JSON"
backup_path "$CLAUDE_JSON"
assert_regular_or_absent "$CODEX_CONFIG"
backup_path "$CODEX_CONFIG"

claude_mcp_state() {
  local name="$1" command_name="$2"; shift 2
  python3 - "$CLAUDE_JSON" "$name" "$command_name" "$@" <<'PY'
import json, pathlib, sys

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Chave JSON duplicada: {key}; revise manualmente")
        result[key] = value
    return result
path, name, command = sys.argv[1:4]
args = sys.argv[4:]
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
if server.get("command") == command and server.get("args", []) == args and server.get("type", "stdio") == "stdio":
    print("matching")
else:
    raise SystemExit(f"Conflito: Claude MCP {name} ja existe com outra configuracao; nenhuma entrada foi sobrescrita")
PY
}

codex_mcp_state() {
  local name="$1" command_name="$2"; shift 2
  codex mcp list --json > "$TMP_WORKDIR/codex-mcp.json" || return
  python3 - "$TMP_WORKDIR/codex-mcp.json" "$name" "$command_name" "$@" <<'PY'
import json, pathlib, sys
path, name, command = sys.argv[1:4]
args = sys.argv[4:]
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
if (transport.get("type") == "stdio" and transport.get("command") == command
        and transport.get("args", []) == args and server.get("enabled") is True):
    print("matching")
else:
    raise SystemExit(f"Conflito: MCP Codex {name} diferente ou desabilitado; nenhuma entrada sobrescrita")
PY
}

ensure_claude_mcp() {
  local name="$1" command_name="$2" state; shift 2
  state="$(claude_mcp_state "$name" "$command_name" "$@")" || die "Nao foi possivel validar a entrada Claude MCP $name."
  if [[ "$state" == absent ]]; then
    claude mcp add --transport stdio --scope user "$name" -- "$command_name" "$@"
    state="$(claude_mcp_state "$name" "$command_name" "$@")" || die "Claude nao registrou $name como esperado."
    [[ "$state" == matching ]] || die "Claude nao registrou $name como esperado."
    printf 'Claude MCP registrado: %s\n' "$name"
  else
    printf 'Claude MCP ja confere: %s\n' "$name"
  fi
}

ensure_codex_mcp() {
  local name="$1" command_name="$2" state; shift 2
  state="$(codex_mcp_state "$name" "$command_name" "$@")" || die "Nao foi possivel validar a entrada Codex MCP $name."
  if [[ "$state" == absent ]]; then
    codex mcp add "$name" -- "$command_name" "$@"
    state="$(codex_mcp_state "$name" "$command_name" "$@")" || die "Codex nao registrou $name como esperado."
    [[ "$state" == matching ]] || die "Codex nao registrou $name como esperado."
    printf 'Codex MCP registrado: %s\n' "$name"
  else
    printf 'Codex MCP ja confere: %s\n' "$name"
  fi
}



claude_mcp_state context7 npx -y --registry=https://registry.npmjs.org @upstash/context7-mcp >/dev/null || die 'Revise a entrada Claude MCP context7 antes de prosseguir.'
codex_mcp_state context7 npx -y --registry=https://registry.npmjs.org @upstash/context7-mcp >/dev/null || die 'Revise a entrada Codex MCP context7 antes de prosseguir.'

ensure_claude_mcp context7 npx -y --registry=https://registry.npmjs.org @upstash/context7-mcp
ensure_codex_mcp context7 npx -y --registry=https://registry.npmjs.org @upstash/context7-mcp
[[ "$(claude_mcp_state context7 npx -y --registry=https://registry.npmjs.org @upstash/context7-mcp)" == matching ]] || die 'Verificacao Claude MCP context7 falhou.'
[[ "$(codex_mcp_state context7 npx -y --registry=https://registry.npmjs.org @upstash/context7-mcp)" == matching ]] || die 'Verificacao Codex MCP context7 falhou.'


printf '\nConcluido: Context7 instalado/configurado para o usuario.\n'
printf 'Backup: %s\nLog: %s\n' "$BACKUP_DIR" "$LOG_FILE"
printf 'Reinicie os agentes para carregar a integracao.
'
if [[ ":$ORIGINAL_PATH:" != *":$LOCAL_BIN:"* ]]; then
  printf 'Inclua %s no PATH das sessoes que iniciam os agentes.\n' "$LOCAL_BIN"
fi
