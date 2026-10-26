#!/usr/bin/env bash
# Orquestrador: le o addons.json e executa o bootstrap e um instalador por provedor de
# `clients`, um por vez. Cada instalador le as opcoes dos addons do mesmo arquivo.
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
umask 077

SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/addons.json"
DRY_RUN=0
TMP_DIR=""

usage() {
  cat <<EOF
Uso: bash $SCRIPT_NAME [--config ARQUIVO] [--dry-run]

Le um arquivo JSON e executa, nesta ordem e um por vez:
  install-dependencies-ubuntu.sh (bootstrap) e um instalador por provedor de clients:
  claude, codex, cline, opencode, copilot (copilot e vscode) e antigravity.
Cada instalador de provedor instala as ferramentas e configura todos os addons.

  --config ARQUIVO  JSON com os parametros. Padrao: addons.json ao lado deste script.
  --dry-run         Valida o JSON e executa --dry-run em cada instalador, sem
                    alterar nada. O bootstrap so e exibido, pois nao tem simulacao.
  --help            Mostra esta ajuda.

Antes de instalar, todos os instaladores sao conferidos com --dry-run; uma opcao
invalida interrompe tudo antes de qualquer alteracao. Formato do JSON no README,
secao "Orquestrador".
EOF
}

die() {
  printf '\n[ERRO] %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

while (($#)); do
  case "$1" in
    --config)
      (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || die 'Falta valor para --config.'
      CONFIG_FILE="$2"
      shift ;;
    --dry-run) DRY_RUN=1 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Opcao desconhecida: $1. Use --help." ;;
  esac
  shift
done

[[ -r "$SCRIPT_DIR/lib/config.sh" ]] || die "Pasta lib/ ausente em $SCRIPT_DIR; copie-a junto com os instaladores."
[[ -f "$CONFIG_FILE" ]] || die "Arquivo de configuracao nao encontrado: $CONFIG_FILE"
# Os instaladores rodam em outro diretorio; o caminho precisa ser absoluto.
CONFIG_FILE="$(cd -- "$(dirname -- "$CONFIG_FILE")" && pwd)/${CONFIG_FILE##*/}"
# lib/config.sh define o array CONFIG; o arquivo fica em CONFIG_FILE.
# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"
config_load "$CONFIG_FILE"

# Plano: nome, script, quantidade de argumentos e argumentos de cada etapa.
PLAN=()
TOTAL=0
add_step() {
  local name="$1" script="$2"; shift 2
  PLAN+=("$name" "$script" "$#" "$@")
  TOTAL=$((TOTAL + 1))
}

if [[ "$(config_opt bootstrap enabled true)" == true ]]; then
  bootstrap_args=()
  bootstrap_clients="$(config_opt bootstrap clients "$(config_opt root clients)")"
  [[ -z "$bootstrap_clients" ]] || bootstrap_args+=(--clients "$bootstrap_clients")
  [[ "$(config_opt bootstrap upgrade false)" != true ]] || bootstrap_args+=(--upgrade)
  [[ "$(config_opt bootstrap with-opencode false)" != true ]] || bootstrap_args+=(--with-opencode)
  add_step bootstrap install-dependencies-ubuntu.sh ${bootstrap_args[@]+"${bootstrap_args[@]}"}
fi
CLIENTS=",$(config_clients),"
for provider in claude codex cline opencode; do
  [[ "$CLIENTS" != *",$provider,"* ]] || add_step "$provider" "install-$provider-ubuntu.sh" --config "$CONFIG_FILE"
done
# copilot (CLI) e vscode (Copilot no VS Code) sao superficies do mesmo instalador.
surfaces=""
[[ "$CLIENTS" != *",copilot,"* ]] || surfaces="cli"
[[ "$CLIENTS" != *",vscode,"* ]] || surfaces="${surfaces:+$surfaces,}vscode"
[[ -z "$surfaces" ]] || add_step copilot install-copilot-ubuntu.sh --config "$CONFIG_FILE" --surfaces "$surfaces"
[[ "$CLIENTS" != *",antigravity,"* ]] || add_step antigravity install-antigravity-ubuntu.sh --config "$CONFIG_FILE"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/addons-all.XXXXXX")"

# Percorre o plano; phase = preflight (simulacao) ou run (instalacao).
run_steps() {
  local phase="$1" i=0 step=0 name script count
  local -a args
  while ((i < ${#PLAN[@]})); do
    name="${PLAN[i]}" script="${PLAN[i+1]}" count="${PLAN[i+2]}"
    args=("${PLAN[@]:i+3:count}")
    i=$((i + 3 + count))
    step=$((step + 1))
    [[ -f "$SCRIPT_DIR/$script" ]] || die "Script nao encontrado: $SCRIPT_DIR/$script"
    if [[ "$phase" == preflight ]]; then
      if [[ "$name" == bootstrap ]]; then
        printf '[%d/%d] bootstrap (sem simulacao): bash %s' "$step" "$TOTAL" "$script"
        printf ' %q' ${args[@]+"${args[@]}"}
        printf '\n'
        continue
      fi
      if ! bash "$SCRIPT_DIR/$script" ${args[@]+"${args[@]}"} --dry-run > "$TMP_DIR/dry-$name.txt" 2>&1; then
        cat "$TMP_DIR/dry-$name.txt" >&2
        die "Opcoes invalidas para $name; nada foi instalado. Revise $CONFIG_FILE."
      fi
      printf '[%d/%d] %s: argumentos conferidos.\n' "$step" "$TOTAL" "$name"
      if [[ "$DRY_RUN" == 1 ]]; then sed 's/^/    /' "$TMP_DIR/dry-$name.txt"; fi
    else
      printf '\n==> [%d/%d] %s: bash %s' "$step" "$TOTAL" "$name" "$script"
      printf ' %q' ${args[@]+"${args[@]}"}
      printf '\n'
      bash "$SCRIPT_DIR/$script" ${args[@]+"${args[@]}"} \
        || die "Falha em $name (etapa $step/$TOTAL). Corrija e reexecute; etapas concluidas podem ser repetidas com seguranca."
      # Os CLIs instalados pelo bootstrap precisam estar no PATH das proximas etapas.
      if [[ "$name" == bootstrap ]]; then export PATH="$HOME/.local/bin:$PATH"; fi
    fi
  done
}

printf 'Configuracao: %s\n' "$CONFIG_FILE"
run_steps preflight
if [[ "$DRY_RUN" == 1 ]]; then
  printf '\nSimulacao concluida; nenhuma alteracao feita.\n'
  exit 0
fi
run_steps run
printf '\nConcluido: todas as etapas habilitadas em %s terminaram.\n' "$CONFIG_FILE"
printf 'Abra uma nova sessao (ou export PATH="$HOME/.local/bin:$PATH") e reinicie os agentes.\n'
