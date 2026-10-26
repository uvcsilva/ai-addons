#!/usr/bin/env bash
# Instalador do provedor GitHub Copilot (Copilot CLI e Copilot no VS Code): instala as
# ferramentas e configura todos os addons nas superficies escolhidas. Requer a pasta lib/.
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

COPILOT_DIR="${COPILOT_HOME:-$HOME_DIR/.copilot}"
VSCODE_USER_DIR=""
PROJECT_DIR=""
SURFACES="cli,vscode"
OPENCODE_MAJOR=""
HAS_COPILOT_CLI=0
CONFIG_FILE=""
DRY_RUN=0

usage() {
  cat <<EOF
Uso: bash $SCRIPT_NAME [--config ARQUIVO] [--surfaces cli,vscode] [opcoes] [--dry-run]

Instala as ferramentas e configura no GitHub Copilot todos os addons: Engram, Serena,
Context7, RTK e Ponytail.

  --config ARQUIVO        addons.json com as opcoes dos addons. Padrao: addons.json ao lado
                          deste script, se existir; sem ele, os padroes de cada addon.
  --surfaces LISTA        cli (Copilot CLI), vscode (Copilot no VS Code) ou cli,vscode.
                          Padrao: cli,vscode.
  --vscode-user-dir DIR   Pasta User do perfil VS Code. Padrao: options.vscode-user-dir
                          ou \${XDG_CONFIG_HOME:-~/.config}/Code/User.
  --project-dir DIR       Projeto fixo do Serena no VS Code. Padrao: options.project-dir.
  --dry-run               Mostra o plano, sem rede, arquivos, logs ou alteracoes.
  --help                  Mostra esta ajuda.

Copilot CLI: MCP em \${COPILOT_HOME:-~/.copilot}/mcp-config.json, hook do RTK e plugin
Ponytail (este exige o comando copilot; sem ele, o Ponytail fica so nas regras).
VS Code: MCP em User/mcp.json, regras em User/prompts e memoria nativa desligada.
Pre-requisitos: curl, sha256sum, node, npm, python3, flock. Nao usa sudo.
Backup e log privados: \${XDG_STATE_HOME:-~/.local/state}/six-addons-installer.
Conflitos existentes sao informados antes de qualquer download, sem sobrescrever.
EOF
}

surface() { [[ ",$SURFACES," == *",$1,"* ]]; }

cli_rules() { write_managed_rule "$COPILOT_DIR/copilot-instructions.md" "$2" "$1"; }
vscode_rules() { write_managed_rule "$VSCODE_USER_DIR/prompts/six-addons-$1.instructions.md" "$2" "$1" 1; }

# Uso: addon_mcp MODO NOME COMANDO ARGS... em cada superficie (check, apply ou verify).
addon_mcp() {
  local mode="$1"; shift
  if surface cli; then edit_client_json "$mode" "$COPILOT_DIR/mcp-config.json" copilot "$@"; fi
  if surface vscode; then edit_client_json "$mode" "$VSCODE_USER_DIR/mcp.json" vscode "$@"; fi
}

# O argv do Serena muda por superficie: o CLI usa o diretorio atual; o VS Code, o projeto fixo.
serena_mcp() {
  local mode="$1"
  if surface cli; then edit_client_json "$mode" "$COPILOT_DIR/mcp-config.json" copilot serena "$LOCAL_BIN/serena" "${SERENA_CLI_ARGV[@]}"; fi
  if surface vscode; then edit_client_json "$mode" "$VSCODE_USER_DIR/mcp.json" vscode serena "$LOCAL_BIN/serena" "${SERENA_VSCODE_ARGV[@]}"; fi
}

copilot_ponytail_marketplace_state() {
  copilot plugin marketplace list --json > "$TMP_WORKDIR/copilot-marketplaces.json"
  python3 - "$TMP_WORKDIR/copilot-marketplaces.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
if not isinstance(data, list):
    raise SystemExit("Formato de copilot plugin marketplace list --json nao reconhecido")
hits = [e for e in data if isinstance(e, dict) and e.get("name") == "ponytail"]
if not hits:
    print("absent"); raise SystemExit(0)
if "DietrichGebert/ponytail" not in str(hits[0].get("source", "")):
    raise SystemExit("Conflito: marketplace ponytail existe com outra origem no Copilot; revise manualmente")
print("matching")
PY
}

# Uso: copilot_plugin_state. Imprime installed ou absent para ponytail@ponytail.
copilot_plugin_state() {
  copilot plugin list --json > "$TMP_WORKDIR/copilot-plugins.json"
  python3 - "$TMP_WORKDIR/copilot-plugins.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
if not isinstance(data, list):
    raise SystemExit("Formato de copilot plugin list --json nao reconhecido")
hits = [e for e in data if isinstance(e, dict) and e.get("name") == "ponytail" and e.get("marketplace") == "ponytail"]
if len(hits) > 1:
    raise SystemExit("Plugin ponytail aparece mais de uma vez no Copilot; revise manualmente")
print("installed" if hits and hits[0].get("enabled") is True else "disabled" if hits else "absent")
PY
}

install_ponytail_plugin() {
  local state
  state="$(copilot_ponytail_marketplace_state)" || die 'Revise o marketplace Copilot ponytail.'
  if [[ "$state" == absent ]]; then
    copilot plugin marketplace add DietrichGebert/ponytail
  else
    printf 'Marketplace Copilot ponytail ja confere.\n'
  fi
  copilot plugin marketplace update ponytail
  state="$(copilot_plugin_state)" || die 'Nao foi possivel conferir o plugin Ponytail no Copilot.'
  case "$state" in
    absent) copilot plugin install ponytail@ponytail ;;
    disabled) die 'Plugin ponytail esta desabilitado no Copilot; habilite com: copilot plugin enable ponytail@ponytail' ;;
    *) copilot plugin update ponytail@ponytail ;;
  esac
  [[ "$(copilot_plugin_state)" == installed ]] || die 'Copilot: plugin ponytail nao confirmado instalado e habilitado.'
  printf 'Plugin Copilot ponytail: conferido\n'
}

copilot_verify_rtk_hook() {
  python3 - "$COPILOT_DIR/hooks/rtk-rewrite.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
commands = [h.get('command', '') for h in data.get('hooks', {}).get('PreToolUse', []) if isinstance(h, dict)]
if not any('rtk' in c and 'hook' in c for c in commands):
    raise ValueError('Hook RTK ausente: copilot')
print('RTK: hook do Copilot CLI conferido')
PY
}

main() {
  local path mode vscode_dir="" project_dir="" project_set=0
  while (($#)); do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --config|--surfaces|--vscode-user-dir|--project-dir)
        (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || { printf 'Falta valor para %s\n' "$1" >&2; exit 2; }
        case "$1" in
          --config) CONFIG_FILE="$2" ;;
          --surfaces) SURFACES="$2" ;;
          --vscode-user-dir) vscode_dir="$2" ;;
          --project-dir) project_dir="$2"; project_set=1 ;;
        esac
        shift 2 ;;
      *) printf 'Opcao desconhecida: %s\n' "$1" >&2; exit 2 ;;
    esac
  done
  [[ "$SURFACES" =~ ^(cli|vscode)(,(cli|vscode))?$ ]] || { printf 'Use --surfaces cli, vscode ou cli,vscode\n' >&2; exit 2; }
  [[ -n "$CONFIG_FILE" || ! -f "$SCRIPT_DIR/addons.json" ]] || CONFIG_FILE="$SCRIPT_DIR/addons.json"
  config_load "$CONFIG_FILE"
  addons_load_options
  tools_load_options
  VSCODE_USER_DIR="${vscode_dir:-$(config_option vscode-user-dir "${XDG_CONFIG_HOME:-$HOME_DIR/.config}/Code/User")}"
  if [[ "$project_set" == 1 ]]; then PROJECT_DIR="$project_dir"; else PROJECT_DIR="$(config_opt serena project-dir)"; fi
  for path in "$COPILOT_DIR" "$VSCODE_USER_DIR" "${PROJECT_DIR:-/}"; do
    [[ "$path" == /* && "$path" != *$'\n'* ]] || { printf 'Caminho precisa ser absoluto, sem quebra de linha: %s\n' "$path" >&2; exit 2; }
  done
  SERENA_CLI_ARGV=(start-mcp-server --context copilot-cli --add-mode no-memories --project-from-cwd ${SERENA_EXTRA[@]+"${SERENA_EXTRA[@]}"})
  SERENA_VSCODE_ARGV=(start-mcp-server --context vscode --add-mode no-memories)
  [[ -z "$PROJECT_DIR" ]] || SERENA_VSCODE_ARGV+=(--project "$PROJECT_DIR")
  SERENA_VSCODE_ARGV+=(${SERENA_EXTRA[@]+"${SERENA_EXTRA[@]}"})
  RTK_ARGV=(init --global --copilot ${RTK_INIT_FLAGS[@]+"${RTK_INIT_FLAGS[@]}"})

  if [[ "$DRY_RUN" == 1 ]]; then
    cat <<EOF
Simulacao do Copilot: sem alteracoes e sem acesso a rede.
  Configuracao: ${CONFIG_FILE:-padroes dos addons}
  Superficies: $SURFACES
  Copilot CLI: $COPILOT_DIR
  VS Code User: $VSCODE_USER_DIR
  • Exigir Ubuntu, usuario sem sudo e: curl, sha256sum, node, npm, python3, flock.
  • Conferir os MCPs engram, serena e context7 antes de baixar algo; recusar conflitos.
  • Instalar ou atualizar em ~/.local: Engram, uv + Serena (Go: $WITH_GO), context7-mcp e RTK.
  • Engram, Serena e Context7: MCP e regras em cada superficie; Engram com --tools=$ENGRAM_TOOLS.
  • Serena no CLI: ${SERENA_CLI_ARGV[*]}.
  • Serena no VS Code: ${SERENA_VSCODE_ARGV[*]}.
  • VS Code: memoria nativa do Copilot desligada em settings.json.
  • RTK no CLI: rtk ${RTK_ARGV[*]} (hook PreToolUse) e remocao do bloco de regras RTK antigo.
  • RTK no VS Code: regras de rtk init --agent cline (sem hook global).
  • Ponytail no CLI: plugin ponytail@ponytail com o comando copilot, nivel $PONYTAIL_MODE em $PONYTAIL_CONFIG;
    sem o comando copilot, so as regras. Ponytail no VS Code: regras no nivel $PONYTAIL_MODE.
EOF
    exit 0
  fi

  installer_begin copilot "${TOOLS_PREREQS[@]}"
  if surface cli && command -v copilot >/dev/null 2>&1; then
    HAS_COPILOT_CLI=1
    copilot --version
  fi
  tools_check

  # Conflitos param tudo antes de baixar ferramentas ou escrever no Copilot.
  addon_mcp check engram "$LOCAL_BIN/engram" mcp "--tools=$ENGRAM_TOOLS"
  serena_mcp check
  LEGACY_MCP_ARGV="$C7_LEGACY_MCP_ARGV" addon_mcp check context7 "$LOCAL_BIN/context7-mcp" ${C7_ARGS[@]+"${C7_ARGS[@]}"}
  if [[ "$HAS_COPILOT_CLI" == 1 ]]; then copilot_ponytail_marketplace_state >/dev/null; fi

  tools_install

  addon_rules engram "$TMP_WORKDIR/engram-rules.md"
  for mode in apply verify; do addon_mcp "$mode" engram "$LOCAL_BIN/engram" mcp "--tools=$ENGRAM_TOOLS"; done
  if surface cli; then cli_rules engram "$TMP_WORKDIR/engram-rules.md"; fi
  if surface vscode; then
    vscode_rules engram "$TMP_WORKDIR/engram-rules.md"
    edit_client_json apply "$VSCODE_USER_DIR/settings.json" memory engram
    edit_client_json verify "$VSCODE_USER_DIR/settings.json" memory engram
  fi

  serena_check_flags
  addon_rules serena "$TMP_WORKDIR/serena-rules.md"
  for mode in apply verify; do serena_mcp "$mode"; done
  if surface cli; then cli_rules serena "$TMP_WORKDIR/serena-rules.md"; fi
  if surface vscode; then vscode_rules serena "$TMP_WORKDIR/serena-rules.md"; fi

  addon_rules context7 "$TMP_WORKDIR/context7-rules.md"
  for mode in apply verify; do
    LEGACY_MCP_ARGV="$C7_LEGACY_MCP_ARGV" addon_mcp "$mode" context7 "$LOCAL_BIN/context7-mcp" ${C7_ARGS[@]+"${C7_ARGS[@]}"}
  done
  if surface cli; then cli_rules context7 "$TMP_WORKDIR/context7-rules.md"; fi
  if surface vscode; then vscode_rules context7 "$TMP_WORKDIR/context7-rules.md"; fi

  if surface cli; then
    # O hook do rtk init --copilot substitui as regras RTK que instaladores antigos gravavam.
    assert_regular_or_absent "$COPILOT_DIR/hooks/rtk-rewrite.json"
    backup_path "$COPILOT_DIR/hooks/rtk-rewrite.json"
    backup_path "$COPILOT_DIR/copilot-instructions.md"
    "$LOCAL_BIN/rtk" "${RTK_ARGV[@]}"
    copilot_verify_rtk_hook
    remove_managed_rule "$COPILOT_DIR/copilot-instructions.md" rtk
  fi
  if surface vscode; then
    rtk_cline_rules "$TMP_WORKDIR/rtk-rules.md"
    vscode_rules rtk "$TMP_WORKDIR/rtk-rules.md"
  fi

  addon_rules ponytail "$TMP_WORKDIR/ponytail-rules.md"
  if [[ "$HAS_COPILOT_CLI" == 1 ]]; then
    # O hook sessionStart do plugin injeta as regras no nivel do config.json.
    install_ponytail_plugin
    set_ponytail_default_mode
    [[ -z "${PONYTAIL_DEFAULT_MODE:-}" || "$PONYTAIL_DEFAULT_MODE" == "$PONYTAIL_MODE" ]] \
      || printf 'AVISO: PONYTAIL_DEFAULT_MODE=%s no ambiente tem prioridade sobre o config.json.\n' "$PONYTAIL_DEFAULT_MODE"
    remove_managed_rule "$COPILOT_DIR/copilot-instructions.md" ponytail
  elif surface cli; then
    printf 'AVISO: comando copilot ausente; Ponytail aplicado so como regras no Copilot CLI.\n'
    cli_rules ponytail "$TMP_WORKDIR/ponytail-rules.md"
  fi
  if surface vscode; then vscode_rules ponytail "$TMP_WORKDIR/ponytail-rules.md"; fi

  installer_end "Copilot ($SURFACES) configurado com Engram, Serena, Context7, RTK e Ponytail."
  printf '\nACAO MANUAL: desative Copilot Memory nas configuracoes da conta GitHub. Revise overrides do workspace/perfil. Veja README.\n'
}

# Carregado com source (testes), so define as funcoes.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
