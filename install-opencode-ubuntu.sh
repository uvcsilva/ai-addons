#!/usr/bin/env bash
# Instalador do provedor OpenCode: instala as ferramentas e configura no OpenCode todos os
# addons, com os plugins nativos de Engram, RTK e Ponytail. Requer a pasta lib/.
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

OPENCODE_DIR="${XDG_CONFIG_HOME:-$HOME_DIR/.config}/opencode"
OC_CONFIG_FILE=""
OPENCODE_MAJOR=""
PROJECT_DIR=""
HAS_OPENCODE_CLI=0
CONFIG_FILE=""
DRY_RUN=0

usage() {
  cat <<EOF
Uso: bash $SCRIPT_NAME [--config ARQUIVO] [--opencode-major 1|2] [--project-dir DIR] [--dry-run]

Instala as ferramentas e configura no OpenCode todos os addons: Engram, Serena, Context7,
RTK e Ponytail. Engram, RTK e Ponytail entram tambem como plugins nativos do OpenCode.

  --config ARQUIVO       addons.json com as opcoes dos addons. Padrao: addons.json ao lado
                         deste script, se existir; sem ele, os padroes de cada addon.
  --opencode-major 1|2   Schema MCP instalado. Padrao: options.opencode-major ou
                         a deteccao por opencode --version.
  --project-dir DIR      Projeto fixo do Serena. Padrao: options.project-dir; sem ele,
                         o Serena usa o diretorio atual.
  --dry-run              Mostra o plano, sem rede, arquivos, logs ou alteracoes.
  --help                 Mostra esta ajuda.

Configuracao global: \${XDG_CONFIG_HOME:-~/.config}/opencode (opencode.json ou .jsonc).
OPENCODE_CONFIG, OPENCODE_CONFIG_CONTENT e OPENCODE_CONFIG_DIR sao recusados.
O plugin Ponytail exige o comando opencode; sem ele, o Ponytail fica so nas regras.
Pre-requisitos: curl, sha256sum, node, npm, python3, flock. Nao usa sudo.
Backup e log privados: \${XDG_STATE_HOME:-~/.local/state}/six-addons-installer.
Conflitos existentes sao informados antes de qualquer download, sem sobrescrever.
EOF
}

opencode_rules() { write_managed_rule "$OPENCODE_DIR/AGENTS.md" "$2" "$1"; }

# Uso: opencode_mcp MODO NOME COMANDO ARGS... (check, apply ou verify).
opencode_mcp() { edit_client_json "$1" "$OC_CONFIG_FILE" opencode "${@:2}"; }

# Uso: plugin_from_scratch NOME COMANDO ARGS... Roda o setup com HOME temporario e imprime a
# pasta de plugins gerada: setups que tambem tocam outros clientes ou reescrevem o
# opencode.json nao alcancam os arquivos reais.
plugin_from_scratch() {
  local dir="$TMP_WORKDIR/scratch-$1"; shift
  mkdir -p "$dir/.config"
  (cd "$dir" && HOME="$dir" XDG_CONFIG_HOME="$dir/.config" "$@" </dev/null) >&2
  printf '%s' "$dir/.config/opencode"
}

# Uso: install_plugin_file ORIGEM NOME. Copia um plugin gerado para a pasta global do OpenCode.
install_plugin_file() {
  local source="$1" dest="$OPENCODE_DIR/plugins/$2"
  [[ -s "$source" ]] || die "Plugin $2 nao foi gerado."
  ! grep -qF -- "$TMP_WORKDIR" "$source" || die "Plugin $2 aponta para a pasta temporaria; nada copiado."
  assert_regular_or_absent "$dest"
  if [[ -f "$dest" ]] && cmp -s "$source" "$dest"; then
    printf 'Plugin OpenCode %s ja confere.\n' "$2"
    return 0
  fi
  backup_path "$dest"
  mkdir -p "${dest%/*}"
  install -m 0600 "$source" "$dest"
  printf 'Plugin OpenCode %s: %s\n' "$2" "$dest"
}

# A statusline de sub-agentes que o engram setup liga no tui.json; arquivo do usuario nao e reescrito.
install_engram_statusline() {
  local generated="$1/tui.json" path
  [[ -s "$generated" ]] || return 0
  for path in "$OPENCODE_DIR/tui.json" "$OPENCODE_DIR/tui.jsonc"; do
    [[ -e "$path" ]] || continue
    if grep -qF opencode-subagent-statusline "$path"; then
      printf 'Statusline do Engram ja confere: %s\n' "$path"
    else
      printf 'AVISO: inclua "opencode-subagent-statusline" em "plugin" de %s para ver os sub-agentes do Engram.\n' "$path"
    fi
    return 0
  done
  install -m 0600 "$generated" "$OPENCODE_DIR/tui.json"
  printf 'Statusline do Engram: %s\n' "$OPENCODE_DIR/tui.json"
}

install_ponytail_plugin() {
  backup_path "$OC_CONFIG_FILE"
  opencode plugin @dietrichgebert/ponytail --global </dev/null
  grep -qF '"@dietrichgebert/ponytail"' "$OC_CONFIG_FILE" || die "OpenCode nao registrou o plugin Ponytail em $OC_CONFIG_FILE."
  printf 'Plugin OpenCode ponytail: conferido\n'
}

main() {
  local path mode addon dir major="" project_dir="" project_set=0 version
  while (($#)); do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --config|--opencode-major|--project-dir)
        (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || { printf 'Falta valor para %s\n' "$1" >&2; exit 2; }
        case "$1" in
          --config) CONFIG_FILE="$2" ;;
          --opencode-major) major="$2" ;;
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
  OPENCODE_MAJOR="${major:-$(config_option opencode-major)}"
  case "$OPENCODE_MAJOR" in ''|1|2) ;; *) printf 'Use --opencode-major 1 ou 2\n' >&2; exit 2 ;; esac
  if [[ "$project_set" == 1 ]]; then PROJECT_DIR="$project_dir"; else PROJECT_DIR="$(config_opt serena project-dir)"; fi
  for path in "$OPENCODE_DIR" "${PROJECT_DIR:-/}"; do
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
Simulacao do OpenCode: sem alteracoes e sem acesso a rede.
  Configuracao: ${CONFIG_FILE:-padroes dos addons}
  OpenCode: $OPENCODE_DIR (major: ${OPENCODE_MAJOR:-detectar})
  • Exigir Ubuntu, usuario sem sudo e: curl, sha256sum, node, npm, python3, flock.
  • Recusar OPENCODE_CONFIG/CONTENT/DIR e opencode.json junto com opencode.jsonc.
  • Conferir os MCPs engram, serena e context7 antes de baixar algo; recusar conflitos.
  • Instalar ou atualizar em ~/.local: Engram, uv + Serena (Go: $WITH_GO), context7-mcp e RTK.
  • MCPs: engram mcp --tools=$ENGRAM_TOOLS; serena ${SERENA_ARGV[*]}; context7-mcp.
  • Plugins: engram.ts (engram setup opencode) e rtk.ts (rtk init --global --opencode), gerados
    com HOME temporario e copiados para $OPENCODE_DIR/plugins; statusline do Engram no tui.json.
  • Ponytail: opencode plugin @dietrichgebert/ponytail --global (sem o comando opencode, so regras).
  • Regras em AGENTS.md: Engram, Serena, Context7 e RTK; Ponytail sai das regras quando o plugin entra.
EOF
    exit 0
  fi

  installer_begin opencode "${TOOLS_PREREQS[@]}"
  [[ -z "${OPENCODE_CONFIG:-}" && -z "${OPENCODE_CONFIG_CONTENT:-}" && -z "${OPENCODE_CONFIG_DIR:-}" ]] || die 'Remova os overrides OPENCODE_CONFIG/CONTENT/DIR e execute para a configuracao global, ou adapte o destino manualmente.'
  if command -v opencode >/dev/null 2>&1; then
    HAS_OPENCODE_CLI=1
    version="$(opencode --version)"
    printf 'OpenCode %s\n' "$version"
  fi
  if [[ -z "$OPENCODE_MAJOR" ]]; then
    [[ "$HAS_OPENCODE_CLI" == 1 ]] || die 'Instale OpenCode ou informe --opencode-major 1|2.'
    case "$version" in 1.*|v1.*) OPENCODE_MAJOR=1 ;; 2.*|v2.*) OPENCODE_MAJOR=2 ;; *) die 'Versao OpenCode nao reconhecida: informe --opencode-major 1|2.' ;; esac
  fi
  [[ ! -e "$OPENCODE_DIR/opencode.json" || ! -e "$OPENCODE_DIR/opencode.jsonc" ]] || die 'Existem opencode.json e opencode.jsonc: consolide as configuracoes antes de prosseguir.'
  OC_CONFIG_FILE="$OPENCODE_DIR/opencode.json"
  [[ ! -e "$OPENCODE_DIR/opencode.jsonc" ]] || OC_CONFIG_FILE="$OPENCODE_DIR/opencode.jsonc"
  printf 'OpenCode %s: %s\n' "$OPENCODE_MAJOR" "$OC_CONFIG_FILE"
  backup_plugins_dir "$OPENCODE_DIR/plugins"
  for path in "$OPENCODE_DIR/tui.json" "$OPENCODE_DIR/tui.jsonc"; do
    assert_regular_or_absent "$path"
    backup_path "$path"
  done
  tools_check

  # Conflitos param tudo antes de baixar ferramentas ou escrever no OpenCode.
  opencode_mcp check engram "$LOCAL_BIN/engram" mcp "--tools=$ENGRAM_TOOLS"
  opencode_mcp check serena "$LOCAL_BIN/serena" "${SERENA_ARGV[@]}"
  LEGACY_MCP_ARGV="$C7_LEGACY_MCP_ARGV" opencode_mcp check context7 "$LOCAL_BIN/context7-mcp" ${C7_ARGS[@]+"${C7_ARGS[@]}"}

  tools_install

  serena_check_flags
  for mode in apply verify; do
    opencode_mcp "$mode" engram "$LOCAL_BIN/engram" mcp "--tools=$ENGRAM_TOOLS"
    opencode_mcp "$mode" serena "$LOCAL_BIN/serena" "${SERENA_ARGV[@]}"
    LEGACY_MCP_ARGV="$C7_LEGACY_MCP_ARGV" opencode_mcp "$mode" context7 "$LOCAL_BIN/context7-mcp" ${C7_ARGS[@]+"${C7_ARGS[@]}"}
  done

  # engram setup opencode reescreve o opencode.json e fixa --tools=agent; dele fica so o plugin.
  dir="$(plugin_from_scratch engram "$LOCAL_BIN/engram" setup opencode)"
  install_plugin_file "$dir/plugins/engram.ts" engram.ts
  install_engram_statusline "$dir"
  # rtk init --opencode tambem grava arquivos do Claude; dele fica so o plugin.
  dir="$(plugin_from_scratch rtk "$LOCAL_BIN/rtk" init --global --opencode --auto-patch ${RTK_INIT_FLAGS[@]+"${RTK_INIT_FLAGS[@]}"})"
  install_plugin_file "$dir/plugins/rtk.ts" rtk.ts

  for addon in engram serena context7; do
    addon_rules "$addon" "$TMP_WORKDIR/$addon-rules.md"
    opencode_rules "$addon" "$TMP_WORKDIR/$addon-rules.md"
  done
  rtk_cline_rules "$TMP_WORKDIR/rtk-rules.md"
  opencode_rules rtk "$TMP_WORKDIR/rtk-rules.md"

  if [[ "$HAS_OPENCODE_CLI" == 1 ]]; then
    # O plugin injeta as regras a cada turno no nivel ativo; o bloco fixo contradiria /ponytail.
    install_ponytail_plugin
    remove_managed_rule "$OPENCODE_DIR/AGENTS.md" ponytail
  else
    printf 'AVISO: comando opencode ausente; Ponytail aplicado so como regras.\n'
    addon_rules ponytail "$TMP_WORKDIR/ponytail-rules.md"
    opencode_rules ponytail "$TMP_WORKDIR/ponytail-rules.md"
  fi

  installer_end 'OpenCode configurado com Engram, Serena, Context7, RTK e Ponytail.'
}

# Carregado com source (testes), so define as funcoes.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
