#!/usr/bin/env bash
# Arquivo independente: nao precisa de biblioteca nem dos outros instaladores.
# Fontes oficiais e limites de validacao estao no README.md do pacote.
set -Eeuo pipefail
umask 077

ADDON="ponytail"
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

Instala e configura somente Ponytail no escopo do usuario do Ubuntu.
Instala o plugin oficial no escopo do usuario nos dois agentes.

  --dry-run  Mostra o plano, sem rede, arquivos, logs ou alteracoes.
  --help     Mostra esta ajuda.

Pre-requisitos: git, node, python3, flock, claude, codex.
Nao usa sudo. Requer os dois CLIs ja instalados e autenticados.
Usa o marketplace oficial DietrichGebert/ponytail; registra versoes no log.
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
Simulacao de Ponytail: sem alteracoes e sem acesso a rede.
  • Exigir Ubuntu, usuario sem sudo e: git, node, python3, flock, claude, codex.
  • Instalar/atualizar ponytail@ponytail nos dois agentes.
  • Conferir se os dois plugins estao instalados e habilitados.
  • Bloquear execucao simultanea dos seis instaladores.
  • Fazer backup antes de alterar configuracoes e criar log privado.
  • Conferir Ponytail depois da instalacao.
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
for cmd in git node python3 flock claude codex; do
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
assert_regular_or_absent "$CLAUDE_DIR/plugins/known_marketplaces.json"
backup_path "$CLAUDE_DIR/plugins/known_marketplaces.json"
assert_regular_or_absent "$CLAUDE_DIR/plugins/installed_plugins.json"
backup_path "$CLAUDE_DIR/plugins/installed_plugins.json"
assert_regular_or_absent "$CODEX_DIR/plugins/marketplaces.json"
backup_path "$CODEX_DIR/plugins/marketplaces.json"
assert_regular_or_absent "$CODEX_DIR/plugins/installed_plugins.json"
backup_path "$CODEX_DIR/plugins/installed_plugins.json"
assert_regular_or_absent "$CODEX_DIR/hooks.json"
backup_path "$CODEX_DIR/hooks.json"
assert_regular_or_absent "$HOME_DIR/.agents/plugins/marketplace.json"
backup_path "$HOME_DIR/.agents/plugins/marketplace.json"

claude_ponytail_marketplace_state() {
  python3 - "$CLAUDE_DIR/plugins/known_marketplaces.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
if not p.exists():
    print("absent"); raise SystemExit(0)
data = json.loads(p.read_text())
if not isinstance(data, dict):
    raise SystemExit("Registro Claude de marketplaces nao reconhecido")
entry = data.get("ponytail")
if entry is None:
    print("absent"); raise SystemExit(0)
source = entry.get("source", {}) if isinstance(entry, dict) else {}
if source.get("source") != "github" or source.get("repo") != "DietrichGebert/ponytail":
    raise SystemExit("Conflito: marketplace ponytail existe com outra origem; revise manualmente")
print("matching")
PY
}
verify_plugins() {
  local name="$1"
  claude plugin list --json > "$TMP_WORKDIR/claude-plugins.json"
  codex plugin list --json > "$TMP_WORKDIR/codex-plugins.json"
  python3 - "$name" "$TMP_WORKDIR/claude-plugins.json" "$TMP_WORKDIR/codex-plugins.json" <<'PY'
import json, pathlib, sys
name, claude_path, codex_path = sys.argv[1:]
claude = json.loads(pathlib.Path(claude_path).read_text())
entries = claude.get("plugins") if isinstance(claude, dict) else claude
if not isinstance(entries, list):
    raise SystemExit("Formato de claude plugin list --json nao reconhecido")
def matches(entry):
    if not isinstance(entry, dict): return False
    identifier = entry.get("id") or entry.get("name")
    return identifier == f"{name}@{name}" or (identifier == name and entry.get("marketplace") in (name, f"Gentleman-Programming/{name}" if name == "engram" else f"DietrichGebert/{name}"))
hits = [e for e in entries if matches(e) and e.get("scope", "user") == "user"]
if len(hits) != 1 or hits[0].get("enabled") is not True:
    raise SystemExit(f"Claude: plugin {name} nao confirmado instalado e habilitado no escopo do usuario")
codex = json.loads(pathlib.Path(codex_path).read_text())
if not isinstance(codex, dict) or not isinstance(codex.get("installed"), list):
    raise SystemExit("Formato de codex plugin list --json nao reconhecido")
hits = [e for e in codex["installed"] if isinstance(e, dict) and e.get("name") == name and e.get("marketplaceName") == name]
if len(hits) != 1 or hits[0].get("installed") is not True or hits[0].get("enabled") is not True:
    raise SystemExit(f"Codex: plugin {name} nao confirmado instalado e habilitado")
print(f"Plugins {name}: instalados e habilitados nos dois agentes")
print("Versao Claude:", next(e.get("version", "?") for e in entries if matches(e)))
print("Versao Codex:", hits[0].get("version", "?"))
PY
}


marketplace_state="$(claude_ponytail_marketplace_state)" || die 'Revise o marketplace Claude ponytail.'
if [[ "$marketplace_state" == absent ]]; then
  claude plugin marketplace add DietrichGebert/ponytail
else
  printf 'Marketplace Claude ponytail ja confere.\n'
fi
claude plugin marketplace update ponytail
if ! claude plugin install ponytail@ponytail --scope user > "$TMP_WORKDIR/ponytail-install.txt" 2>&1; then
  cat "$TMP_WORKDIR/ponytail-install.txt"
  grep -qi 'already installed' "$TMP_WORKDIR/ponytail-install.txt" || die 'Falha ao instalar Ponytail no Claude.'
else
  cat "$TMP_WORKDIR/ponytail-install.txt"
fi
claude plugin update ponytail@ponytail --scope user
codex plugin marketplace add DietrichGebert/ponytail
codex plugin add ponytail@ponytail
verify_plugins ponytail

printf '\nConcluido: Ponytail instalado/configurado para o usuario.\n'
printf 'Backup: %s\nLog: %s\n' "$BACKUP_DIR" "$LOG_FILE"
printf 'Reinicie os agentes para carregar a integracao.
'
printf 'No Codex, abra /hooks para revisar e confiar nos hooks do plugin e inicie nova sessao.
'
if [[ ":$ORIGINAL_PATH:" != *":$LOCAL_BIN:"* ]]; then
  printf 'Inclua %s no PATH das sessoes que iniciam os agentes.\n' "$LOCAL_BIN"
fi
