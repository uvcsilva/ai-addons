#!/usr/bin/env bash
# Arquivo independente: nao precisa de biblioteca nem dos outros instaladores.
# Fontes oficiais e limites de validacao estao no README.md do pacote.
set -Eeuo pipefail
umask 077

ADDON="rtk"
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
RTK_CONFIG="${XDG_CONFIG_HOME:-$HOME_DIR/.config}/rtk/config.toml"
RTK_INIT_MODE="default"
RTK_TRUST=""
RTK_TELEMETRY=""
RTK_RECALL=""
RTK_AWARENESS=""
RTK_EXCLUDE=""
RTK_TRACKING=""
RTK_HISTORY_DAYS=""
RTK_INIT_FLAGS=()
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

Instala e configura somente RTK no escopo do usuario do Ubuntu.
Integra somente os clientes selecionados. Consulte a matriz de compatibilidade no README.

  --dry-run  Mostra o plano, sem rede, arquivos, logs ou alteracoes.
  --help     Mostra esta ajuda.
  --clients LISTA  claude,codex,cline,opencode,copilot,vscode ou all.
                   Padrao: claude,codex. copilot = CLI; vscode = Copilot VS Code.
  --cline-config ARQUIVO  MCP do Cline CLI ou extensao (caminho absoluto).
  --vscode-user-dir DIR   Pasta User do perfil VS Code no Ubuntu.
  --opencode-major 1|2    Schema instalado; senao detecta opencode --version.
  --project-dir DIR      Projeto fixo do Serena nos novos clientes (opcional).
  --init-mode default|hook-only  Claude/Codex: hook + RTK.md (padrao) ou somente hook.
  --trust-filters true|false     Confiar nos filtros personalizados detectados.
  --telemetry enable|disable     Consentimento de telemetria (rtk telemetry).
  --recall sqlite|tee|disabled   Recuperacao da saida completa (rtk config recall).
  --awareness default|high|full  Quanto as instrucoes contam ao agente sobre o RTK.
  --exclude-commands LISTA       Comandos nunca reescritos (ex.: curl,playwright).
  --tracking true|false          Registro local de economia de tokens.
  --history-days N               Dias de historico do registro local.
                                 Sem estas opcoes, valem os padroes e o config.toml atual.
OpenRouter: selecione cline/opencode e configure o provedor no proprio cliente.
RTK/Ponytail nos novos clientes: regras, sem hooks nem comandos de plugin.

Pre-requisitos: curl, python3, sha256sum, flock.
Nao usa sudo. Requer apenas os clientes selecionados; veja limites no README.
Baixa a release estavel mais recente de RTK e valida o digest SHA-256 oficial.
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
    --clients|--cline-config|--vscode-user-dir|--opencode-major|--project-dir|--init-mode|--trust-filters|--telemetry|--recall|--awareness|--exclude-commands|--tracking|--history-days)
      (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || { printf 'Falta valor para %s\n' "$1" >&2; exit 2; }
      case "$1" in
        --clients) CLIENTS="$2" ;;
        --init-mode) RTK_INIT_MODE="$2" ;;
        --trust-filters) RTK_TRUST="$2" ;;
        --telemetry) RTK_TELEMETRY="$2" ;;
        --recall) RTK_RECALL="$2" ;;
        --awareness) RTK_AWARENESS="$2" ;;
        --exclude-commands) RTK_EXCLUDE="$2" ;;
        --tracking) RTK_TRACKING="$2" ;;
        --history-days) RTK_HISTORY_DAYS="$2" ;;
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
case "$RTK_INIT_MODE" in default) ;; hook-only) RTK_INIT_FLAGS+=(--hook-only) ;; *) printf 'Use --init-mode default ou hook-only\n' >&2; exit 2 ;; esac
case "$RTK_TRUST" in '') ;; true) RTK_INIT_FLAGS+=(--trust-filters) ;; false) RTK_INIT_FLAGS+=(--no-trust-filters) ;; *) printf 'Use --trust-filters true ou false\n' >&2; exit 2 ;; esac
case "$RTK_TELEMETRY" in ''|enable|disable) ;; *) printf 'Use --telemetry enable ou disable\n' >&2; exit 2 ;; esac
case "$RTK_RECALL" in ''|sqlite|tee|disabled) ;; *) printf 'Use --recall sqlite, tee ou disabled\n' >&2; exit 2 ;; esac
case "$RTK_AWARENESS" in ''|default|high|full) ;; *) printf 'Use --awareness default, high ou full\n' >&2; exit 2 ;; esac
case "$RTK_TRACKING" in ''|true|false) ;; *) printf 'Use --tracking true ou false\n' >&2; exit 2 ;; esac
[[ -z "$RTK_HISTORY_DAYS" || "$RTK_HISTORY_DAYS" =~ ^[1-9][0-9]*$ ]] || { printf 'Use --history-days com um inteiro positivo\n' >&2; exit 2; }
for path in "$CLINE_CONFIG" "$VSCODE_USER_DIR" "$OPENCODE_DIR" "$COPILOT_DIR" "${PROJECT_DIR:-/}"; do
  [[ "$path" == /* && "$path" != *$'\n'* ]] || { printf 'Caminho precisa ser absoluto, sem quebra de linha: %s\n' "$path" >&2; exit 2; }
done
if [[ "$DRY_RUN" == 1 ]]; then
  cat <<EOF
Simulacao de RTK: sem alteracoes e sem acesso a rede.
  Clientes: $CLIENTS
  Cline MCP: $CLINE_CONFIG
  OpenCode: $OPENCODE_DIR (major: ${OPENCODE_MAJOR:-detectar})
  Copilot CLI: $COPILOT_DIR
  VS Code User: $VSCODE_USER_DIR
  Serena projeto novos clientes: ${PROJECT_DIR:-ativacao durante a sessao}
  • Exigir Ubuntu, usuario sem sudo e: curl, python3, sha256sum, flock.
  • Instalar RTK em ~/.local/bin com SHA-256 verificado.
  • Hooks em Claude/Codex; regras nos quatro novos clientes selecionados.
  • Init: ${RTK_INIT_FLAGS[*]:-padrao}; telemetria: ${RTK_TELEMETRY:-preservar}; recall: ${RTK_RECALL:-preservar}.
  • config.toml ($RTK_CONFIG): awareness=${RTK_AWARENESS:-preservar}, exclude_commands=${RTK_EXCLUDE:-preservar}, tracking=${RTK_TRACKING:-preservar}, history_days=${RTK_HISTORY_DAYS:-preservar}.
  • Bloquear execucao simultanea dos seis instaladores.
  • Fazer backup antes de alterar configuracoes e criar log privado.
  • Conferir RTK depois da instalacao.
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
  x86_64|amd64) RTK_ASSET='rtk-x86_64-unknown-linux-musl.tar.gz' ;;
  aarch64|arm64) RTK_ASSET='rtk-aarch64-unknown-linux-gnu.tar.gz' ;;
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
assert_regular_or_absent "$LOCAL_BIN/rtk"
backup_path "$LOCAL_BIN/rtk"
assert_regular_or_absent "$RTK_CONFIG"
backup_path "$RTK_CONFIG"

# Edita somente as chaves pedidas no config.toml do RTK, preservando o resto do arquivo.
set_rtk_config() {
  python3 - "$RTK_CONFIG" "$RTK_AWARENESS" "$RTK_EXCLUDE" "$RTK_TRACKING" "$RTK_HISTORY_DAYS" <<'PY'
import copy, json, os, pathlib, re, stat, sys, tempfile
p = pathlib.Path(sys.argv[1]); awareness, exclude, tracking, history = sys.argv[2:]
changes = []
if awareness: changes.append(("awareness", "level", awareness))
if exclude: changes.append(("hooks", "exclude_commands", [c.strip() for c in exclude.split(",") if c.strip()]))
if tracking: changes.append(("tracking", "enabled", tracking == "true"))
if history: changes.append(("tracking", "history_days", int(history)))
if not changes:
    raise SystemExit(0)
text = p.read_text(encoding="utf-8") if p.exists() else ""
mode = stat.S_IMODE(p.stat().st_mode) if p.exists() else 0o600
try:
    import tomllib
except ImportError:
    tomllib = None
if tomllib:
    before = tomllib.loads(text)
elif chr(34) * 3 in text or chr(39) * 3 in text:
    raise SystemExit("TOML multiline requer Python 3.11+; config.toml do RTK nao alterado")
def literal(value):
    if isinstance(value, bool): return "true" if value else "false"
    if isinstance(value, int): return str(value)
    if isinstance(value, list): return "[" + ", ".join(json.dumps(v, ensure_ascii=False) for v in value) + "]"
    return json.dumps(value, ensure_ascii=False)
header = re.compile(r"^\s*\[")
lines = text.splitlines()
first_header = next((i for i, l in enumerate(lines) if header.match(l)), len(lines))
for section, key, value in changes:
    if any(re.match(r"^\s*" + section + r"\s*[.=]", l) for l in lines[:first_header]):
        raise SystemExit(f"config.toml define {section} fora de uma tabela; revise manualmente, sem alteracao")
    starts = [i for i, l in enumerate(lines) if re.match(r"^\s*\[\s*" + section + r"\s*\]\s*(#.*)?$", l)]
    if len(starts) > 1:
        raise SystemExit(f"Tabela [{section}] duplicada; config.toml nao alterado")
    entry = f"{key} = {literal(value)}"
    if not starts:
        if lines and lines[-1].strip(): lines.append("")
        lines += [f"[{section}]", entry]
        continue
    start = starts[0]
    end = next((j for j in range(start + 1, len(lines)) if header.match(lines[j])), len(lines))
    hits = [i for i in range(start + 1, end) if re.match(r"^\s*" + key + r"\s*=", lines[i])]
    if len(hits) > 1:
        raise SystemExit(f"Chave duplicada [{section}].{key}; config.toml nao alterado")
    if hits:
        if lines[hits[0]].count("[") > lines[hits[0]].count("]"):
            raise SystemExit(f"[{section}].{key} ocupa varias linhas; revise manualmente, sem alteracao")
        lines[hits[0]] = entry
    else:
        last = max([start] + [i for i in range(start + 1, end) if lines[i].strip()])
        lines.insert(last + 1, entry)
new_text = "\n".join(lines).rstrip() + "\n"
if tomllib:
    expected = copy.deepcopy(before)
    for section, key, value in changes:
        table = expected.setdefault(section, {})
        if not isinstance(table, dict):
            raise SystemExit(f"{section} nao e tabela TOML; config.toml nao alterado")
        table[key] = value
    if tomllib.loads(new_text) != expected:
        raise SystemExit("Edicao alteraria outra configuracao do RTK; config.toml nao alterado")
if new_text != text:
    p.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".config.toml.", dir=str(p.parent))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(new_text)
        os.replace(tmp, p)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
print("RTK config.toml: " + ", ".join(f"{s}.{k}" for s, k, _ in changes))
PY
}

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


RTK_TAG="$(download_verified_release_asset 'rtk-ai/rtk' "$RTK_ASSET" "$TMP_WORKDIR/rtk.tar.gz")"
extract_archive_binary "$TMP_WORKDIR/rtk.tar.gz" rtk "$TMP_WORKDIR/rtk"
install -m 0755 "$TMP_WORKDIR/rtk" "$LOCAL_BIN/rtk"
printf 'RTK instalado: %s\n' "$RTK_TAG"

# Antes do init: awareness muda as instrucoes que o init grava.
if [[ -n "$RTK_TELEMETRY" ]]; then "$LOCAL_BIN/rtk" telemetry "$RTK_TELEMETRY"; fi
if [[ -n "$RTK_RECALL" ]]; then "$LOCAL_BIN/rtk" config recall "$RTK_RECALL"; fi
set_rtk_config
if selected claude; then "$LOCAL_BIN/rtk" init --global --auto-patch ${RTK_INIT_FLAGS[@]+"${RTK_INIT_FLAGS[@]}"}; fi
if selected codex; then "$LOCAL_BIN/rtk" init --global --codex ${RTK_INIT_FLAGS[@]+"${RTK_INIT_FLAGS[@]}"}; fi
"$LOCAL_BIN/rtk" --version
if selected cline || selected opencode || selected copilot || selected vscode; then
  "$LOCAL_BIN/rtk" init --agent cline
  [[ -s "$TMP_WORKDIR/.clinerules" ]] || die 'RTK nao gerou instrucoes esperadas.'
  new_client_rules "$TMP_WORKDIR/.clinerules"
fi
python3 - "$CLIENTS" "$CLAUDE_SETTINGS" "$CODEX_DIR/hooks.json" <<'PY'
import json,pathlib,sys
clients=sys.argv[1].split(',')
for client,path in zip(('claude','codex'),sys.argv[2:]):
    if client not in clients:continue
    data=json.loads(pathlib.Path(path).read_text())
    commands=[h.get('command','') for g in data.get('hooks',{}).get('PreToolUse',[]) for h in g.get('hooks',[])]
    if not any('rtk' in c and 'hook' in c for c in commands):raise ValueError('Hook RTK ausente: '+client)
print('RTK: hooks dos clientes nativos selecionados conferidos')
PY


printf '\nConcluido: RTK instalado/configurado para o usuario.\n'
printf 'Backup: %s\nLog: %s\n' "$BACKUP_DIR" "$LOG_FILE"
printf 'Reinicie os agentes para carregar a integracao.
'
if [[ ":$ORIGINAL_PATH:" != *":$LOCAL_BIN:"* ]]; then
  printf 'Inclua %s no PATH das sessoes que iniciam os agentes.\n' "$LOCAL_BIN"
fi
