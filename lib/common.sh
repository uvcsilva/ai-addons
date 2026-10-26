# shellcheck shell=bash
# Base comum dos instaladores por provedor. Carregue com source depois de
# `set -Eeuo pipefail` e `umask 077`; este arquivo so define variaveis e funcoes.

HOME_DIR="${HOME:?HOME precisa estar definido}"
LOCAL_BIN="$HOME_DIR/.local/bin"
ORIGINAL_PATH="$PATH"
STATE_ROOT="${XDG_STATE_HOME:-$HOME_DIR/.local/state}/six-addons-installer"
INSTALLER=""
TMP_WORKDIR=""
LOG_FILE=""
BACKUP_DIR=""

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
  printf '\n[FALHA] %s: linha %s, codigo %s.\n' "$INSTALLER" "$line" "$rc" >&2
  [[ -z "$LOG_FILE" ]] || printf '[FALHA] Log: %s\n' "$LOG_FILE" >&2
  [[ -z "$BACKUP_DIR" ]] || printf '[FALHA] Backup: %s\n' "$BACKUP_DIR" >&2
  exit "$rc"
}

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

# Uso: write_managed_rule ARQUIVO ORIGEM ADDON [1 = frontmatter applyTo do VS Code]
write_managed_rule() {
  local file="$1" source="$2" addon="$3" frontmatter="${4:-0}"
  assert_regular_or_absent "$file"
  backup_path "$file"
  python3 - "$file" "$source" "$addon" "$frontmatter" <<'PY'
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

# Remove o bloco six-addons:ADDON quando um plugin nativo passa a cobrir as mesmas regras.
remove_managed_rule() {
  local file="$1" addon="$2"
  assert_regular_or_absent "$file"
  [[ -e "$file" ]] && grep -qF -- "<!-- six-addons:$addon:" "$file" || return 0
  backup_path "$file"
  python3 - "$file" "$addon" <<'PY'
import os,pathlib,stat,sys,tempfile
p,addon=sys.argv[1:]; p=pathlib.Path(p)
old=p.read_text()
start=f'<!-- six-addons:{addon}:begin -->'; end=f'<!-- six-addons:{addon}:end -->'
if old.count(start)!=1 or old.count(end)!=1 or old.index(start)>old.index(end):
    raise ValueError('Bloco gerenciado corrompido; nenhuma alteracao')
# Inverso de write_managed_rule: tira tambem o '\n\n' anterior e o '\n' final que ela acrescenta.
a=old.index(start); b=old.index(end)+len(end)
if old[b:b+1]=='\n': b+=1
if old[max(a-2,0):a]=='\n\n': a-=2
new=old[:a]+old[b:]
fd,tmp=tempfile.mkstemp(prefix='.'+p.name+'.',dir=str(p.parent))
try:
    with os.fdopen(fd,'w') as f:f.write(new)
    os.chmod(tmp,stat.S_IMODE(p.stat().st_mode))
    if p.read_text()!=old: raise ValueError('Arquivo mudou durante a edicao')
    os.replace(tmp,p)
finally:
    if os.path.exists(tmp):os.unlink(tmp)
assert start not in p.read_text() and end not in p.read_text()
print(f'Instrucoes {addon} removidas: {p}')
PY
}

# Uso: installer_begin NOME [COMANDO...]. Confere o sistema e os comandos exigidos,
# toma o bloqueio compartilhado e abre backup, log e diretorio temporario da execucao.
installer_begin() {
  INSTALLER="$1"; shift
  trap cleanup EXIT
  trap 'on_error "$?" "$LINENO"' ERR
  ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))) || die 'Use Bash 4.4 ou superior no Ubuntu.'
  ((EUID != 0)) || die 'Execute com seu usuario normal, sem sudo ou root.'
  [[ -r /etc/os-release ]] || die 'Este instalador requer Ubuntu Linux.'
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == ubuntu && "$(uname -s)" == Linux ]] || die "Destino precisa ser Ubuntu Linux; detectado: ${PRETTY_NAME:-desconhecido}."
  local path cmd missing=()
  for path in "$HOME_DIR" "$STATE_ROOT" "${TMPDIR:-/tmp}"; do
    [[ "$path" == /* ]] || die "Diretorio precisa ser absoluto: $path"
  done
  export PATH="$LOCAL_BIN:$PATH"
  for cmd in python3 flock "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  ((${#missing[@]} == 0)) || die "Pre-requisitos ausentes: ${missing[*]}. Instale pelo gerenciador oficial do Ubuntu/fornecedor e reexecute."
  mkdir -p "$LOCAL_BIN" "$STATE_ROOT/backups"
  chmod 700 "$STATE_ROOT" "$STATE_ROOT/backups"
  [[ ! -L "$STATE_ROOT/install.lock" ]] || die 'O arquivo de bloqueio nao pode ser link simbolico.'
  [[ ! -e "$STATE_ROOT/install.lock" || -f "$STATE_ROOT/install.lock" ]] || die 'O arquivo de bloqueio precisa ser regular.'
  exec 9>"$STATE_ROOT/install.lock"
  flock -n 9 || die 'Outro instalador de addon esta em execucao. Aguarde e reexecute.'
  RUN_ID="$INSTALLER-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  BACKUP_DIR="$STATE_ROOT/backups/$RUN_ID"
  mkdir "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  LOG_FILE="$STATE_ROOT/install-$RUN_ID.log"
  : > "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  TMP_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/addon-$INSTALLER.XXXXXXXX")"
  chmod 700 "$TMP_WORKDIR"
  # Executar CLIs fora de repositorios evita misturar configuracao de projeto.
  cd "$TMP_WORKDIR" || die "Nao foi possivel entrar em $TMP_WORKDIR."
  printf 'Instalador de %s — Ubuntu %s\nUsuario: %s\nLog: %s\n' "$INSTALLER" "${VERSION_ID:-?}" "$HOME_DIR" "$LOG_FILE"
}

installer_end() {
  printf '\nConcluido: %s\n' "$1"
  printf 'Backup: %s\nLog: %s\n' "$BACKUP_DIR" "$LOG_FILE"
  printf 'Reinicie os agentes para carregar a integracao.\n'
  if [[ ":$ORIGINAL_PATH:" != *":$LOCAL_BIN:"* ]]; then
    printf 'Inclua %s no PATH das sessoes que iniciam os agentes.\n' "$LOCAL_BIN"
  fi
}

