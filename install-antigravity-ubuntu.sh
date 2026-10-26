#!/usr/bin/env bash
# Instalador do provedor Google Antigravity: instala as ferramentas e configura no Antigravity
# (~/.gemini) todos os addons. Requer a pasta lib/ ao lado deste script.
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

ANTIGRAVITY_DIR="$HOME_DIR/.gemini"
MCP_CONFIG="$ANTIGRAVITY_DIR/config/mcp_config.json"
PROJECT_DIR=""
OPENCODE_MAJOR=""
HAS_AGY=0
CONFIG_FILE=""
DRY_RUN=0

usage() {
  cat <<EOF
Uso: bash $SCRIPT_NAME [--config ARQUIVO] [--project-dir DIR] [--dry-run]

Instala as ferramentas e configura no Google Antigravity (~/.gemini) todos os addons:
Engram, Serena, Context7, RTK e Ponytail.

  --config ARQUIVO   addons.json com as opcoes dos addons. Padrao: addons.json ao lado
                     deste script, se existir; sem ele, os padroes de cada addon.
  --project-dir DIR  Projeto fixo do Serena. Padrao: options.project-dir; sem ele,
                     o Serena usa o diretorio atual.
  --dry-run          Mostra o plano, sem rede, arquivos, logs ou alteracoes.
  --help             Mostra esta ajuda.

MCP em ~/.gemini/config/mcp_config.json, regras em ~/.gemini/GEMINI.md e plugin RTK com
hook em ~/.gemini/config/plugins/rtk. O plugin Ponytail exige o CLI agy; sem ele, so regras.
Pre-requisitos: curl, sha256sum, node, npm, python3, flock. Nao usa sudo.
Backup e log privados: \${XDG_STATE_HOME:-~/.local/state}/six-addons-installer.
Conflitos existentes sao informados antes de qualquer download, sem sobrescrever.
EOF
}

antigravity_rules() { write_managed_rule "$ANTIGRAVITY_DIR/GEMINI.md" "$2" "$1"; }

# Uso: antigravity_mcp MODO NOME COMANDO ARGS... (check, apply ou verify).
antigravity_mcp() { edit_client_json "$1" "$MCP_CONFIG" antigravity "${@:2}"; }

antigravity_verify_rtk_hook() {
  python3 - "$ANTIGRAVITY_DIR/config/plugins/rtk/hooks.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
root = data.get('rtk-rewrite', {})
commands = [h.get('command', '') for g in root.get('PreToolUse', []) for h in g.get('hooks', [])]
if not any('rtk' in c and 'hook' in c for c in commands):
    raise ValueError('Hook RTK ausente: antigravity')
print('RTK: hook do Antigravity conferido')
PY
}

# Sem hooks no plugin, o nivel nao persiste; as regras em GEMINI.md continuam valendo.
install_ponytail_plugin() {
  agy plugin list > "$TMP_WORKDIR/agy-plugins.txt"
  if grep -qiw ponytail "$TMP_WORKDIR/agy-plugins.txt"; then
    printf 'Plugin Antigravity ponytail ja instalado.\n'
    return 0
  fi
  agy plugin install https://github.com/DietrichGebert/ponytail </dev/null
  agy plugin list > "$TMP_WORKDIR/agy-plugins.txt"
  grep -qiw ponytail "$TMP_WORKDIR/agy-plugins.txt" || die 'Antigravity: plugin ponytail nao aparece em agy plugin list.'
  printf 'Plugin Antigravity ponytail: conferido\n'
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
  [[ "${PROJECT_DIR:-/}" == /* && "$PROJECT_DIR" != *$'\n'* ]] || { printf 'Caminho precisa ser absoluto, sem quebra de linha: %s\n' "$PROJECT_DIR" >&2; exit 2; }
  if [[ -z "$PROJECT_DIR" ]]; then
    SERENA_ARGV=(start-mcp-server --context antigravity --project-from-cwd --add-mode no-memories)
  else
    SERENA_ARGV=(start-mcp-server --context antigravity --add-mode no-memories --project "$PROJECT_DIR")
  fi
  SERENA_ARGV+=(${SERENA_EXTRA[@]+"${SERENA_EXTRA[@]}"})
  # rtk init --agent antigravity recusa --hook-only, --auto-patch e --no-patch.
  RTK_ARGV=(init --global --agent antigravity ${RTK_INIT_FLAGS[@]+"${RTK_INIT_FLAGS[@]}"})

  if [[ "$DRY_RUN" == 1 ]]; then
    cat <<EOF
Simulacao do Antigravity: sem alteracoes e sem acesso a rede.
  Configuracao: ${CONFIG_FILE:-padroes dos addons}
  Antigravity: $ANTIGRAVITY_DIR (MCP em $MCP_CONFIG)
  • Exigir Ubuntu, usuario sem sudo e: curl, sha256sum, node, npm, python3, flock.
  • Conferir os MCPs engram, serena e context7 antes de baixar algo; recusar conflitos.
  • Instalar ou atualizar em ~/.local: Engram, uv + Serena (Go: $WITH_GO), Graphify, context7-mcp e RTK.
  • Graphify: skill do cliente, regra de uso e graphify-preflight; o grafo de cada repositorio e criado sob demanda.
  • MCPs: engram mcp --tools=$ENGRAM_TOOLS; serena ${SERENA_ARGV[*]}; context7-mcp.
  • Regras em GEMINI.md: Engram, Serena, Context7 e Ponytail (nivel $PONYTAIL_MODE); RTK fica no plugin.
  • RTK: rtk ${RTK_ARGV[*]} e conferir o hook do plugin.
  • Ponytail: agy plugin install https://github.com/DietrichGebert/ponytail (sem agy, so regras).
EOF
    exit 0
  fi

  installer_begin antigravity "${TOOLS_PREREQS[@]}"
  if command -v agy >/dev/null 2>&1; then HAS_AGY=1; fi
  for path in "$ANTIGRAVITY_DIR/GEMINI.md" "$MCP_CONFIG"; do
    assert_regular_or_absent "$path"
    backup_path "$path"
  done
  backup_plugins_dir "$ANTIGRAVITY_DIR/config/plugins"
  tools_check

  # Conflitos param tudo antes de baixar ferramentas ou escrever no Antigravity.
  antigravity_mcp check engram "$LOCAL_BIN/engram" mcp "--tools=$ENGRAM_TOOLS"
  antigravity_mcp check serena "$LOCAL_BIN/serena" "${SERENA_ARGV[@]}"
  LEGACY_MCP_ARGV="$C7_LEGACY_MCP_ARGV" antigravity_mcp check context7 "$LOCAL_BIN/context7-mcp" ${C7_ARGS[@]+"${C7_ARGS[@]}"}

  tools_install

  serena_check_flags
  for mode in apply verify; do
    antigravity_mcp "$mode" engram "$LOCAL_BIN/engram" mcp "--tools=$ENGRAM_TOOLS"
    antigravity_mcp "$mode" serena "$LOCAL_BIN/serena" "${SERENA_ARGV[@]}"
    LEGACY_MCP_ARGV="$C7_LEGACY_MCP_ARGV" antigravity_mcp "$mode" context7 "$LOCAL_BIN/context7-mcp" ${C7_ARGS[@]+"${C7_ARGS[@]}"}
  done

  for addon in engram serena context7 ponytail graphify; do
    addon_rules "$addon" "$TMP_WORKDIR/$addon-rules.md"
    antigravity_rules "$addon" "$TMP_WORKDIR/$addon-rules.md"
  done

  "$LOCAL_BIN/rtk" "${RTK_ARGV[@]}"
  antigravity_verify_rtk_hook

  if [[ "$HAS_AGY" == 1 ]]; then
    install_ponytail_plugin
  else
    printf 'AVISO: CLI agy ausente; Ponytail aplicado so como regras no GEMINI.md.\n'
  fi

  graphify_skill antigravity .gemini/config/skills/graphify "$ANTIGRAVITY_DIR/config/skills/graphify"

  installer_end 'Antigravity configurado com Engram, Serena, Context7, RTK, Ponytail e Graphify.'
}

# Carregado com source (testes), so define as funcoes.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
