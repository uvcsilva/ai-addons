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

usage() {
  cat <<EOF
Uso: $SCRIPT_NAME [--dry-run | --help]

Instala e configura somente Engram no escopo do usuario do Ubuntu.
Configura Engram como unica memoria persistente e desativa as memorias nativas dos dois agentes.

  --dry-run  Mostra o plano, sem rede, arquivos, logs ou alteracoes.
  --help     Mostra esta ajuda.

Pre-requisitos: curl, git, jq, python3, sha256sum, flock, claude, codex.
Nao usa sudo. Requer os dois CLIs ja instalados e autenticados.
Baixa a release estavel mais recente com SHA-256; usa os setups oficiais dos dois agentes.
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
Simulacao de Engram: sem alteracoes e sem acesso a rede.
  • Exigir Ubuntu, usuario sem sudo e: curl, git, jq, python3, sha256sum, flock, claude, codex.
  • Instalar Engram verificado em ~/.local/bin.
  • Desativar memorias nativas e executar setup claude-code e setup codex.
  • Conferir MCPs, plugins e configuracao de memoria.
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
for cmd in curl git jq python3 sha256sum flock claude codex; do
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
assert_regular_or_absent "$CODEX_DIR/engram-instructions.md"
backup_path "$CODEX_DIR/engram-instructions.md"
assert_regular_or_absent "$CODEX_DIR/engram-compact-prompt.md"
backup_path "$CODEX_DIR/engram-compact-prompt.md"
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


claude_mcp_state engram "$LOCAL_BIN/engram" mcp --tools=agent >/dev/null || die 'Revise a entrada Claude MCP engram antes de prosseguir.'
codex_mcp_state engram "$LOCAL_BIN/engram" mcp --tools=agent >/dev/null || die 'Revise a entrada Codex MCP engram antes de prosseguir.'

ENGRAM_TAG="$(download_verified_release_asset 'Gentleman-Programming/engram' "@engram-linux-$ASSET_ARCH" "$TMP_WORKDIR/engram.tar.gz")"
extract_archive_binary "$TMP_WORKDIR/engram.tar.gz" engram "$TMP_WORKDIR/engram"
install -m 0755 "$TMP_WORKDIR/engram" "$LOCAL_BIN/engram"
printf 'Engram instalado: %s\n' "$ENGRAM_TAG"
set_claude_auto_memory_off
set_codex_native_memory_off
"$LOCAL_BIN/engram" setup claude-code
"$LOCAL_BIN/engram" setup codex
"$LOCAL_BIN/engram" version
"$LOCAL_BIN/engram" mcp --help >/dev/null
[[ "$(claude_mcp_state engram "$LOCAL_BIN/engram" mcp --tools=agent)" == matching ]] || die 'Verificacao Claude MCP engram falhou.'
[[ "$(codex_mcp_state engram "$LOCAL_BIN/engram" mcp --tools=agent)" == matching ]] || die 'Verificacao Codex MCP engram falhou.'
codex mcp list --json >/dev/null
verify_native_memory_off
verify_plugins engram

printf '\nConcluido: Engram instalado/configurado para o usuario.\n'
printf 'Backup: %s\nLog: %s\n' "$BACKUP_DIR" "$LOG_FILE"
printf 'Reinicie os agentes para carregar a integracao.
'
printf 'No Codex, abra /hooks para revisar e confiar nos hooks do plugin e inicie nova sessao.
'
if [[ ":$ORIGINAL_PATH:" != *":$LOCAL_BIN:"* ]]; then
  printf 'Inclua %s no PATH das sessoes que iniciam os agentes.\n' "$LOCAL_BIN"
fi
