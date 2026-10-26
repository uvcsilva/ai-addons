#!/usr/bin/env bash
# Instalador do provedor Cline (CLI e extensao): instala as ferramentas e configura no Cline
# todos os addons. Requer a pasta lib/ ao lado deste script.
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

CLINE_CONFIG=""
CLINE_RULES_DIR="$HOME_DIR/.cline/rules"
PROJECT_DIR=""
OPENCODE_MAJOR=""
CONFIG_FILE=""
DRY_RUN=0

usage() {
  cat <<EOF
Uso: bash $SCRIPT_NAME [--config ARQUIVO] [--cline-config ARQUIVO] [--project-dir DIR] [--dry-run]

Instala as ferramentas e configura no Cline todos os addons: Engram, Serena, Context7,
RTK e Ponytail. O Cline recebe MCPs e regras; RTK e Ponytail ficam so como regras.

  --config ARQUIVO        addons.json com as opcoes dos addons. Padrao: addons.json ao lado
                          deste script, se existir; sem ele, os padroes de cada addon.
  --cline-config ARQUIVO  MCP do Cline CLI ou da extensao (caminho absoluto). Padrao:
                          options.cline-config, CLINE_MCP_SETTINGS_PATH ou
                          ~/.cline/data/settings/cline_mcp_settings.json.
  --project-dir DIR       Projeto fixo do Serena. Padrao: options.project-dir.
  --dry-run               Mostra o plano, sem rede, arquivos, logs ou alteracoes.
  --help                  Mostra esta ajuda.

Na extensao, confira o arquivo em MCP Servers > Configure e passe-o em --cline-config.
OpenRouter: configure o provedor no proprio Cline.
Pre-requisitos: curl, sha256sum, node, npm, python3, flock. Nao usa sudo.
Backup e log privados: \${XDG_STATE_HOME:-~/.local/state}/six-addons-installer.
Conflitos existentes sao informados antes de qualquer download, sem sobrescrever.
EOF
}

cline_rules() { write_managed_rule "$CLINE_RULES_DIR/six-addons-$1.md" "$2" "$1"; }

# Uso: cline_mcp MODO NOME COMANDO ARGS... (check, apply ou verify).
cline_mcp() { edit_client_json "$1" "$CLINE_CONFIG" cline "${@:2}"; }

main() {
  local path mode addon cline_config="" project_dir="" project_set=0
  while (($#)); do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --config|--cline-config|--project-dir)
        (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || { printf 'Falta valor para %s\n' "$1" >&2; exit 2; }
        case "$1" in
          --config) CONFIG_FILE="$2" ;;
          --cline-config) cline_config="$2" ;;
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
  CLINE_CONFIG="${cline_config:-$(config_option cline-config "${CLINE_MCP_SETTINGS_PATH:-$HOME_DIR/.cline/data/settings/cline_mcp_settings.json}")}"
  if [[ "$project_set" == 1 ]]; then PROJECT_DIR="$project_dir"; else PROJECT_DIR="$(config_opt serena project-dir)"; fi
  for path in "$CLINE_CONFIG" "${PROJECT_DIR:-/}"; do
    [[ "$path" == /* && "$path" != *$'\n'* ]] || { printf 'Caminho precisa ser absoluto, sem quebra de linha: %s\n' "$path" >&2; exit 2; }
  done
  SERENA_ARGV=(start-mcp-server --context ide --add-mode no-memories)
  [[ -z "$PROJECT_DIR" ]] || SERENA_ARGV+=(--project "$PROJECT_DIR")
  SERENA_ARGV+=(${SERENA_EXTRA[@]+"${SERENA_EXTRA[@]}"})

  if [[ "$DRY_RUN" == 1 ]]; then
    cat <<EOF
Simulacao do Cline: sem alteracoes e sem acesso a rede.
  Configuracao: ${CONFIG_FILE:-padroes dos addons}
  Cline MCP: $CLINE_CONFIG
  Regras: $CLINE_RULES_DIR/six-addons-<addon>.md
  • Exigir Ubuntu, usuario sem sudo e: curl, sha256sum, node, npm, python3, flock.
  • Conferir os MCPs engram, serena e context7 antes de baixar algo; recusar conflitos.
  • Instalar ou atualizar em ~/.local: Engram, uv + Serena (Go: $WITH_GO), context7-mcp e RTK.
  • MCPs: engram mcp --tools=$ENGRAM_TOOLS; serena ${SERENA_ARGV[*]}; context7-mcp ($([[ ${#C7_ARGS[@]} -gt 0 ]] && echo 'chave de CONTEXT7_API_KEY' || echo 'sem chave')).
  • Regras de Engram, Serena, Context7, RTK (rtk init --agent cline) e Ponytail (nivel $PONYTAIL_MODE).
EOF
    exit 0
  fi

  installer_begin cline "${TOOLS_PREREQS[@]}"
  tools_check

  # Conflitos param tudo antes de baixar ferramentas ou escrever no Cline.
  cline_mcp check engram "$LOCAL_BIN/engram" mcp "--tools=$ENGRAM_TOOLS"
  cline_mcp check serena "$LOCAL_BIN/serena" "${SERENA_ARGV[@]}"
  LEGACY_MCP_ARGV="$C7_LEGACY_MCP_ARGV" cline_mcp check context7 "$LOCAL_BIN/context7-mcp" ${C7_ARGS[@]+"${C7_ARGS[@]}"}

  tools_install

  serena_check_flags
  for mode in apply verify; do
    cline_mcp "$mode" engram "$LOCAL_BIN/engram" mcp "--tools=$ENGRAM_TOOLS"
    cline_mcp "$mode" serena "$LOCAL_BIN/serena" "${SERENA_ARGV[@]}"
    LEGACY_MCP_ARGV="$C7_LEGACY_MCP_ARGV" cline_mcp "$mode" context7 "$LOCAL_BIN/context7-mcp" ${C7_ARGS[@]+"${C7_ARGS[@]}"}
  done

  for addon in engram serena context7 ponytail; do
    addon_rules "$addon" "$TMP_WORKDIR/$addon-rules.md"
    cline_rules "$addon" "$TMP_WORKDIR/$addon-rules.md"
  done
  rtk_cline_rules "$TMP_WORKDIR/rtk-rules.md"
  cline_rules rtk "$TMP_WORKDIR/rtk-rules.md"

  installer_end 'Cline configurado com Engram, Serena, Context7, RTK e Ponytail.'
}

# Carregado com source (testes), so define as funcoes.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
