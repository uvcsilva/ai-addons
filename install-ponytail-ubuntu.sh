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
CLIENTS="claude,codex"
PROJECT_DIR=""
CLINE_CONFIG="${CLINE_MCP_SETTINGS_PATH:-$HOME_DIR/.cline/data/settings/cline_mcp_settings.json}"
OPENCODE_DIR="${XDG_CONFIG_HOME:-$HOME_DIR/.config}/opencode"
OC_CONFIG_FILE=""
OPENCODE_MAJOR=""
COPILOT_DIR="${COPILOT_HOME:-$HOME_DIR/.copilot}"
VSCODE_USER_DIR="${XDG_CONFIG_HOME:-$HOME_DIR/.config}/Code/User"
PONYTAIL_MODE="ultra"
PONYTAIL_QUIET=""
PONYTAIL_HIDE=""
PONYTAIL_CONFIG="${XDG_CONFIG_HOME:-$HOME_DIR/.config}/ponytail/config.json"
selected() { [[ ",$CLIENTS," == *",$1,"* ]]; }


usage() {
  cat <<EOF
Uso: $SCRIPT_NAME [opcoes]

Instala e configura somente Ponytail no escopo do usuario do Ubuntu.
Integra somente os clientes selecionados. Consulte a matriz de compatibilidade no README.

  --dry-run  Mostra o plano, sem rede, arquivos, logs ou alteracoes.
  --help     Mostra esta ajuda.
  --clients LISTA  claude,codex,cline,opencode,copilot,vscode ou all.
                   Padrao: claude,codex. copilot = CLI; vscode = Copilot VS Code.
  --cline-config ARQUIVO  MCP do Cline CLI ou extensao (caminho absoluto).
  --vscode-user-dir DIR   Pasta User do perfil VS Code no Ubuntu.
  --opencode-major 1|2    Schema instalado; senao detecta opencode --version.
  --project-dir DIR      Projeto fixo do Serena nos novos clientes (opcional).
  --mode lite|full|ultra Nivel padrao do Ponytail. Padrao: ultra.
                         Claude/Codex: defaultMode em ~/.config/ponytail/config.json;
                         novos clientes: nivel incorporado nas regras.
  --quiet-startup true|false  quietStartup do config.json (oculta o aviso de inicio).
  --hide-status true|false    hideStatus do config.json (oculta o selo de nivel).
                              Sem a opcao, o valor existente e preservado.
OpenRouter: selecione cline/opencode e configure o provedor no proprio cliente.
RTK/Ponytail nos novos clientes: regras, sem hooks nem comandos de plugin.

Pre-requisitos: git, node, python3, flock.
Nao usa sudo. Requer apenas os clientes selecionados; veja limites no README.
Usa o marketplace oficial DietrichGebert/ponytail; registra versoes no log. Novos clientes: regras oficiais incorporadas, commit 9b58c1ffb790c075ca32e70a89cf1d80588f4abf.
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
    --clients|--cline-config|--vscode-user-dir|--opencode-major|--project-dir|--mode|--quiet-startup|--hide-status)
      (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || { printf 'Falta valor para %s\n' "$1" >&2; exit 2; }
      case "$1" in
        --clients) CLIENTS="$2" ;;
        --quiet-startup) PONYTAIL_QUIET="$2" ;;
        --hide-status) PONYTAIL_HIDE="$2" ;;
        --mode) PONYTAIL_MODE="$2" ;;
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
case "$PONYTAIL_MODE" in lite|full|ultra) ;; *) printf 'Use --mode lite, full ou ultra\n' >&2; exit 2 ;; esac
for value in "$PONYTAIL_QUIET" "$PONYTAIL_HIDE"; do
  case "$value" in ''|true|false) ;; *) printf 'Use true ou false em --quiet-startup/--hide-status\n' >&2; exit 2 ;; esac
done
for path in "$CLINE_CONFIG" "$VSCODE_USER_DIR" "$OPENCODE_DIR" "$COPILOT_DIR" "${PROJECT_DIR:-/}" "$PONYTAIL_CONFIG"; do
  [[ "$path" == /* && "$path" != *$'\n'* ]] || { printf 'Caminho precisa ser absoluto, sem quebra de linha: %s\n' "$path" >&2; exit 2; }
done
if [[ "$DRY_RUN" == 1 ]]; then
  cat <<EOF
Simulacao de Ponytail: sem alteracoes e sem acesso a rede.
  Clientes: $CLIENTS
  Cline MCP: $CLINE_CONFIG
  OpenCode: $OPENCODE_DIR (major: ${OPENCODE_MAJOR:-detectar})
  Copilot CLI: $COPILOT_DIR
  VS Code User: $VSCODE_USER_DIR
  Serena projeto novos clientes: ${PROJECT_DIR:-ativacao durante a sessao}
  • Exigir Ubuntu, usuario sem sudo e: git, node, python3, flock.
  • Plugin oficial em Claude/Codex selecionados.
  • Nivel padrao: $PONYTAIL_MODE (Claude/Codex: $PONYTAIL_CONFIG).
  • quietStartup: ${PONYTAIL_QUIET:-preservar}; hideStatus: ${PONYTAIL_HIDE:-preservar}.
  • Regras oficiais incorporadas nos quatro novos clientes selecionados, no nivel $PONYTAIL_MODE.
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
for cmd in git node python3 flock; do
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
# defaultMode e lido pelos hooks oficiais (ponytail-config.js) no inicio de cada sessao.
set_ponytail_default_mode() {
  assert_regular_or_absent "$PONYTAIL_CONFIG"
  backup_path "$PONYTAIL_CONFIG"
  python3 - "$PONYTAIL_CONFIG" "$PONYTAIL_MODE" "${PONYTAIL_QUIET:-}" "${PONYTAIL_HIDE:-}" <<'PY'
import json, os, pathlib, stat, sys, tempfile
p, mode, quiet, hide = pathlib.Path(sys.argv[1]), *sys.argv[2:]
if p.exists():
    try:
        data = json.loads(p.read_text(encoding="utf-8-sig") or "{}")
    except Exception as exc:
        raise SystemExit(f"{p} nao e JSON valido; nenhuma alteracao feita: {exc}")
    if not isinstance(data, dict):
        raise SystemExit(f"{p} precisa conter um objeto JSON no topo")
    file_mode = stat.S_IMODE(p.stat().st_mode)
else:
    data, file_mode = {}, 0o600
wanted = {"defaultMode": mode}
for key, value in (("quietStartup", quiet), ("hideStatus", hide)):
    if value:
        wanted[key] = value == "true"
if any(data.get(key) != value for key, value in wanted.items()):
    data.update(wanted)
    p.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".config.json.", dir=str(p.parent))
    try:
        os.fchmod(fd, file_mode)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
        os.replace(tmp, p)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
print(f"Ponytail: {', '.join(f'{k}={v}' for k, v in wanted.items())} em {p}")
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
import json, os, pathlib, re, shutil, stat, sys, tempfile
mode, filename, kind, name, major = sys.argv[1:6]
args = sys.argv[6:]
p = pathlib.Path(filename)
def current():
    text=p.read_text() if p.exists() else ''
    # Arquivo vazio (comum no settings.json do VS Code) equivale a objeto vazio.
    return text if text.strip() else '{}\n'
original = current()
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
        if current()!=original: raise ValueError('Arquivo mudou durante a edicao')
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


if selected claude; then
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
fi
if selected codex; then
# Reexecucao: aceita marketplace/plugin ja presentes, como no fluxo do Claude.
if ! codex plugin marketplace add DietrichGebert/ponytail > "$TMP_WORKDIR/ponytail-codex-marketplace.txt" 2>&1; then
  cat "$TMP_WORKDIR/ponytail-codex-marketplace.txt"
  grep -qi 'already' "$TMP_WORKDIR/ponytail-codex-marketplace.txt" || die 'Falha ao adicionar o marketplace Ponytail no Codex.'
else
  cat "$TMP_WORKDIR/ponytail-codex-marketplace.txt"
fi
codex plugin list --json > "$TMP_WORKDIR/codex-plugins.json"
codex_ponytail_state="$(python3 - "$TMP_WORKDIR/codex-plugins.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
if not isinstance(data, dict) or not isinstance(data.get("installed"), list):
    raise SystemExit("Formato de codex plugin list --json nao reconhecido")
hits = [e for e in data["installed"] if isinstance(e, dict) and e.get("name") == "ponytail" and e.get("marketplaceName") == "ponytail"]
print("matching" if len(hits) == 1 and hits[0].get("installed") is True and hits[0].get("enabled") is True else "absent")
PY
)" || die 'Nao foi possivel conferir o plugin Ponytail no Codex.'
if [[ "$codex_ponytail_state" == matching ]]; then
  printf 'Plugin Codex ponytail ja instalado e habilitado.\n'
else
  codex plugin add ponytail@ponytail
fi
fi
verify_plugins ponytail
if selected claude || selected codex; then
  set_ponytail_default_mode
  [[ -z "${PONYTAIL_DEFAULT_MODE:-}" || "$PONYTAIL_DEFAULT_MODE" == "$PONYTAIL_MODE" ]] \
    || printf 'AVISO: PONYTAIL_DEFAULT_MODE=%s no ambiente tem prioridade sobre o config.json.\n' "$PONYTAIL_DEFAULT_MODE"
fi
cat > "$TMP_WORKDIR/ponytail-rules.md" <<'PONYTAIL_RULES'
<!-- Fonte oficial DietrichGebert/ponytail/AGENTS.md; commit 9b58c1ffb790c075ca32e70a89cf1d80588f4abf -->
# Ponytail, lazy senior dev mode

You are a lazy senior developer. The best code is the code never written. You solve the whole problem with the least new code. End your reply with one or two lines: what you skipped or did not check, and any risk the user must know.

## Before you write

Read the task and the code it touches. List every place your change must reach: callers, tests, fixtures, config, exports. Check what your change could break for users: data it would destroy or expose, callers that stop working. That is scope. Extra features are not.

## The smallest complete change

Take the first option that fully works:

1. Does it need to exist? Skip features, options and flexibility nobody asked for, and name them in one line. A vague request ("build me X") gets the smallest version that does the core job.
2. Already in this codebase (a helper, component, service, pattern)? Use it the way the surrounding code does.
3. Standard library or a platform feature? Use it, unless the project has its own. A house component beats a native widget.
4. An installed dependency? Use it. Never add a dependency for a few lines.
5. Can it be one line a reader gets at a glance? One line.
6. Otherwise: the minimum code that works.

- Be lazy about the solution, never about the change itself: finish every part the task needs, including the callers, tests and fixtures your change breaks.
- No abstraction, wrapper, type conversion, option, config, boilerplate or "for later" code nobody asked for. Keep values in the form the platform already gives you. Deletion beats addition. Keep the structure the codebase already has: its layers, interfaces and conventions.
- The shortest working diff wins, once you know everything it must touch. A one-liner that needs decoding is not short.
- Comment only the why the code cannot show, in one line.
- Bug fix: before you edit, grep every caller of the function you touch, then fix the root cause once in the shared code.
- Code you move or merge keeps its error handling and validation.
- Between options of equal size, take the one that is correct on edge cases.
- Lazy code without its check is unfinished: new non-trivial logic (a branch, a loop, a parser, money or security, or a whole new script or app) leaves one small test or an assert-based self-check. Trivial changes need none.
- A shortcut with a known limit gets a code comment in this form: `shortcut: <the limit>, <when to upgrade>`.

Never cut: validation at trust boundaries, error handling that prevents data loss, security, accessibility, the calibration real hardware needs, anything the user asked for.

(Yes, this file also applies to agents working on the ponytail repo itself. Especially to them.)

PONYTAIL_RULES
# Sem hooks, os novos clientes recebem o nivel como regra (tabela Levels do SKILL.md oficial).
case "$PONYTAIL_MODE" in
  lite) printf '## Level: lite\n\nBuild what was asked. Name the smaller option in one line and let the user pick.\n' >> "$TMP_WORKDIR/ponytail-rules.md" ;;
  ultra) printf '## Level: ultra\n\nAlso question the request: before building, push back on any part the need does not justify.\n' >> "$TMP_WORKDIR/ponytail-rules.md" ;;
esac
new_client_rules "$TMP_WORKDIR/ponytail-rules.md"


printf '\nConcluido: Ponytail instalado/configurado para o usuario.\n'
printf 'Backup: %s\nLog: %s\n' "$BACKUP_DIR" "$LOG_FILE"
printf 'Reinicie os agentes para carregar a integracao.
'
if selected codex; then printf 'No Codex, abra /hooks para revisar e confiar nos hooks do plugin e inicie nova sessao.
'; fi
if [[ ":$ORIGINAL_PATH:" != *":$LOCAL_BIN:"* ]]; then
  printf 'Inclua %s no PATH das sessoes que iniciam os agentes.\n' "$LOCAL_BIN"
fi
