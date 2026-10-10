#!/usr/bin/env bash
# Arquivo independente: nao precisa de biblioteca nem dos outros instaladores.
# Fontes oficiais e limites de validacao estao no README.md do pacote.
set -Eeuo pipefail
umask 077

ADDON="engram"
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

Instala e configura somente Engram no escopo do usuario do Ubuntu.
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

Pre-requisitos: curl, git, jq, python3, sha256sum, flock.
Nao usa sudo. Requer apenas os clientes selecionados; veja limites no README.
Baixa Engram estavel com SHA-256; setup nativo apenas em Claude/Codex selecionados.
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
Simulacao de Engram: sem alteracoes e sem acesso a rede.
  Clientes: $CLIENTS
  Cline MCP: $CLINE_CONFIG
  OpenCode: $OPENCODE_DIR (major: ${OPENCODE_MAJOR:-detectar})
  Copilot CLI: $COPILOT_DIR
  VS Code User: $VSCODE_USER_DIR
  Serena projeto novos clientes: ${PROJECT_DIR:-ativacao durante a sessao}
  • Exigir Ubuntu, usuario sem sudo e: curl, git, jq, python3, sha256sum, flock.
  • Instalar Engram verificado, registrar MCPs e protocolo de memoria.
  • Desativar memorias locais conhecidas; Copilot requer ajuste na conta GitHub.
  • Bloquear execucao simultanea dos seis instaladores.
  • Fazer backup antes de alterar configuracoes e criar log privado.
  • Conferir Engram depois da instalacao.
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
case "$(uname -m)" in
  x86_64|amd64) ASSET_ARCH=amd64 ;;
  aarch64|arm64) ASSET_ARCH=arm64 ;;
  *) die "Arquitetura nao suportada: $(uname -m). Use x86_64 ou aarch64." ;;
esac

export PATH="$LOCAL_BIN:$PATH"
MISSING=()
for cmd in curl git jq python3 sha256sum flock; do
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
assert_regular_or_absent "$LOCAL_BIN/engram"
backup_path "$LOCAL_BIN/engram"

set_claude_auto_memory_off() {
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
    raw = p.read_text(encoding="utf-8")
    try:
        data = json.loads(raw, object_pairs_hook=unique_object)
    except Exception as exc:
        raise SystemExit(f"settings.json nao e JSON valido; nenhuma alteracao feita: {exc}")
    if not isinstance(data, dict):
        raise SystemExit("settings.json precisa conter um objeto JSON no topo")
    mode = stat.S_IMODE(p.stat().st_mode)
else:
    data, mode = {}, 0o600
data["autoMemoryEnabled"] = False
encoded = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
fd, tmp = tempfile.mkstemp(prefix=".settings.json.", dir=str(p.parent))
try:
    os.fchmod(fd, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(encoded)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, p)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
  printf 'Memoria automatica nativa do Claude Code: desativada em %s\n' "$CLAUDE_SETTINGS"
}

set_codex_native_memory_off() {
  python3 - "$CODEX_CONFIG" <<'PY'
import copy, os, pathlib, re, stat, sys, tempfile
p = pathlib.Path(sys.argv[1])
p.parent.mkdir(parents=True, exist_ok=True)
text = p.read_text(encoding="utf-8") if p.exists() else ""
mode = stat.S_IMODE(p.stat().st_mode) if p.exists() else 0o600
try:
    import tomllib
except ImportError:
    tomllib = None
if tomllib:
    before = tomllib.loads(text)
else:
    if chr(34)*3 in text or chr(39)*3 in text:
        raise SystemExit("TOML multiline requer Python 3.11+ para preservar semanticamente; arquivo nao alterado")
lines = text.splitlines()
sections = {}
current = ""
target = {"features": {"memories": "false"}, "memories": {"use_memories": "false", "generate_memories": "false"}}
for i, line in enumerate(lines):
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    header = re.match(r"^\[([^\[\]]+)\]\s*(?:#.*)?$", stripped)
    if header:
        current = header.group(1).strip()
        if current.strip("\"'") in target and current not in target:
            raise SystemExit("Tabela TOML de memoria com nome entre aspas; revise manualmente, sem alteracao")
        sections.setdefault(current, []).append(i)
        continue
    if stripped.startswith("["):
        current = "__other_table__"
        continue
    root_key = stripped.split("=", 1)[0].strip().split(".", 1)[0].strip("\"'")
    if not current and root_key in target:
        raise SystemExit("Config usa chave TOML inline/dotada para memoria; revise config.toml manualmente")

for sec in ("features", "memories"):
    if len(sections.get(sec, [])) > 1:
        raise SystemExit(f"Tabela [{sec}] duplicada; config.toml nao foi alterado")

if not lines and not text:
    lines = []

for sec in ("memories", "features"):
    keys = target[sec]
    if sec not in sections:
        if lines and lines[-1].strip():
            lines.append("")
        lines.append(f"[{sec}]")
        for key, value in keys.items():
            lines.append(f"{key} = {value}")
        sections[sec] = [len(lines) - len(keys) - 1]
        continue
    current_starts = []
    for i, line in enumerate(lines):
        m = re.match(r"^\s*\[([^\[\]]+)\]\s*(?:#.*)?$", line.strip())
        if m and m.group(1).strip() == sec:
            current_starts.append(i)
    if len(current_starts) != 1:
        raise SystemExit(f"Tabela [{sec}] ficou ambigua; config.toml nao foi alterado")
    start = current_starts[0]
    end = len(lines)
    for j in range(start + 1, len(lines)):
        if lines[j].lstrip().startswith("["):
            end = j
            break
    present = {}
    for i in range(start + 1, end):
        raw_key = lines[i].split("=", 1)[0].strip()
        if raw_key.strip("\"'") in keys and raw_key not in keys:
            raise SystemExit("Chave TOML de memoria entre aspas; revise manualmente, sem alteracao")
        m = re.match(r"^\s*([A-Za-z0-9_-]+)\s*=", lines[i])
        if m and m.group(1) in keys:
            present.setdefault(m.group(1), []).append(i)
    for key, value in keys.items():
        matches = present.get(key, [])
        if len(matches) > 1:
            raise SystemExit(f"Chave duplicada [{sec}].{key}; config.toml nao foi alterado")
        if matches:
            i = matches[0]
            old = lines[i]
            m = re.match(r"^(\s*[A-Za-z0-9_-]+\s*=\s*)(.*?)(\s+#.*)?$", old)
            if not m:
                raise SystemExit(f"Formato nao reconhecido para [{sec}].{key}; config.toml nao foi alterado")
            lines[i] = m.group(1) + value + (m.group(3) or "")
        else:
            lines.insert(end, f"{key} = {value}")
            end += 1

new_text = "\n".join(lines).rstrip() + "\n"
if tomllib:
    after = tomllib.loads(new_text)
    expected = copy.deepcopy(before)
    for section, keys in target.items():
        existing = expected.setdefault(section, {})
        if not isinstance(existing, dict):
            raise SystemExit("Tabela de memoria TOML nao e objeto; nenhuma alteracao")
        existing.update({key: False for key in keys})
    if after != expected:
        raise SystemExit("Edicao alteraria outra configuracao TOML; nenhuma alteracao")
fd, tmp = tempfile.mkstemp(prefix=".config.toml.", dir=str(p.parent))
try:
    os.fchmod(fd, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(new_text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, p)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
  printf 'Memoria nativa do Codex: desativada em %s\n' "$CODEX_CONFIG"
}

# Resolve an official release asset and its GitHub API SHA-256 digest.
release_asset_metadata() {
  local repo="$1" asset="$2" api_json="$TMP_WORKDIR/release.json"
  curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 \
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

verify_native_memory_off() {
  python3 - "$CLAUDE_SETTINGS" "$CODEX_CONFIG" <<'PY'
import json, pathlib, re, sys
settings = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if settings.get("autoMemoryEnabled") is not False:
    raise SystemExit("Memoria nativa Claude Code nao esta desativada")
text = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
def has_false(section, key):
    lines = text.splitlines()
    active = False
    found = []
    for line in lines:
        stripped = line.strip()
        header = re.match(r'^\[([^\[\]]+)\]', stripped)
        if header:
            active = header.group(1) == section
            continue
        if stripped.startswith("["):
            active = False
            continue
        if active:
            m = re.match(r'^' + re.escape(key) + r'\s*=\s*(false|true)\b', stripped)
            if m:
                found.append(m.group(1))
    return found == ["false"]
if not has_false("features", "memories"):
    raise SystemExit("features.memories nao esta false no Codex")
if not has_false("memories", "use_memories") or not has_false("memories", "generate_memories"):
    raise SystemExit("Memorias nativas Codex nao estao totalmente desativadas")
PY
}
verify_plugins() {
  local name="$1"
  if selected claude; then claude plugin list --json > "$TMP_WORKDIR/claude-plugins.json"; fi
  if selected codex; then codex plugin list --json > "$TMP_WORKDIR/codex-plugins.json"; fi
  python3 - "$name" "$TMP_WORKDIR/claude-plugins.json" "$TMP_WORKDIR/codex-plugins.json" "$CLIENTS" <<'PY'
import json, pathlib, sys
name, claude_path, codex_path, clients = sys.argv[1:]
clients=clients.split(",")
if "claude" in clients:
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
if "codex" in clients:
    codex = json.loads(pathlib.Path(codex_path).read_text())
    if not isinstance(codex, dict) or not isinstance(codex.get("installed"), list):
        raise SystemExit("Formato de codex plugin list --json nao reconhecido")
    hits = [e for e in codex["installed"] if isinstance(e, dict) and e.get("name") == name and e.get("marketplaceName") == name]
    if len(hits) != 1 or hits[0].get("installed") is not True or hits[0].get("enabled") is not True:
        raise SystemExit(f"Codex: plugin {name} nao confirmado instalado e habilitado")
print(f"Plugins {name}: clientes selecionados conferidos")
PY
}
edit_client_json() {
  local mode="$1" file="$2" kind="$3" name="$4"; shift 4
  assert_regular_or_absent "$file"
  [[ "$mode" != apply ]] || backup_path "$file"
  python3 - "$mode" "$file" "$kind" "$name" "$OPENCODE_MAJOR" "$@" <<'PY'
import json, os, pathlib, re, stat, sys, tempfile
mode, filename, kind, name, major = sys.argv[1:6]
args = sys.argv[6:]
p = pathlib.Path(filename)
original = p.read_text() if p.exists() else '{}\n'
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
if kind=='memory':
    changes=[((key,),False,True) for key in ('github.copilot.chat.tools.memory.enabled','github.copilot.chat.copilotMemory.enabled')]
else:
    command=args[0]; argv=args[1:]
    entry={'command':command,'args':argv}
    if kind=='cline':
        entry.update(disabled=False,autoApprove=[]); path=('mcpServers',name)
    elif kind=='copilot':
        entry.update(type='local',tools=['*']); path=('mcpServers',name)
    elif kind=='vscode':
        entry.update(type='stdio'); path=('servers',name)
    elif kind=='opencode':
        entry={'type':'local','command':[command]+argv}
        entry.update({'disabled':False} if major=='2' else {'enabled':True})
        path=('mcp','servers',name) if major=='2' else ('mcp',name)
    else: raise ValueError('Cliente desconhecido')
    changes=[(path,entry,False)]
if kind=='opencode':
    root,_,_=parse(original)
    current=root.get('mcp',{})
    if not isinstance(current,dict): raise ValueError('mcp precisa ser objeto')
    if major=='1' and 'servers' in current: raise ValueError('Encontrado schema MCP v2; confira --opencode-major')
    if major=='2' and any(isinstance(v,dict) and 'type' in v for v in current.values()):
        raise ValueError('Encontrado schema MCP v1; migre antes de instalar no v2')
text=original
for path,expected,replace in changes:
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
                if not replace: raise ValueError(f'Conflito MCP {name}: {filename}; nenhuma entrada substituida')
                a,b=spans[path]; text=text[:a]+json.dumps(expected)+text[b:]
        node=node[key]
# Verify all resulting settings before committing the file.
root,_,_=parse(text)
for path,expected,_ in changes:
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
        if (p.read_text() if p.exists() else '{}\n')!=original: raise ValueError('Arquivo mudou durante a edicao')
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
        *) [[ -z "$PROJECT_DIR" ]] || argv+=(--project "$PROJECT_DIR") ;;
      esac
      # Keep the original argument order for existing Claude/Codex installations.
      if [[ "$client" == claude || "$client" == codex ]]; then
        argv=(start-mcp-server --context "$context" --project-from-cwd --add-mode no-memories)
      fi
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


all_mcp check engram "$LOCAL_BIN/engram" mcp --tools=agent
ENGRAM_TAG="$(download_verified_release_asset 'Gentleman-Programming/engram' "@engram-linux-$ASSET_ARCH" "$TMP_WORKDIR/engram.tar.gz")"
extract_archive_binary "$TMP_WORKDIR/engram.tar.gz" engram "$TMP_WORKDIR/engram"
install -m 0755 "$TMP_WORKDIR/engram" "$LOCAL_BIN/engram"
printf 'Engram instalado: %s\n' "$ENGRAM_TAG"

if selected claude; then set_claude_auto_memory_off; "$LOCAL_BIN/engram" setup claude-code; fi
if selected codex; then set_codex_native_memory_off; "$LOCAL_BIN/engram" setup codex; fi
all_mcp apply engram "$LOCAL_BIN/engram" mcp --tools=agent
all_mcp verify engram "$LOCAL_BIN/engram" mcp --tools=agent
if selected claude && selected codex; then verify_native_memory_off; fi
verify_plugins engram
"$LOCAL_BIN/engram" version
"$LOCAL_BIN/engram" mcp --help >/dev/null
cat > "$TMP_WORKDIR/engram-rules.md" <<'RULES'
# Engram: exclusive persistent agent memory
Use only Engram MCP for persistent memories. Do not create or update a Memory Bank,
Serena memories, native Copilot memories, or memory notes in AGENTS.md/CLAUDE.md.
Instruction files are configuration, not storage for learned facts.
At session start, call mem_session_start with the actual workspace directory;
use the returned session/project identity instead of inventing project names.
Use mem_context then mem_search to retrieve relevant prior work; get full records
with mem_get_observation. Save durable decisions and fixes with mem_save, using
the session identity, a descriptive topic_key, and What/Why/Where/Learned.
Update existing topics instead of duplicating them. Before finishing, write a
mem_session_summary and close the session with mem_session_end when appropriate.
Never store secrets, credentials or private raw logs in memory. If memory calls fail,
report that briefly and still deliver the requested work. Do not start another store.
RULES
new_client_rules "$TMP_WORKDIR/engram-rules.md"
if selected vscode; then
  edit_client_json apply "$VSCODE_USER_DIR/settings.json" memory engram
  edit_client_json verify "$VSCODE_USER_DIR/settings.json" memory engram
fi
if selected copilot || selected vscode; then
  printf '\nACAO MANUAL: desative Copilot Memory nas configuracoes da conta GitHub. Revise overrides do workspace/perfil. Veja README.\n'
fi


printf '\nConcluido: Engram instalado/configurado para o usuario.\n'
printf 'Backup: %s\nLog: %s\n' "$BACKUP_DIR" "$LOG_FILE"
printf 'Reinicie os agentes para carregar a integracao.
'
if selected codex; then printf 'No Codex, abra /hooks para revisar e confiar nos hooks do plugin e inicie nova sessao.
'; fi
if [[ ":$ORIGINAL_PATH:" != *":$LOCAL_BIN:"* ]]; then
  printf 'Inclua %s no PATH das sessoes que iniciam os agentes.\n' "$LOCAL_BIN"
fi
