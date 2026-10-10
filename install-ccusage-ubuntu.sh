#!/usr/bin/env bash
# Arquivo independente: nao precisa de biblioteca nem dos outros instaladores.
# Fontes oficiais e limites de validacao estao no README.md do pacote.
set -Eeuo pipefail
umask 077

ADDON="ccusage"
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

Instala e configura somente ccusage no escopo do usuario do Ubuntu.
Integra somente os clientes selecionados. Consulte a matriz de compatibilidade no README.

  --dry-run  Mostra o plano, sem rede, arquivos, logs ou alteracoes.
  --help     Mostra esta ajuda.
  --clients LISTA  claude,codex,cline,opencode,copilot,vscode ou all.
                   Padrao: claude,codex. copilot = CLI; vscode = Copilot VS Code.
  --cline-config ARQUIVO  MCP do Cline CLI ou extensao (caminho absoluto).
  --vscode-user-dir DIR   Pasta User do perfil VS Code no Ubuntu.
  --opencode-major 1|2    Schema instalado; senao detecta opencode --version.
  --project-dir DIR      Projeto fixo do Serena nos novos clientes (opcional).
OpenRouter: selecione cline/opencode e configure o provedor no proprio cliente.
RTK/Ponytail nos novos clientes: regras, sem hooks nem comandos de plugin.

Pre-requisitos: node, npm, flock, python3.
Nao usa sudo. Nao requer os CLIs dos agentes para instalar a CLI de relatorios.
Instala ccusage@latest no prefixo ~/.local; npm recusa Node com versao incompatível.
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
    --clients|--cline-config|--vscode-user-dir|--opencode-major|--project-dir)
      (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || { printf 'Falta valor para %s\n' "$1" >&2; exit 2; }
      case "$1" in
        --clients) CLIENTS="$2" ;;
        --cline-config) CLINE_CONFIG="$2" ;;
        --vscode-user-dir) VSCODE_USER_DIR="$2" ;;
        --opencode-major) OPENCODE_MAJOR="$2" ;;
        --project-dir) PROJECT_DIR="$2" ;;
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
for path in "$CLINE_CONFIG" "$VSCODE_USER_DIR" "$OPENCODE_DIR" "$COPILOT_DIR" "${PROJECT_DIR:-/}"; do
  [[ "$path" == /* && "$path" != *$'\n'* ]] || { printf 'Caminho precisa ser absoluto, sem quebra de linha: %s\n' "$path" >&2; exit 2; }
done
if [[ "$DRY_RUN" == 1 ]]; then
  cat <<EOF
Simulacao de ccusage: sem alteracoes e sem acesso a rede.
  Clientes: $CLIENTS
  Cline MCP: $CLINE_CONFIG
  OpenCode: $OPENCODE_DIR (major: ${OPENCODE_MAJOR:-detectar})
  Copilot CLI: $COPILOT_DIR
  VS Code User: $VSCODE_USER_DIR
  Serena projeto novos clientes: ${PROJECT_DIR:-ativacao durante a sessao}
  • Exigir Ubuntu, usuario sem sudo e: node, npm, flock, python3.
  • Instalar ccusage no prefixo ~/.local e conferir versao/ajuda.
  • Nenhuma configuracao de cliente sera alterada.
  • Bloquear execucao simultanea dos seis instaladores.
  • Fazer backup antes de alterar configuracoes e criar log privado.
  • Conferir ccusage depois da instalacao.
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
for cmd in node npm flock python3; do
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
  cp -a -- "$path" "$destination"
  printf 'Backup: %s -> %s\n' "$path" "$destination"
}

assert_regular_or_absent() {
  local path="$1"
  [[ ! -L "$path" ]] || die "Revise o link simbolico antes de prosseguir: $path"
  [[ ! -e "$path" || -f "$path" ]] || die "Caminho nao e arquivo regular: $path"
}

if [[ "$ADDON" != ccusage ]]; then

if selected claude; then
  for path in "$CLAUDE_SETTINGS" "$CLAUDE_JSON" "$CLAUDE_DIR/CLAUDE.md" "$CLAUDE_DIR/RTK.md" "$CLAUDE_DIR/hooks/rtk-rewrite.sh" "$CLAUDE_DIR/hooks/.rtk-hook.sha256"; do assert_regular_or_absent "$path"; backup_path "$path"; done
  backup_path "$CLAUDE_DIR/plugins"
fi
if selected codex; then
  for path in "$CODEX_CONFIG" "$CODEX_DIR/hooks.json" "$CODEX_DIR/AGENTS.md" "$CODEX_DIR/RTK.md" "$CODEX_DIR/engram-instructions.md" "$CODEX_DIR/engram-compact-prompt.md"; do assert_regular_or_absent "$path"; backup_path "$path"; done
  backup_path "$CODEX_DIR/plugins"
  backup_path "$HOME_DIR/.agents/plugins"
fi

fi




node --version
npm --version
npm install --global --prefix "$HOME_DIR/.local" --registry=https://registry.npmjs.org --engine-strict=true ccusage@latest
[[ -x "$LOCAL_BIN/ccusage" ]] || die 'ccusage nao apareceu em ~/.local/bin.'
"$LOCAL_BIN/ccusage" --version
"$LOCAL_BIN/ccusage" --help >/dev/null

printf '\nConcluido: ccusage instalado/configurado para o usuario.\n'
printf 'Backup: %s\nLog: %s\n' "$BACKUP_DIR" "$LOG_FILE"
printf 'Reinicie os agentes para carregar a integracao.
'
if [[ ":$ORIGINAL_PATH:" != *":$LOCAL_BIN:"* ]]; then
  printf 'Inclua %s no PATH das sessoes que iniciam os agentes.\n' "$LOCAL_BIN"
fi
