#!/usr/bin/env bash
# Instalador do provedor OpenAI (Codex CLI): instala as ferramentas e configura no Codex
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

CODEX_DIR="${CODEX_HOME:-$HOME_DIR/.codex}"
CODEX_CONFIG="$CODEX_DIR/config.toml"
CONFIG_FILE=""
DRY_RUN=0

usage() {
  cat <<EOF
Uso: bash $SCRIPT_NAME [--config ARQUIVO] [--dry-run]

Instala as ferramentas e configura no Codex CLI (OpenAI) todos os addons:
Engram, Serena, Context7, RTK e Ponytail.

  --config ARQUIVO  addons.json com as opcoes dos addons. Padrao: addons.json ao lado
                    deste script, se existir; sem ele, os padroes de cada addon.
  --dry-run         Mostra o plano, sem rede, arquivos, logs ou alteracoes.
  --help            Mostra esta ajuda.

Respeita CODEX_HOME. Nao usa sudo. Requer a pasta lib/ ao lado do script.
Pre-requisitos: codex, git, jq, curl, sha256sum, node, npm, python3, flock.
Backup e log privados: \${XDG_STATE_HOME:-~/.local/state}/six-addons-installer.
Os instaladores compartilham um bloqueio; execute um de cada vez.
Conflitos existentes sao informados antes de qualquer download, sem sobrescrever.
EOF
}

codex_mcp_state() {
  local name="$1" command_name="$2"; shift 2
  codex mcp list --json > "$TMP_WORKDIR/codex-mcp.json" || return
  python3 - "$TMP_WORKDIR/codex-mcp.json" "$name" "$command_name" "$@" <<'PY'
import json, os, pathlib, sys
path, name, command = sys.argv[1:4]
args = sys.argv[4:]
legacy = json.loads(os.environ.get("LEGACY_MCP_ARGV") or "[]")
if not isinstance(legacy, list) or not all(isinstance(x, str) for x in legacy):
    raise SystemExit("LEGACY_MCP_ARGV precisa ser lista JSON de strings")
entries = json.loads(pathlib.Path(path).read_text())
if not isinstance(entries, list):
    raise SystemExit("Formato de codex mcp list --json nao reconhecido")
hits = [e for e in entries if isinstance(e, dict) and e.get("name") == name]
if not hits:
    print("absent"); raise SystemExit(0)
if len(hits) != 1:
    raise SystemExit(f"Conflito: mais de uma entrada MCP Codex {name}")
server = hits[0]
transport = server.get("transport", {})
def same(cmd, argv):
    return (transport.get("type") == "stdio" and transport.get("command") == cmd
            and transport.get("args", []) == argv and server.get("enabled") is True)
if same(command, args):
    print("matching")
elif legacy and same(legacy[0], legacy[1:]):
    print("legacy")
elif (command.startswith("/") and transport.get("type") == "stdio" and transport.get("command") == command
      and server.get("enabled") is True):
    # Mesmo binario instalado por este pacote, com outros argumentos: atualiza as opcoes.
    print("legacy")
else:
    raise SystemExit(f"Conflito: MCP Codex {name} diferente ou desabilitado; nenhuma entrada sobrescrita")
PY
}

update_codex_mcp() {
  local name="$1" command_name="$2"; shift 2
  assert_regular_or_absent "$CODEX_CONFIG"
  backup_path "$CODEX_CONFIG"
  python3 - "$CODEX_CONFIG" "$name" "$command_name" "$@" <<'PY'
import copy, json, os, pathlib, re, stat, sys, tempfile
try:
    import tomllib
except ImportError:
    raise SystemExit("Atualizar MCP existente requer Python 3.11+; config.toml nao alterado")
p = pathlib.Path(sys.argv[1]); name, command = sys.argv[2:4]; args = sys.argv[4:]
old = p.read_text(encoding="utf-8")
before = tomllib.loads(old)
server = before.get("mcp_servers", {}).get(name, {})
legacy = json.loads(os.environ.get("LEGACY_MCP_ARGV") or "[]")
owned = (command.startswith("/") and server.get("command") == command
         or legacy and [server.get("command")] + server.get("args", []) == legacy)
if not owned or server.get("enabled", True) is not True:
    raise SystemExit("Entrada MCP mudou ou conflita; config.toml nao alterado")
# shortcut: TOML incomum exige revisao manual; ampliar o editor quando houver um caso real.
header = re.search(r"(?m)^[ \t]*\[[ \t]*mcp_servers[ \t]*\.[ \t]*(?:"
                   + re.escape(name) + "|" + re.escape(json.dumps(name)) + "|'"
                   + re.escape(name) + r"')[ \t]*\][ \t]*(?:#[^\n]*)?$", old)
if not header:
    raise SystemExit("Tabela MCP fora do formato suportado; config.toml nao alterado")
start = header.end()
next_header = re.search(r"(?m)^[ \t]*\[", old[start:])
end = start + next_header.start() if next_header else len(old)
body = old[start:end]
string = r'"(?:\\[^\n]|[^"\\\n])*"|\'[^\'\n]*\''
array = r"\[(?:\s|,|" + string + r")*\]"
edits = []
expected = copy.deepcopy(before)
for key, value, pattern in (("command", command, string), ("args", args, array)):
    if server.get(key, [] if key == "args" else None) == value:
        continue
    expected["mcp_servers"][name][key] = value
    match = re.search(r"(?m)^[ \t]*(?:" + key + "|'" + key + "'|\"" + key
                      + r'\")[ \t]*=[ \t]*(?P<value>' + pattern + ")", body)
    if match:
        edits.append((start + match.start("value"), start + match.end("value"),
                      json.dumps(value, ensure_ascii=False)))
    elif key not in server:
        prefix = "" if old[:end].endswith("\n") else "\n"
        edits.append((end, end, prefix + key + " = " + json.dumps(value, ensure_ascii=False) + "\n"))
    else:
        raise SystemExit(f"Campo MCP {key} fora do formato suportado; config.toml nao alterado")
new = old
for a, b, value in sorted(edits, reverse=True):
    new = new[:a] + value + new[b:]
if tomllib.loads(new) != expected:
    raise SystemExit("Edicao alteraria outra configuracao MCP; config.toml nao alterado")
fd, tmp = tempfile.mkstemp(prefix=".config.toml.", dir=str(p.parent))
try:
    os.fchmod(fd, stat.S_IMODE(p.stat().st_mode))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(new)
        f.flush()
        os.fsync(f.fileno())
    if p.read_text(encoding="utf-8") != old:
        raise SystemExit("config.toml mudou durante a edicao; nenhuma alteracao feita")
    os.replace(tmp, p)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
}

ensure_codex_mcp() {
  local name="$1" command_name="$2" state; shift 2
  state="$(codex_mcp_state "$name" "$command_name" "$@")" || die "Nao foi possivel validar a entrada Codex MCP $name."
  if [[ "$state" == absent || "$state" == legacy ]]; then
    if [[ "$state" == legacy ]]; then
      update_codex_mcp "$name" "$command_name" "$@"
    else
      codex mcp add "$name" -- "$command_name" "$@"
    fi
    [[ "$state" == absent ]] && state=registrado || state=migrado
    [[ "$(codex_mcp_state "$name" "$command_name" "$@")" == matching ]] || die "Codex nao registrou $name como esperado."
    printf 'Codex MCP %s: %s\n' "$state" "$name"
  else
    printf 'Codex MCP ja confere: %s\n' "$name"
  fi
}

set_codex_native_memory_off() {
  python3 - "$CODEX_CONFIG" <<'PY'
import copy, os, pathlib, re, stat, sys, tempfile
p = pathlib.Path(sys.argv[1])
p.parent.mkdir(parents=True, exist_ok=True)
text = p.read_text(encoding="utf-8") if p.exists() else ""
mode = stat.S_IMODE(p.stat().st_mode) if p.exists() else 0o600
try:
    import tomllib
except ImportError:
    tomllib = None
if tomllib:
    before = tomllib.loads(text)
else:
    if chr(34)*3 in text or chr(39)*3 in text:
        raise SystemExit("TOML multiline requer Python 3.11+ para preservar semanticamente; arquivo nao alterado")
lines = text.splitlines()
sections = {}
current = ""
target = {"features": {"memories": "false"}, "memories": {"use_memories": "false", "generate_memories": "false"}}
for i, line in enumerate(lines):
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    header = re.match(r"^\[([^\[\]]+)\]\s*(?:#.*)?$", stripped)
    if header:
        current = header.group(1).strip()
        if current.strip("\"'") in target and current not in target:
            raise SystemExit("Tabela TOML de memoria com nome entre aspas; revise manualmente, sem alteracao")
        sections.setdefault(current, []).append(i)
        continue
    if stripped.startswith("["):
        current = "__other_table__"
        continue
    root_key = stripped.split("=", 1)[0].strip().split(".", 1)[0].strip("\"'")
    if not current and root_key in target:
        raise SystemExit("Config usa chave TOML inline/dotada para memoria; revise config.toml manualmente")

for sec in ("features", "memories"):
    if len(sections.get(sec, [])) > 1:
        raise SystemExit(f"Tabela [{sec}] duplicada; config.toml nao foi alterado")

if not lines and not text:
    lines = []

for sec in ("memories", "features"):
    keys = target[sec]
    if sec not in sections:
        if lines and lines[-1].strip():
            lines.append("")
        lines.append(f"[{sec}]")
        for key, value in keys.items():
            lines.append(f"{key} = {value}")
        sections[sec] = [len(lines) - len(keys) - 1]
        continue
    current_starts = []
    for i, line in enumerate(lines):
        m = re.match(r"^\s*\[([^\[\]]+)\]\s*(?:#.*)?$", line.strip())
        if m and m.group(1).strip() == sec:
            current_starts.append(i)
    if len(current_starts) != 1:
        raise SystemExit(f"Tabela [{sec}] ficou ambigua; config.toml nao foi alterado")
    start = current_starts[0]
    end = len(lines)
    for j in range(start + 1, len(lines)):
        if lines[j].lstrip().startswith("["):
            end = j
            break
    present = {}
    for i in range(start + 1, end):
        raw_key = lines[i].split("=", 1)[0].strip()
        if raw_key.strip("\"'") in keys and raw_key not in keys:
            raise SystemExit("Chave TOML de memoria entre aspas; revise manualmente, sem alteracao")
        m = re.match(r"^\s*([A-Za-z0-9_-]+)\s*=", lines[i])
        if m and m.group(1) in keys:
            present.setdefault(m.group(1), []).append(i)
    for key, value in keys.items():
        matches = present.get(key, [])
        if len(matches) > 1:
            raise SystemExit(f"Chave duplicada [{sec}].{key}; config.toml nao foi alterado")
        if matches:
            i = matches[0]
            old = lines[i]
            m = re.match(r"^(\s*[A-Za-z0-9_-]+\s*=\s*)(.*?)(\s+#.*)?$", old)
            if not m:
                raise SystemExit(f"Formato nao reconhecido para [{sec}].{key}; config.toml nao foi alterado")
            lines[i] = m.group(1) + value + (m.group(3) or "")
        else:
            lines.insert(end, f"{key} = {value}")
            end += 1

new_text = "\n".join(lines).rstrip() + "\n"
if tomllib:
    after = tomllib.loads(new_text)
    expected = copy.deepcopy(before)
    for section, keys in target.items():
        existing = expected.setdefault(section, {})
        if not isinstance(existing, dict):
            raise SystemExit("Tabela de memoria TOML nao e objeto; nenhuma alteracao")
        existing.update({key: False for key in keys})
    if after != expected:
        raise SystemExit("Edicao alteraria outra configuracao TOML; nenhuma alteracao")
fd, tmp = tempfile.mkstemp(prefix=".config.toml.", dir=str(p.parent))
try:
    os.fchmod(fd, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(new_text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, p)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
  printf 'Memoria nativa do Codex: desativada em %s\n' "$CODEX_CONFIG"
}

codex_verify_native_memory_off() {
  python3 - "$CODEX_CONFIG" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
if not p.is_file():
    raise SystemExit(f"Arquivo ausente para conferir memoria nativa: {p}")
text = p.read_text(encoding="utf-8")
def has_false(section, key):
    lines = text.splitlines()
    active = False
    found = []
    for line in lines:
        stripped = line.strip()
        header = re.match(r'^\[([^\[\]]+)\]', stripped)
        if header:
            active = header.group(1) == section
            continue
        if stripped.startswith("["):
            active = False
            continue
        if active:
            m = re.match(r'^' + re.escape(key) + r'\s*=\s*(false|true)\b', stripped)
            if m:
                found.append(m.group(1))
    return found == ["false"]
if not has_false("features", "memories"):
    raise SystemExit("features.memories nao esta false no Codex")
if not has_false("memories", "use_memories") or not has_false("memories", "generate_memories"):
    raise SystemExit("Memorias nativas Codex nao estao totalmente desativadas")
PY
}

# Uso: codex_verify_plugin NOME. Exige o plugin NOME do marketplace NOME instalado e habilitado.
codex_verify_plugin() {
  codex plugin list --json > "$TMP_WORKDIR/codex-plugins.json"
  python3 - "$1" "$TMP_WORKDIR/codex-plugins.json" <<'PY'
import json, pathlib, sys
name, codex_path = sys.argv[1:]
codex = json.loads(pathlib.Path(codex_path).read_text())
if not isinstance(codex, dict) or not isinstance(codex.get("installed"), list):
    raise SystemExit("Formato de codex plugin list --json nao reconhecido")
hits = [e for e in codex["installed"] if isinstance(e, dict) and e.get("name") == name and e.get("marketplaceName") == name]
if len(hits) != 1 or hits[0].get("installed") is not True or hits[0].get("enabled") is not True:
    raise SystemExit(f"Codex: plugin {name} nao confirmado instalado e habilitado")
print(f"Plugin Codex {name}: conferido")
PY
}

codex_verify_rtk_hook() {
  python3 - "$CODEX_DIR/hooks.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
commands = [h.get('command', '') for g in data.get('hooks', {}).get('PreToolUse', []) for h in g.get('hooks', [])]
if not any('rtk' in c and 'hook' in c for c in commands):
    raise ValueError('Hook RTK ausente: codex')
print('RTK: hook do Codex conferido')
PY
}

# Uso: codex_mcp NOME COMANDO ARGS... Registra e confere a entrada MCP no config.toml.
codex_mcp() {
  ensure_codex_mcp "$@"
  [[ "$(codex_mcp_state "$@")" == matching ]] || die "MCP $1 ausente no codex"
}

# Reexecucao: aceita marketplace/plugin ja presentes, como no fluxo do Claude.
install_ponytail_plugin() {
  local codex_ponytail_state
  if ! codex plugin marketplace add DietrichGebert/ponytail > "$TMP_WORKDIR/ponytail-codex-marketplace.txt" 2>&1; then
    cat "$TMP_WORKDIR/ponytail-codex-marketplace.txt"
    grep -qi 'already' "$TMP_WORKDIR/ponytail-codex-marketplace.txt" || die 'Falha ao adicionar o marketplace Ponytail no Codex.'
  else
    cat "$TMP_WORKDIR/ponytail-codex-marketplace.txt"
  fi
  codex plugin list --json > "$TMP_WORKDIR/codex-plugins.json"
  codex_ponytail_state="$(python3 - "$TMP_WORKDIR/codex-plugins.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
if not isinstance(data, dict) or not isinstance(data.get("installed"), list):
    raise SystemExit("Formato de codex plugin list --json nao reconhecido")
hits = [e for e in data["installed"] if isinstance(e, dict) and e.get("name") == "ponytail" and e.get("marketplaceName") == "ponytail"]
print("matching" if len(hits) == 1 and hits[0].get("installed") is True and hits[0].get("enabled") is True else "absent")
PY
)" || die 'Nao foi possivel conferir o plugin Ponytail no Codex.'
  if [[ "$codex_ponytail_state" == matching ]]; then
    printf 'Plugin Codex ponytail ja instalado e habilitado.\n'
  else
    codex plugin add ponytail@ponytail
  fi
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
  [[ "$CODEX_DIR" == /* && "$CODEX_DIR" != *$'\n'* ]] || { printf 'Caminho precisa ser absoluto, sem quebra de linha: %s\n' "$CODEX_DIR" >&2; exit 2; }
  SERENA_ARGV=(start-mcp-server --context codex --project-from-cwd --add-mode no-memories ${SERENA_EXTRA[@]+"${SERENA_EXTRA[@]}"})
  # rtk init --codex recusa --hook-only, --auto-patch e --no-patch.
  RTK_ARGV=(init --global --codex ${RTK_INIT_FLAGS[@]+"${RTK_INIT_FLAGS[@]}"})

  if [[ "$DRY_RUN" == 1 ]]; then
    cat <<EOF
Simulacao do Codex: sem alteracoes e sem acesso a rede.
  Configuracao: ${CONFIG_FILE:-padroes dos addons}
  Codex: $CODEX_DIR (MCP em $CODEX_CONFIG)
  • Exigir Ubuntu, usuario sem sudo e: codex, git, jq, curl, sha256sum, node, npm, python3, flock.
  • Fazer backup das configuracoes e plugins do Codex e conferir os MCPs antes de baixar algo.
  • Instalar ou atualizar em ~/.local: Engram, uv + Serena (Go: $WITH_GO), context7-mcp e RTK.
  • RTK global: telemetria=${RTK_TELEMETRY:-preservar}, recall=${RTK_RECALL:-preservar}, config.toml em $RTK_CONFIG.
  • Engram: memorias nativas desligadas no config.toml, engram setup codex, MCP engram mcp --tools=$ENGRAM_TOOLS.
  • Serena: regra em AGENTS.md e MCP ${SERENA_ARGV[*]}.
  • Context7: regra em AGENTS.md e MCP context7-mcp ($([[ ${#C7_ARGS[@]} -gt 0 ]] && echo 'chave de CONTEXT7_API_KEY' || echo 'sem chave')); migrar entrada npx antiga.
  • RTK: rtk ${RTK_ARGV[*]} e conferir o hook em hooks.json.
  • Ponytail: plugin ponytail@ponytail (marketplace DietrichGebert/ponytail), nivel $PONYTAIL_MODE em $PONYTAIL_CONFIG.
EOF
    exit 0
  fi

  installer_begin codex codex git jq "${TOOLS_PREREQS[@]}"
  codex --version
  for path in "$CODEX_CONFIG" "$CODEX_DIR/hooks.json" "$CODEX_DIR/AGENTS.md" "$CODEX_DIR/RTK.md" "$CODEX_DIR/engram-instructions.md" "$CODEX_DIR/engram-compact-prompt.md"; do
    assert_regular_or_absent "$path"
    backup_path "$path"
  done
  backup_plugins_dir "$CODEX_DIR/plugins"
  backup_plugins_dir "$HOME_DIR/.agents/plugins"
  tools_check

  # Conflitos param tudo antes de baixar ferramentas ou escrever no Codex.
  codex_mcp_state engram "$LOCAL_BIN/engram" mcp "--tools=$ENGRAM_TOOLS" >/dev/null
  codex_mcp_state serena "$LOCAL_BIN/serena" "${SERENA_ARGV[@]}" >/dev/null
  LEGACY_MCP_ARGV="$C7_LEGACY_MCP_ARGV" codex_mcp_state context7 "$LOCAL_BIN/context7-mcp" ${C7_ARGS[@]+"${C7_ARGS[@]}"} >/dev/null

  tools_install

  set_codex_native_memory_off
  "$LOCAL_BIN/engram" setup codex
  codex_mcp engram "$LOCAL_BIN/engram" mcp "--tools=$ENGRAM_TOOLS"
  codex_verify_native_memory_off
  codex_verify_plugin engram

  serena_check_flags
  addon_rules serena "$TMP_WORKDIR/serena-rules.md"
  write_managed_rule "$CODEX_DIR/AGENTS.md" "$TMP_WORKDIR/serena-rules.md" serena
  codex_mcp serena "$LOCAL_BIN/serena" "${SERENA_ARGV[@]}"

  addon_rules context7 "$TMP_WORKDIR/context7-rules.md"
  write_managed_rule "$CODEX_DIR/AGENTS.md" "$TMP_WORKDIR/context7-rules.md" context7
  LEGACY_MCP_ARGV="$C7_LEGACY_MCP_ARGV" codex_mcp context7 "$LOCAL_BIN/context7-mcp" ${C7_ARGS[@]+"${C7_ARGS[@]}"}

  "$LOCAL_BIN/rtk" "${RTK_ARGV[@]}"
  codex_verify_rtk_hook

  install_ponytail_plugin
  codex_verify_plugin ponytail
  set_ponytail_default_mode
  [[ -z "${PONYTAIL_DEFAULT_MODE:-}" || "$PONYTAIL_DEFAULT_MODE" == "$PONYTAIL_MODE" ]] \
    || printf 'AVISO: PONYTAIL_DEFAULT_MODE=%s no ambiente tem prioridade sobre o config.json.\n' "$PONYTAIL_DEFAULT_MODE"

  installer_end 'Codex configurado com Engram, Serena, Context7, RTK e Ponytail.'
  printf 'No Codex, abra /hooks para revisar e confiar nos hooks dos plugins e inicie nova sessao.\n'
}

# Carregado com source (testes), so define as funcoes.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
