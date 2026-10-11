#!/usr/bin/env bash
# Prepara as dependencias comuns dos seis instaladores no Ubuntu.
set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly HOME_DIR="${HOME:?HOME precisa estar definido}"
readonly LOCAL_BIN="$HOME_DIR/.local/bin"
readonly NODE_ROOT="$HOME_DIR/.local/lib/nodejs"
readonly NPM_REGISTRY="https://registry.npmjs.org"
TMP_DIR=""

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

usage() {
  cat <<EOF
Uso: bash $SCRIPT_NAME

Prepara os pre-requisitos para os seis addons no Ubuntu:
  curl, git, jq, Python 3, sha256sum, flock, Node.js LTS, npm, npx e Codex CLI.

Execute como usuario normal. O script usa sudo somente para instalar pacotes do
Ubuntu e nao autentica o Codex. Na primeira execucao, rode: codex login
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
[[ $# -eq 0 ]] || die "Opcao desconhecida: $1. Use --help."

[[ "${EUID:-$(id -u)}" -ne 0 ]] || die 'Execute como usuario normal, sem sudo.'
[[ -r /etc/os-release ]] || die 'Nao foi possivel identificar a distribuicao Linux.'
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == ubuntu ]] || die 'Este script foi feito para Ubuntu.'
command -v sudo >/dev/null 2>&1 || die 'O comando sudo e necessario para instalar pacotes do Ubuntu.'
command -v dpkg >/dev/null 2>&1 || die 'dpkg nao foi encontrado.'

sudo -v
printf '[1/5] Instalando ferramentas e bibliotecas basicas do Ubuntu...\n'
sudo apt-get update
sudo apt-get install -y ca-certificates coreutils curl git jq python3 tar util-linux xz-utils
command -v curl >/dev/null 2>&1 || die 'curl nao foi instalado.'
command -v python3 >/dev/null 2>&1 || die 'python3 nao foi instalado.'

case "$(dpkg --print-architecture)" in
  amd64) NODE_ARCH='x64' ;;
  arm64) NODE_ARCH='arm64' ;;
  *) die "Arquitetura nao suportada: $(dpkg --print-architecture). Use Ubuntu amd64 ou arm64." ;;
esac

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

for binary in node npm npx; do
  link="$LOCAL_BIN/$binary"
  target="$NODE_ROOT/current/bin/$binary"
  if [[ -e "$link" || -L "$link" ]]; then
    if [[ ! -L "$link" ]] || [[ "$(readlink -- "$link")" != "$target" ]]; then
      die "$link ja existe e nao pertence a este instalador; resolva esse conflito antes de continuar."
    fi
  fi
done
ln -sfn "$NODE_DIST" "$NODE_ROOT/current"
for binary in node npm npx; do
  link="$LOCAL_BIN/$binary"
  if [[ ! -L "$link" ]]; then
    ln -s "$NODE_ROOT/current/bin/$binary" "$link"
  fi
done
export PATH="$LOCAL_BIN:$PATH"

printf '[4/5] Preparando o PATH e instalando Codex CLI...\n'
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

if ! command -v codex >/dev/null 2>&1; then
  npm install --global --prefix "$HOME_DIR/.local" \
    --registry="$NPM_REGISTRY" --engine-strict=true @openai/codex@latest
else
  printf 'Codex ja esta disponivel em %s; mantendo a instalacao existente.\n' "$(command -v codex)"
fi

printf '[5/5] Dependencias prontas. Versoes detectadas:\n'
for binary in jq git python3 node npm npx codex; do
  command -v "$binary" >/dev/null 2>&1 || die "$binary nao esta disponivel no PATH apos a instalacao."
  case "$binary" in
    codex) "$binary" --version ;;
    *) "$binary" --version 2>&1 | head -n 1 ;;
  esac
done
command -v sha256sum >/dev/null 2>&1 || die 'sha256sum nao foi instalado.'
command -v flock >/dev/null 2>&1 || die 'flock nao foi instalado.'
printf '\nAutentique o Codex com: codex login\n'
printf 'O PATH foi salvo em %s; abra uma nova sessao para aplica-lo.\n' "$PROFILE"
