#!/usr/bin/env bash
# Instalador do provedor Moonshot AI (Kimi Code CLI): instala as ferramentas e configura
# no Kimi Code todos os addons. Requer a pasta lib/ ao lado deste script.
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
umask 077

SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ -r "$SCRIPT_DIR/lib/common.sh" ]] || { printf 'Pasta lib/ ausente em %s; copie-a junto com o instalador.\n' "$SCRIPT_DIR" >&2; exit 1; }
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/addons.sh
. "$SCRIPT_DIR/lib/addons.sh"
# shellcheck source=lib/tools.sh
. "$SCRIPT_DIR/lib/tools.sh"
# shellcheck source=lib/json-mcp.sh
. "$SCRIPT_DIR/lib/json-mcp.sh"

KIMI_DIR="${KIMI_CODE_HOME:-$HOME_DIR/.kimi-code}"
MCP_CONFIG="$KIMI_DIR/mcp.json"
KIMI_RULES="$KIMI_DIR/AGENTS.md"
PROJECT_DIR=""
OPENCODE_MAJOR=""
CONFIG_FILE=""
DRY_RUN=0

usage() {
  cat <<EOF
Uso: bash $SCRIPT_NAME [--config ARQUIVO] [--project-dir DIR] [--dry-run]

Instala as ferramentas e configura no Kimi Code CLI (Moonshot AI) todos os addons:
Engram, Serena, Context7, RTK, Ponytail e Graphify.

  --config ARQUIVO   addons.json com as opcoes dos addons. Padrao: addons.json ao lado
                     deste script, se existir; sem ele, os padroes de cada addon.
  --project-dir DIR  Projeto fixo do Serena. Padrao: options.project-dir; sem ele,
                     o Serena usa o diretorio atual.
  --dry-run          Mostra o plano, sem rede, arquivos, logs ou alteracoes.
  --help             Mostra esta ajuda.

Respeita KIMI_CODE_HOME (padrao: ~/.kimi-code). MCP em mcp.json e regras em AGENTS.md.
RTK e Ponytail ficam somente como regras; nenhum hook ou modelo e alterado.
Pre-requisitos: kimi, git, jq, curl, sha256sum, node, npm, python3, flock. Nao usa sudo.
Backup e log privados: \${XDG_STATE_HOME:-~/.local/state}/six-addons-installer.
Conflitos existentes sao informados antes de qualquer download, sem sobrescrever.
EOF
}

kimi_rules() { write_managed_rule "$KIMI_RULES" "$2" "$1"; }

# Uso: kimi_mcp MODO NOME COMANDO ARGS... (check, apply ou verify).
kimi_mcp() { edit_client_json "$1" "$MCP_CONFIG" kimi "${@:2}"; }

kimi_verify_engram_rules() {
  [[ -s "$KIMI_RULES" ]] || die "Engram nao gerou $KIMI_RULES."
  grep -qi engram "$KIMI_RULES" || die "Protocolo Engram ausente em $KIMI_RULES."
  printf 'Engram: protocolo do Kimi conferido\n'
}

main() {
  local path mode addon project_dir="" project_set=0
  while (($#)); do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --config|--project-dir)
        (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || { printf 'Falta valor para %s\n' "$1" >&2; exit 2; }
        case "$1" in
          --config) CONFIG_FILE="$2" ;;
          --project-dir) project_dir="$2"; project_set=1 ;;
        esac
        shift 2 ;;
      *) printf 'Opcao desconhecida: %s\n' "$1" >&2; exit 2 ;;
    esac
  done
  [[ -n "$CONFIG_FILE" || ! -f "$SCRIPT_DIR/addons.json" ]] || CONFIG_FILE="$SCRIPT_DIR/addons.json"
  config_load "$CONFIG_FILE"
  addons_load_options
  tools_load_options
  if [[ "$project_set" == 1 ]]; then PROJECT_DIR="$project_dir"; else PROJECT_DIR="$(config_opt serena project-dir)"; fi
  for path in "$KIMI_DIR" "${PROJECT_DIR:-/}"; do
    [[ "$path" == /* && "$path" != *$'\n'* ]] || { printf 'Caminho precisa ser absoluto, sem quebra de linha: %s\n' "$path" >&2; exit 2; }
  done
  if [[ -z "$PROJECT_DIR" ]]; then
    SERENA_ARGV=(start-mcp-server --context ide --project-from-cwd --add-mode no-memories)
  else
    SERENA_ARGV=(start-mcp-server --context ide --add-mode no-memories --project "$PROJECT_DIR")
  fi
  SERENA_ARGV+=(${SERENA_EXTRA[@]+"${SERENA_EXTRA[@]}"})

  if [[ "$DRY_RUN" == 1 ]]; then
    cat <<EOF
Simulacao do Kimi Code: sem alteracoes e sem acesso a rede.
  Configuracao: ${CONFIG_FILE:-padroes dos addons}
  Kimi Code: $KIMI_DIR (MCP em $MCP_CONFIG)
  • Exigir Ubuntu, usuario sem sudo e: kimi, git, jq, curl, sha256sum, node, npm, python3, flock.
  • Fazer backup de mcp.json e AGENTS.md e conferir os MCPs antes de baixar algo.
  • Instalar ou atualizar em ~/.local: Engram, uv + Serena (Go: $WITH_GO), Graphify, context7-mcp e RTK.
  • Engram: engram setup kimi e MCP engram mcp --tools=$ENGRAM_TOOLS.
  • Serena: regra em AGENTS.md e MCP ${SERENA_ARGV[*]}.
  • Context7: regra em AGENTS.md e MCP context7-mcp ($([[ ${#C7_ARGS[@]} -gt 0 ]] && echo 'chave de CONTEXT7_API_KEY' || echo 'sem chave')); migrar entrada npx antiga.
  • RTK: regras oficiais geradas em temporario; sem hook e sem reescrita transparente.
  • Ponytail: regras em AGENTS.md no nivel $PONYTAIL_MODE; sem plugin interativo.
  • Graphify: skill do cliente, regra de uso e graphify-preflight; grafo local sob demanda.
  • Preservar config.toml, modelos, provedores, credenciais e outros clientes.
EOF
    exit 0
  fi

  installer_begin kimi kimi "${TOOLS_PREREQS[@]}"
  kimi --version
  for path in "$MCP_CONFIG" "$KIMI_RULES"; do
    assert_regular_or_absent "$path"
    backup_path "$path"
  done
  tools_check

  # Conflitos param tudo antes de baixar ferramentas ou escrever no Kimi Code.
  kimi_mcp check engram "$LOCAL_BIN/engram" mcp "--tools=$ENGRAM_TOOLS"
  kimi_mcp check serena "$LOCAL_BIN/serena" "${SERENA_ARGV[@]}"
  LEGACY_MCP_ARGV="$C7_LEGACY_MCP_ARGV" kimi_mcp check context7 "$LOCAL_BIN/context7-mcp" ${C7_ARGS[@]+"${C7_ARGS[@]}"}

  tools_install

  "$LOCAL_BIN/engram" setup kimi
  kimi_verify_engram_rules
  serena_check_flags
  for mode in apply verify; do
    kimi_mcp "$mode" engram "$LOCAL_BIN/engram" mcp "--tools=$ENGRAM_TOOLS"
    kimi_mcp "$mode" serena "$LOCAL_BIN/serena" "${SERENA_ARGV[@]}"
    LEGACY_MCP_ARGV="$C7_LEGACY_MCP_ARGV" kimi_mcp "$mode" context7 "$LOCAL_BIN/context7-mcp" ${C7_ARGS[@]+"${C7_ARGS[@]}"}
  done

  for addon in serena context7 ponytail graphify; do
    addon_rules "$addon" "$TMP_WORKDIR/$addon-rules.md"
    kimi_rules "$addon" "$TMP_WORKDIR/$addon-rules.md"
  done
  rtk_kimi_rules "$TMP_WORKDIR/rtk-rules.md"
  kimi_rules rtk "$TMP_WORKDIR/rtk-rules.md"

  # Graphify 0.9.96 ainda grava no diretorio legado .kimi; o destino e o Kimi Code atual.
  graphify_skill kimi .kimi/skills/graphify "$KIMI_DIR/skills/graphify"

  installer_end 'Kimi Code configurado com Engram, Serena, Context7, RTK, Ponytail e Graphify.'
  printf 'No Kimi Code, use /reload ou abra uma nova sessao e confira os servidores com /mcp-config.\n'
}

# Carregado com source (testes), so define as funcoes.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
