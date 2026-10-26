#!/usr/bin/env bash
# Instalador do provedor Claude (Claude Code CLI): instala as ferramentas e configura no
# Claude todos os addons. Requer a pasta lib/ ao lado deste script.
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

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME_DIR/.claude}"
CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_JSON="${CLAUDE_CONFIG_DIR:-$HOME_DIR}/.claude.json"
CONFIG_FILE=""
DRY_RUN=0

usage() {
  cat <<EOF
Uso: bash $SCRIPT_NAME [--config ARQUIVO] [--dry-run]

Instala as ferramentas e configura no Claude Code (CLI) todos os addons:
Engram, Serena, Context7, RTK, ccusage e Ponytail.

  --config ARQUIVO  addons.json com as opcoes dos addons. Padrao: addons.json ao lado
                    deste script, se existir; sem ele, os padroes de cada addon.
  --dry-run         Mostra o plano, sem rede, arquivos, logs ou alteracoes.
  --help            Mostra esta ajuda.

Respeita CLAUDE_CONFIG_DIR. Nao usa sudo. Requer a pasta lib/ ao lado do script.
Pre-requisitos: claude, git, jq, curl, sha256sum, node, npm, python3, flock.
Backup e log privados: \${XDG_STATE_HOME:-~/.local/state}/six-addons-installer.
Os instaladores compartilham um bloqueio; execute um de cada vez.
Conflitos existentes sao informados antes de qualquer download, sem sobrescrever.
EOF
}

claude_mcp_state() {
  local name="$1" command_name="$2"; shift 2
  python3 - "$CLAUDE_JSON" "$name" "$command_name" "$@" <<'PY'
import json, os, pathlib, sys

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Chave JSON duplicada: {key}; revise manualmente")
        result[key] = value
    return result
path, name, command = sys.argv[1:4]
args = sys.argv[4:]
legacy = json.loads(os.environ.get("LEGACY_MCP_ARGV") or "[]")
if not isinstance(legacy, list) or not all(isinstance(x, str) for x in legacy):
    raise SystemExit("LEGACY_MCP_ARGV precisa ser lista JSON de strings")
p = pathlib.Path(path)
if not p.exists():
    print("absent"); raise SystemExit(0)
try:
    root = json.loads(p.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
except Exception as exc:
    raise SystemExit(f"{path} nao e JSON valido: {exc}")
if not isinstance(root, dict):
    raise SystemExit(f"{path} nao contem objeto JSON")
servers = root.get("mcpServers", {})
if not isinstance(servers, dict):
    raise SystemExit(f"mcpServers em {path} nao e um objeto")
if name not in servers:
    print("absent"); raise SystemExit(0)
server = servers[name]
if not isinstance(server, dict):
    raise SystemExit(f"Entrada Claude MCP {name} nao e objeto")
def same(cmd, argv):
    return server.get("command") == cmd and server.get("args", []) == argv and server.get("type", "stdio") == "stdio"
if same(command, args):
    print("matching")
elif legacy and same(legacy[0], legacy[1:]):
    print("legacy")
elif command.startswith("/") and server.get("command") == command and server.get("type", "stdio") == "stdio":
    # Mesmo binario instalado por este pacote, com outros argumentos: atualiza as opcoes.
    print("legacy")
else:
    raise SystemExit(f"Conflito: Claude MCP {name} ja existe com outra configuracao; nenhuma entrada foi sobrescrita")
PY
}

ensure_claude_mcp() {
  local name="$1" command_name="$2" state; shift 2
  state="$(claude_mcp_state "$name" "$command_name" "$@")" || die "Nao foi possivel validar a entrada Claude MCP $name."
  if [[ "$state" == absent || "$state" == legacy ]]; then
    # Only the exact entry an older installer wrote is replaced (LEGACY_MCP_ARGV).
    if [[ "$state" == legacy ]]; then claude mcp remove --scope user "$name"; fi
    claude mcp add --transport stdio --scope user "$name" -- "$command_name" "$@"
    [[ "$state" == absent ]] && state=registrado || state=migrado
    [[ "$(claude_mcp_state "$name" "$command_name" "$@")" == matching ]] || die "Claude nao registrou $name como esperado."
    printf 'Claude MCP %s: %s\n' "$state" "$name"
  else
    printf 'Claude MCP ja confere: %s\n' "$name"
  fi
}

# Cold MCP server starts (node, uv) can exceed Claude's default 30s connect timeout.
set_claude_mcp_timeout() {
  python3 - "$CLAUDE_SETTINGS" <<'PY'
import json, os, pathlib, stat, sys, tempfile

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Chave JSON duplicada: {key}; revise manualmente")
        result[key] = value
    return result
p = pathlib.Path(sys.argv[1])
p.parent.mkdir(parents=True, exist_ok=True)
if p.exists():
    try:
        data = json.loads(p.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    except Exception as exc:
        raise SystemExit(f"settings.json nao e JSON valido; nenhuma alteracao feita: {exc}")
    if not isinstance(data, dict):
        raise SystemExit("settings.json precisa conter um objeto JSON no topo")
    mode = stat.S_IMODE(p.stat().st_mode)
else:
    data, mode = {}, 0o600
env = data.setdefault("env", {})
if not isinstance(env, dict):
    raise SystemExit("env em settings.json nao e um objeto; nenhuma alteracao feita")
current = str(env.get("MCP_TIMEOUT", ""))
if current and not (current.isdigit() and int(current) < 60000):
    print(f"MCP_TIMEOUT do Claude mantido: {current}"); raise SystemExit(0)
env["MCP_TIMEOUT"] = "60000"
fd, tmp = tempfile.mkstemp(prefix=".settings.json.", dir=str(p.parent))
try:
    os.fchmod(fd, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, p)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
print(f"MCP_TIMEOUT do Claude: 60000 em {p}")
PY
}

set_claude_auto_memory_off() {
  python3 - "$CLAUDE_SETTINGS" <<'PY'
import json, os, pathlib, stat, sys, tempfile

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Chave JSON duplicada: {key}; revise manualmente")
        result[key] = value
    return result
p = pathlib.Path(sys.argv[1])
p.parent.mkdir(parents=True, exist_ok=True)
if p.exists():
    raw = p.read_text(encoding="utf-8")
    try:
        data = json.loads(raw, object_pairs_hook=unique_object)
    except Exception as exc:
        raise SystemExit(f"settings.json nao e JSON valido; nenhuma alteracao feita: {exc}")
    if not isinstance(data, dict):
        raise SystemExit("settings.json precisa conter um objeto JSON no topo")
    mode = stat.S_IMODE(p.stat().st_mode)
else:
    data, mode = {}, 0o600
data["autoMemoryEnabled"] = False
encoded = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
fd, tmp = tempfile.mkstemp(prefix=".settings.json.", dir=str(p.parent))
try:
    os.fchmod(fd, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(encoded)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, p)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
  printf 'Memoria automatica nativa do Claude Code: desativada em %s\n' "$CLAUDE_SETTINGS"
}

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

claude_verify_native_memory_off() {
  python3 - "$CLAUDE_SETTINGS" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
if not p.is_file():
    raise SystemExit(f"Arquivo ausente para conferir memoria nativa: {p}")
if json.loads(p.read_text(encoding="utf-8")).get("autoMemoryEnabled") is not False:
    raise SystemExit("Memoria nativa Claude Code nao esta desativada")
PY
}

# Uso: claude_verify_plugin NOME. Exige NOME@NOME instalado e habilitado no escopo do usuario.
claude_verify_plugin() {
  claude plugin list --json > "$TMP_WORKDIR/claude-plugins.json"
  python3 - "$1" "$TMP_WORKDIR/claude-plugins.json" <<'PY'
import json, pathlib, sys
name, claude_path = sys.argv[1:]
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
print(f"Plugin Claude {name}: conferido")
PY
}

claude_verify_rtk_hook() {
  python3 - "$CLAUDE_SETTINGS" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
commands = [h.get('command', '') for g in data.get('hooks', {}).get('PreToolUse', []) for h in g.get('hooks', [])]
if not any('rtk' in c and 'hook' in c for c in commands):
    raise ValueError('Hook RTK ausente: claude')
print('RTK: hook do Claude conferido')
PY
}

# Uso: claude_mcp NOME COMANDO ARGS... Registra e confere a entrada MCP no escopo do usuario.
claude_mcp() {
  ensure_claude_mcp "$@"
  [[ "$(claude_mcp_state "$@")" == matching ]] || die "MCP $1 ausente no claude"
}

install_ponytail_plugin() {
  local marketplace_state
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
}

main() {
  local path
  while (($#)); do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --config)
        (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || { printf 'Falta valor para --config\n' >&2; exit 2; }
        CONFIG_FILE="$2"; shift 2 ;;
      *) printf 'Opcao desconhecida: %s\n' "$1" >&2; exit 2 ;;
    esac
  done
  [[ -n "$CONFIG_FILE" || ! -f "$SCRIPT_DIR/addons.json" ]] || CONFIG_FILE="$SCRIPT_DIR/addons.json"
  config_load "$CONFIG_FILE"
  addons_load_options
  tools_load_options
  for path in "$CLAUDE_DIR" "$CLAUDE_JSON"; do
    [[ "$path" == /* && "$path" != *$'\n'* ]] || { printf 'Caminho precisa ser absoluto, sem quebra de linha: %s\n' "$path" >&2; exit 2; }
  done
  SERENA_ARGV=(start-mcp-server --context claude-code --project-from-cwd --add-mode no-memories ${SERENA_EXTRA[@]+"${SERENA_EXTRA[@]}"})
  RTK_ARGV=(init --global --auto-patch ${RTK_CLAUDE_FLAGS[@]+"${RTK_CLAUDE_FLAGS[@]}"} ${RTK_INIT_FLAGS[@]+"${RTK_INIT_FLAGS[@]}"})

  if [[ "$DRY_RUN" == 1 ]]; then
    cat <<EOF
Simulacao do Claude: sem alteracoes e sem acesso a rede.
  Configuracao: ${CONFIG_FILE:-padroes dos addons}
  Claude: $CLAUDE_DIR (MCP de usuario em $CLAUDE_JSON)
  • Exigir Ubuntu, usuario sem sudo e: claude, git, jq, curl, sha256sum, node, npm, python3, flock.
  • Fazer backup das configuracoes do Claude e conferir os MCPs e o marketplace antes de baixar algo.
  • Instalar ou atualizar em ~/.local: Engram, uv + Serena (Go: $WITH_GO), context7-mcp, RTK e ccusage.
  • RTK global: telemetria=${RTK_TELEMETRY:-preservar}, recall=${RTK_RECALL:-preservar}, config.toml em $RTK_CONFIG.
  • ccusage.json ($CCUSAGE_CONFIG): $([[ -n "$CCUSAGE_SETTINGS" ]] && echo 'mesclar settings' || echo 'nao alterado').
  • Engram: autoMemoryEnabled=false, engram setup claude-code, MCP engram mcp --tools=$ENGRAM_TOOLS.
  • Serena: regra em CLAUDE.md e MCP ${SERENA_ARGV[*]}.
  • Context7: regra em CLAUDE.md e MCP context7-mcp ($([[ ${#C7_ARGS[@]} -gt 0 ]] && echo 'chave de CONTEXT7_API_KEY' || echo 'sem chave')); migrar entrada npx antiga.
  • settings.json: env.MCP_TIMEOUT >= 60000 (partida a frio dos MCPs).
  • RTK: rtk ${RTK_ARGV[*]} e conferir o hook.
  • Ponytail: plugin ponytail@ponytail (marketplace DietrichGebert/ponytail), nivel $PONYTAIL_MODE em $PONYTAIL_CONFIG.
EOF
    exit 0
  fi

  installer_begin claude claude git jq "${TOOLS_PREREQS[@]}"
  claude --version
  for path in "$CLAUDE_SETTINGS" "$CLAUDE_JSON" "$CLAUDE_DIR/CLAUDE.md" "$CLAUDE_DIR/RTK.md" "$CLAUDE_DIR/hooks/rtk-rewrite.sh" "$CLAUDE_DIR/hooks/.rtk-hook.sha256"; do
    assert_regular_or_absent "$path"
    backup_path "$path"
  done
  backup_plugins_dir "$CLAUDE_DIR/plugins"
  tools_check

  # Conflitos param tudo antes de baixar ferramentas ou escrever no Claude.
  claude_mcp_state engram "$LOCAL_BIN/engram" mcp "--tools=$ENGRAM_TOOLS" >/dev/null
  claude_mcp_state serena "$LOCAL_BIN/serena" "${SERENA_ARGV[@]}" >/dev/null
  LEGACY_MCP_ARGV="$C7_LEGACY_MCP_ARGV" claude_mcp_state context7 "$LOCAL_BIN/context7-mcp" ${C7_ARGS[@]+"${C7_ARGS[@]}"} >/dev/null
  claude_ponytail_marketplace_state >/dev/null

  tools_install
  tools_install_ccusage

  set_claude_auto_memory_off
  "$LOCAL_BIN/engram" setup claude-code
  claude_mcp engram "$LOCAL_BIN/engram" mcp "--tools=$ENGRAM_TOOLS"
  claude_verify_native_memory_off
  claude_verify_plugin engram

  serena_check_flags
  addon_rules serena "$TMP_WORKDIR/serena-rules.md"
  write_managed_rule "$CLAUDE_DIR/CLAUDE.md" "$TMP_WORKDIR/serena-rules.md" serena
  set_claude_mcp_timeout
  claude_mcp serena "$LOCAL_BIN/serena" "${SERENA_ARGV[@]}"

  addon_rules context7 "$TMP_WORKDIR/context7-rules.md"
  write_managed_rule "$CLAUDE_DIR/CLAUDE.md" "$TMP_WORKDIR/context7-rules.md" context7
  LEGACY_MCP_ARGV="$C7_LEGACY_MCP_ARGV" claude_mcp context7 "$LOCAL_BIN/context7-mcp" ${C7_ARGS[@]+"${C7_ARGS[@]}"}

  "$LOCAL_BIN/rtk" "${RTK_ARGV[@]}"
  claude_verify_rtk_hook

  install_ponytail_plugin
  claude_verify_plugin ponytail
  set_ponytail_default_mode
  [[ -z "${PONYTAIL_DEFAULT_MODE:-}" || "$PONYTAIL_DEFAULT_MODE" == "$PONYTAIL_MODE" ]] \
    || printf 'AVISO: PONYTAIL_DEFAULT_MODE=%s no ambiente tem prioridade sobre o config.json.\n' "$PONYTAIL_DEFAULT_MODE"

  installer_end 'Claude configurado com Engram, Serena, Context7, RTK, ccusage e Ponytail.'
}

# Carregado com source (testes), so define as funcoes.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
