#!/usr/bin/env bash
# Prepara as dependencias comuns dos sete instaladores no Ubuntu.
set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly HOME_DIR="${HOME:?HOME precisa estar definido}"
readonly LOCAL_BIN="$HOME_DIR/.local/bin"
readonly NODE_ROOT="$HOME_DIR/.local/lib/nodejs"
readonly NPM_REGISTRY="https://registry.npmjs.org"
TMP_DIR=""
CLIENTS="codex"
WITH_OPENCODE=false
UPGRADE=false
selected() { [[ ",$CLIENTS," == *",$1,"* ]]; }

die() {
  printf '[ERRO] %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

prune_old_node() {
  local dir
  [[ -n "$NODE_ROOT" && -n "$NODE_DIST" ]] || die 'NODE_ROOT/NODE_DIST vazios; nada removido.'
  for dir in "$NODE_ROOT"/node-v*-linux-*; do
    [[ -d "$dir" && ! -L "$dir" && "${dir##*/}" != "$NODE_DIST" ]] || continue
    rm -rf -- "$dir"
    printf 'Node antigo removido: %s\n' "$dir"
  done
}

usage() {
  cat <<EOF
Uso: bash $SCRIPT_NAME [--clients LISTA] [--with-opencode] [--upgrade]

Prepara os pre-requisitos para os seis addons no Ubuntu:
  curl, git, jq, Python 3, sha256sum, flock, Node.js LTS, npm, npx e os CLIs
  dos clientes selecionados (Codex CLI sempre).

  --clients LISTA  claude,codex,kimi,cline,opencode,copilot,vscode,antigravity ou all.
                   Padrao: codex. Instala via npm, somente se ausente:
                   claude=@anthropic-ai/claude-code, codex=@openai/codex,
                   kimi=@moonshot-ai/kimi-code, cline=cline, opencode=opencode-ai@1,
                   copilot=@github/copilot. vscode e antigravity sao instalados separadamente.
                   Use a mesma lista depois nos instaladores de provedor.
  --with-opencode  Equivale a incluir opencode em --clients.
                   Preserva OpenCode 1 ou 2 existente e valida sua versao.
  --upgrade        Atualiza os CLIs selecionados que este script instalou em
                   ~/.local (OpenCode somente dentro do major 1). Instalacoes
                   de outra origem sao preservadas.
  --help           Mostra esta ajuda.

Execute como usuario normal. O script usa sudo somente para instalar pacotes do
Ubuntu e nao autentica os clientes. Na primeira execucao, rode: codex login
(e claude, cline auth, copilot e kimi, depois /login, conforme os clientes).
EOF
}

while (($#)); do
  case "$1" in
    --with-opencode) WITH_OPENCODE=true ;;
    --upgrade) UPGRADE=true ;;
    --clients)
      (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || die 'Falta valor para --clients.'
      CLIENTS="$2"
      shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Opcao desconhecida: $1. Use --help." ;;
  esac
  shift
done
normalize_clients() {
  local client
  local -a client_list
  [[ "$CLIENTS" != all ]] || CLIENTS='claude,codex,kimi,cline,opencode,copilot,vscode,antigravity'
  [[ "$CLIENTS" != ,* && "$CLIENTS" != *, && "$CLIENTS" != *,,* ]] || die 'Lista de clientes invalida.'
  IFS=, read -r -a client_list <<< "$CLIENTS"
  for client in "${client_list[@]}"; do
    case "$client" in
      claude|codex|kimi|cline|opencode|copilot|vscode|antigravity) ;;
      openrouter) die 'OpenRouter e provedor: use --clients cline,opencode e escolha OpenRouter no cliente.' ;;
      *) die "Cliente desconhecido: $client" ;;
    esac
  done
  # Codex continua sendo instalado sempre, como antes da opcao --clients.
  selected codex || CLIENTS="codex,$CLIENTS"
  if "$WITH_OPENCODE" && ! selected opencode; then CLIENTS="$CLIENTS,opencode"; fi
}
normalize_clients

[[ "${EUID:-$(id -u)}" -ne 0 ]] || die 'Execute como usuario normal, sem sudo.'
[[ -r /etc/os-release ]] || die 'Nao foi possivel identificar a distribuicao Linux.'
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == ubuntu ]] || die 'Este script foi feito para Ubuntu.'
command -v sudo >/dev/null 2>&1 || die 'O comando sudo e necessario para instalar pacotes do Ubuntu.'
command -v dpkg >/dev/null 2>&1 || die 'dpkg nao foi encontrado.'

case "$(dpkg --print-architecture)" in
  amd64) NODE_ARCH='x64' ;;
  arm64) NODE_ARCH='arm64' ;;
  *) die "Arquitetura nao suportada: $(dpkg --print-architecture). Use Ubuntu amd64 ou arm64." ;;
esac

# Detecta conflitos antes de alterar os pacotes do sistema ou baixar arquivos.
[[ ! -e "$NODE_ROOT/current" || -L "$NODE_ROOT/current" ]] \
  || die "$NODE_ROOT/current precisa ser um link simbolico; nao sera sobrescrito."
for binary in node npm npx; do
  link="$LOCAL_BIN/$binary"
  target="$NODE_ROOT/current/bin/$binary"
  if [[ -e "$link" || -L "$link" ]]; then
    if [[ ! -L "$link" ]] || [[ "$(readlink "$link")" != "$target" ]]; then
      die "$link ja existe e nao pertence a este instalador; resolva esse conflito antes de continuar."
    fi
  fi
done

sudo -v
printf '[1/5] Instalando ferramentas e bibliotecas basicas do Ubuntu...\n'
sudo apt-get update
sudo apt-get install -y ca-certificates coreutils curl git jq python3 tar util-linux xz-utils
command -v curl >/dev/null 2>&1 || die 'curl nao foi instalado.'
command -v python3 >/dev/null 2>&1 || die 'python3 nao foi instalado.'

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/addons-prereqs.XXXXXX")"
NODE_INDEX="$TMP_DIR/node-index.json"
printf '[2/5] Consultando a versao LTS atual do Node.js...\n'
curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 \
  'https://nodejs.org/dist/index.json' -o "$NODE_INDEX"
NODE_VERSION="$(python3 - "$NODE_INDEX" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    releases = json.load(f)

for release in releases:
    version = release.get("version", "")
    if release.get("lts") and re.fullmatch(r"v\d+\.\d+\.\d+", version):
        print(version)
        break
else:
    raise SystemExit("Nao foi possivel identificar uma versao LTS do Node.js.")
PY
)"
NODE_DIST="node-${NODE_VERSION}-linux-${NODE_ARCH}"
NODE_DEST="$NODE_ROOT/$NODE_DIST"

mkdir -p "$LOCAL_BIN" "$NODE_ROOT"
if [[ ! -x "$NODE_DEST/bin/node" || ! -x "$NODE_DEST/bin/npm" || ! -x "$NODE_DEST/bin/npx" ]]; then
  NODE_ARCHIVE="$TMP_DIR/$NODE_DIST.tar.xz"
  NODE_SHA256_LIST="$TMP_DIR/SHASUMS256.txt"
  printf '[3/5] Baixando o Node.js e validando o SHA-256 publicado...\n'
  curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 \
    "https://nodejs.org/dist/$NODE_VERSION/$NODE_DIST.tar.xz" -o "$NODE_ARCHIVE"
  curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 \
    "https://nodejs.org/dist/$NODE_VERSION/SHASUMS256.txt" -o "$NODE_SHA256_LIST"
  EXPECTED_SHA256="$(python3 - "$NODE_SHA256_LIST" "$NODE_DIST.tar.xz" <<'PY'
import re
import sys

checksum_file, expected_name = sys.argv[1:]
matches = []
with open(checksum_file, encoding="utf-8") as f:
    for line in f:
        parts = line.split()
        if len(parts) >= 2 and parts[-1].lstrip("*") == expected_name:
            matches.append(parts[0])

if len(matches) != 1 or not re.fullmatch(r"[0-9a-fA-F]{64}", matches[0]):
    raise SystemExit(f"Checksum SHA-256 ausente ou ambiguo para {expected_name}.")
print(matches[0])
PY
)"
  printf '%s  %s\n' "$EXPECTED_SHA256" "$NODE_ARCHIVE" | sha256sum --check --status \
    || die 'O SHA-256 do arquivo Node.js nao confere.'
  tar -xJf "$NODE_ARCHIVE" -C "$NODE_ROOT"
fi

ln -sfn "$NODE_DIST" "$NODE_ROOT/current"
prune_old_node
for binary in node npm npx; do
  link="$LOCAL_BIN/$binary"
  if [[ ! -L "$link" ]]; then
    ln -s "$NODE_ROOT/current/bin/$binary" "$link"
  fi
done
export PATH="$LOCAL_BIN:$PATH"

printf '[4/5] Preparando o PATH e os clientes solicitados...\n'
PROFILE="$HOME_DIR/.profile"
touch "$PROFILE"
if ! grep -Fq '# addons: user-local PATH' "$PROFILE"; then
  {
    cat <<'EOF'

# addons: user-local PATH
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
EOF
  } >> "$PROFILE"
fi

install_client_cli() {
  local name="$1" binary="$2" package="$3" upgradable="${4:-true}" current modules
  if command -v "$binary" >/dev/null 2>&1; then
    current="$(command -v "$binary")"
    modules="$(readlink -f "$HOME_DIR/.local/lib/node_modules" 2>/dev/null || true)"
    # So atualiza o que o npm deste script instalou; outras origens tem seu proprio updater.
    if ! "$UPGRADE" || ! "$upgradable" || [[ -z "$modules" || "$(readlink -f "$current")" != "$modules/"* ]]; then
      printf '%s ja esta disponivel em %s; mantendo a instalacao existente.\n' "$name" "$current"
      return 0
    fi
    printf 'Atualizando %s (%s)...\n' "$name" "$package"
  else
    printf 'Instalando %s (%s)...\n' "$name" "$package"
  fi
  npm install --global --prefix "$HOME_DIR/.local" \
    --registry="$NPM_REGISTRY" --engine-strict=true "$package"
  hash -r
  command -v "$binary" >/dev/null 2>&1 || die "$name foi instalado, mas $binary nao esta no PATH."
}

verify_kimi_code() {
  kimi migrate --help >/dev/null 2>&1 \
    || die 'Kimi CLI legado detectado; instale o Kimi Code atual e revise kimi migrate antes de continuar.'
}

CLI_BINARIES=()
if selected codex; then install_client_cli 'Codex' codex '@openai/codex@latest'; CLI_BINARIES+=(codex); fi
if selected claude; then install_client_cli 'Claude Code' claude '@anthropic-ai/claude-code@latest'; CLI_BINARIES+=(claude); fi
if selected kimi; then
  if command -v kimi >/dev/null 2>&1; then verify_kimi_code; fi
  install_client_cli 'Kimi Code' kimi '@moonshot-ai/kimi-code@latest'
  verify_kimi_code
  CLI_BINARIES+=(kimi)
fi
if selected cline; then install_client_cli 'Cline CLI' cline 'cline@latest'; CLI_BINARIES+=(cline); fi
if selected copilot; then install_client_cli 'Copilot CLI' copilot '@github/copilot@latest'; CLI_BINARIES+=(copilot); fi

if selected opencode; then
  # opencode-ai@1 rebaixaria um OpenCode 2; so atualiza dentro do major 1.
  opencode_upgradable=false
  if command -v opencode >/dev/null 2>&1; then
    case "$(opencode --version 2>/dev/null)" in 1.*|v1.*) opencode_upgradable=true ;; esac
  fi
  install_client_cli 'OpenCode' opencode 'opencode-ai@1' "$opencode_upgradable"
  opencode_version="$(opencode --version)" || die 'OpenCode esta instalado, mas falhou ao informar a versao.'
  case "$opencode_version" in
    1.*|v1.*|2.*|v2.*) printf 'OpenCode detectado: %s\n' "$opencode_version" ;;
    *) die "Versao OpenCode nao reconhecida pelos addons: $opencode_version." ;;
  esac
fi

printf '[5/5] Conferindo dependencias comuns e clientes. Versoes detectadas:\n'
for binary in jq git python3 node npm npx "${CLI_BINARIES[@]}"; do
  command -v "$binary" >/dev/null 2>&1 || die "$binary nao esta disponivel no PATH apos a instalacao."
  "$binary" --version
done
command -v sha256sum >/dev/null 2>&1 || die 'sha256sum nao foi instalado.'
command -v flock >/dev/null 2>&1 || die 'flock nao foi instalado.'
printf '\nClientes preparados: %s\n' "$CLIENTS"
printf 'Autentique o Codex com: codex login\n'
if selected claude; then printf 'Autentique o Claude Code executando: claude\n'; fi
if selected kimi; then printf 'Autentique o Kimi Code executando: kimi (depois /login)\n'; fi
if selected cline; then printf 'Autentique o Cline CLI com: cline auth\n'; fi
if selected copilot; then printf 'Autentique o Copilot CLI executando: copilot (depois /login)\n'; fi
if selected vscode; then
  if command -v code >/dev/null 2>&1; then
    printf 'VS Code detectado: %s\n' "$(command -v code)"
  else
    printf 'VS Code nao foi encontrado: instale-o e a extensao GitHub Copilot separadamente.\n'
  fi
fi
if selected antigravity; then
  if command -v agy >/dev/null 2>&1; then
    printf 'Antigravity CLI detectado: %s\n' "$(command -v agy)"
  else
    printf 'Antigravity CLI (agy) nao foi encontrado: instale o Antigravity separadamente se for usa-lo localmente.\n'
  fi
fi
printf 'O PATH foi salvo em %s; abra uma nova sessao para aplica-lo.\n' "$PROFILE"
printf 'Para aplicar agora neste terminal: export PATH="$HOME/.local/bin:$PATH"\n'
printf '\nOs seis addons podem ser instalados somente no Codex com --clients codex.\n'
printf -- '--clients all seleciona oito clientes; nao significa somente os seis addons.\n'
if ! command -v opencode >/dev/null 2>&1; then
  printf 'OpenCode ausente: reexecute este bootstrap com --clients all ou --with-opencode.\n'
fi
if ! command -v claude >/dev/null 2>&1; then
  printf 'Claude Code ausente: reexecute este bootstrap com --clients all ou incluindo claude.\n'
fi
