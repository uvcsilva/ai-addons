# shellcheck shell=bash disable=SC2154
# Dados de cada addon compartilhados pelos instaladores de provedor: opcoes do addons.json,
# argumentos MCP e textos das regras. Requer lib/common.sh e lib/config.sh carregadas
# (HOME_DIR, LOCAL_BIN e TMP_WORKDIR vem de lib/common.sh).

PONYTAIL_CONFIG="${XDG_CONFIG_HOME:-$HOME_DIR/.config}/ponytail/config.json"
# Entrada que instaladores antigos gravavam antes do npm local; migrada se identica.
# Exporte como LEGACY_MCP_ARGV somente nas chamadas MCP do context7.
# shellcheck disable=SC2034
C7_LEGACY_MCP_ARGV='["npx","-y","--registry=https://registry.npmjs.org","@upstash/context7-mcp"]'

# Le e valida as opcoes de addon usadas na configuracao dos provedores (chame depois de config_load).
# Define ENGRAM_TOOLS, C7_ARGS, SERENA_EXTRA, RTK_INIT_FLAGS, RTK_CLAUDE_FLAGS e PONYTAIL_*.
# shellcheck disable=SC2034
addons_load_options() {
  local value mode backend interface dashboard open_dashboard log_level timeout modes trust
  local -a serena_modes=()
  ENGRAM_TOOLS="$(config_opt engram tools agent)"
  [[ "$ENGRAM_TOOLS" =~ ^[a-z_]+(,[a-z_]+)*$ ]] || { printf 'Use addons.engram.tools agent, admin, all ou uma lista separada por virgulas\n' >&2; exit 2; }

  C7_ARGS=()
  if [[ "$(config_opt context7 api-key-from-env false)" == true ]]; then
    [[ -n "${CONTEXT7_API_KEY:-}" ]] || { printf 'Exporte CONTEXT7_API_KEY antes de usar addons.context7.api-key-from-env\n' >&2; exit 2; }
    C7_ARGS=(--api-key "$CONTEXT7_API_KEY")
  fi

  # Opcoes repassadas ao start-mcp-server oficial em todos os clientes.
  backend="$(config_opt serena language-backend)"
  interface="$(config_opt serena agent-interface)"
  dashboard="$(config_opt serena enable-web-dashboard)"
  open_dashboard="$(config_opt serena open-web-dashboard)"
  log_level="$(config_opt serena log-level)"
  timeout="$(config_opt serena tool-timeout)"
  modes="$(config_opt serena modes)"
  case "$backend" in ''|LSP|JetBrains) ;; *) printf 'Use addons.serena.language-backend LSP ou JetBrains\n' >&2; exit 2 ;; esac
  case "$interface" in ''|tools|REPL) ;; *) printf 'Use addons.serena.agent-interface tools ou REPL\n' >&2; exit 2 ;; esac
  for value in "$dashboard" "$open_dashboard"; do
    case "$value" in ''|true|false) ;; *) printf 'Use true ou false nas opcoes de dashboard\n' >&2; exit 2 ;; esac
  done
  case "$log_level" in ''|DEBUG|INFO|WARNING|ERROR|CRITICAL) ;; *) printf 'Use addons.serena.log-level DEBUG, INFO, WARNING, ERROR ou CRITICAL\n' >&2; exit 2 ;; esac
  [[ -z "$timeout" || "$timeout" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { printf 'Use addons.serena.tool-timeout em segundos\n' >&2; exit 2; }
  [[ -z "$modes" || "$modes" =~ ^[A-Za-z0-9_-]+(,[A-Za-z0-9_-]+)*$ ]] || { printf 'Use uma lista de nomes em addons.serena.modes\n' >&2; exit 2; }
  [[ ",$modes," != *",no-memories,"* ]] || { printf 'no-memories ja e sempre aplicado; remova-o de addons.serena.modes\n' >&2; exit 2; }
  SERENA_EXTRA=()
  [[ -z "$backend" ]] || SERENA_EXTRA+=(--language-backend "$backend")
  [[ -z "$interface" ]] || SERENA_EXTRA+=(--agent-interface "$interface")
  [[ -z "$dashboard" ]] || SERENA_EXTRA+=(--enable-web-dashboard "$dashboard")
  [[ -z "$open_dashboard" ]] || SERENA_EXTRA+=(--open-web-dashboard "$open_dashboard")
  [[ -z "$log_level" ]] || SERENA_EXTRA+=(--log-level "$log_level")
  [[ -z "$timeout" ]] || SERENA_EXTRA+=(--tool-timeout "$timeout")
  if [[ -n "$modes" ]]; then
    IFS=, read -r -a serena_modes <<< "$modes"
    for mode in "${serena_modes[@]}"; do SERENA_EXTRA+=(--add-mode "$mode"); done
  fi

  # rtk init --codex recusa --hook-only; esse modo vale so para o Claude.
  RTK_INIT_FLAGS=()
  RTK_CLAUDE_FLAGS=()
  case "$(config_opt rtk init-mode default)" in default) ;; hook-only) RTK_CLAUDE_FLAGS+=(--hook-only) ;; *) printf 'Use addons.rtk.init-mode default ou hook-only\n' >&2; exit 2 ;; esac
  trust="$(config_opt rtk trust-filters)"
  case "$trust" in '') ;; true) RTK_INIT_FLAGS+=(--trust-filters) ;; false) RTK_INIT_FLAGS+=(--no-trust-filters) ;; *) printf 'Use true ou false em addons.rtk.trust-filters\n' >&2; exit 2 ;; esac

  PONYTAIL_MODE="$(config_opt ponytail mode ultra)"
  PONYTAIL_QUIET="$(config_opt ponytail quiet-startup)"
  PONYTAIL_HIDE="$(config_opt ponytail hide-status)"
  case "$PONYTAIL_MODE" in lite|full|ultra) ;; *) printf 'Use addons.ponytail.mode lite, full ou ultra\n' >&2; exit 2 ;; esac
  for value in "$PONYTAIL_QUIET" "$PONYTAIL_HIDE"; do
    case "$value" in ''|true|false) ;; *) printf 'Use true ou false em addons.ponytail.quiet-startup/hide-status\n' >&2; exit 2 ;; esac
  done
  [[ "$PONYTAIL_CONFIG" == /* && "$PONYTAIL_CONFIG" != *$'\n'* ]] || { printf 'Caminho precisa ser absoluto, sem quebra de linha: %s\n' "$PONYTAIL_CONFIG" >&2; exit 2; }
}

# Recusa registrar o Serena se a versao instalada nao documentar as flags usadas.
serena_check_flags() {
  local flag
  "$LOCAL_BIN/serena" start-mcp-server --help > "$TMP_WORKDIR/serena-help.txt"
  for flag in --context --project-from-cwd --add-mode ${SERENA_EXTRA[@]+"${SERENA_EXTRA[@]}"}; do
    [[ "$flag" == --* ]] || continue
    grep -Fq -- "$flag" "$TMP_WORKDIR/serena-help.txt" || die "Serena nao documenta $flag; servidor nao registrado."
  done
}

# Uso: addon_rules ADDON SAIDA. Grava as regras gerenciadas do addon; o Ponytail sai no nivel PONYTAIL_MODE.
addon_rules() {
  local out="$2"
  case "$1" in
    engram) cat > "$out" <<'RULES'
# Engram: exclusive persistent agent memory
Use only Engram MCP for persistent memories. Do not create or update a Memory Bank,
Serena memories, native Copilot memories, or memory notes in AGENTS.md/CLAUDE.md.
Instruction files are configuration, not storage for learned facts.
At session start, call mem_session_start with the actual workspace directory;
use the returned session/project identity instead of inventing project names.
Use mem_context then mem_search to retrieve relevant prior work; get full records
with mem_get_observation. Save durable decisions and fixes with mem_save, using
the session identity, a descriptive topic_key, and What/Why/Where/Learned.
Update existing topics instead of duplicating them. Before finishing, write a
mem_session_summary and close the session with mem_session_end when appropriate.
Never store secrets, credentials or private raw logs in memory. If memory calls fail,
report that briefly and still deliver the requested work. Do not start another store.
RULES
      ;;
    serena) cat > "$out" <<'RULES'
## Serena
Before coding tasks, read the Serena initial instructions. Prefer its symbol and reference tools to explore and modify code. If the language backend fails, report it; an MCP registration does not prove the analyzer works. If a file's language is missing from `language_servers` in `.serena/project.yml`, say so and propose adding it; Serena reads that file only when its MCP server starts.
RULES
      ;;
    context7) cat > "$out" <<'RULES'
## Context7
Use Context7 for current documentation when working with libraries, frameworks, SDKs, APIs and tools. Resolve the library identifier before querying its documentation, following the server instructions. Use it as the task requires, without artificial calls.
RULES
      ;;
    ponytail) cat > "$out" <<'PONYTAIL_RULES'
<!-- Fonte oficial DietrichGebert/ponytail/AGENTS.md; commit 9b58c1ffb790c075ca32e70a89cf1d80588f4abf -->
# Ponytail, lazy senior dev mode

You are a lazy senior developer. The best code is the code never written. You solve the whole problem with the least new code. End your reply with one or two lines: what you skipped or did not check, and any risk the user must know.

## Before you write

Read the task and the code it touches. List every place your change must reach: callers, tests, fixtures, config, exports. Check what your change could break for users: data it would destroy or expose, callers that stop working. That is scope. Extra features are not.

## The smallest complete change

Take the first option that fully works:

1. Does it need to exist? Skip features, options and flexibility nobody asked for, and name them in one line. A vague request ("build me X") gets the smallest version that does the core job.
2. Already in this codebase (a helper, component, service, pattern)? Use it the way the surrounding code does.
3. Standard library or a platform feature? Use it, unless the project has its own. A house component beats a native widget.
4. An installed dependency? Use it. Never add a dependency for a few lines.
5. Can it be one line a reader gets at a glance? One line.
6. Otherwise: the minimum code that works.

- Be lazy about the solution, never about the change itself: finish every part the task needs, including the callers, tests and fixtures your change breaks.
- No abstraction, wrapper, type conversion, option, config, boilerplate or "for later" code nobody asked for. Keep values in the form the platform already gives you. Deletion beats addition. Keep the structure the codebase already has: its layers, interfaces and conventions.
- The shortest working diff wins, once you know everything it must touch. A one-liner that needs decoding is not short.
- Comment only the why the code cannot show, in one line.
- Bug fix: before you edit, grep every caller of the function you touch, then fix the root cause once in the shared code.
- Code you move or merge keeps its error handling and validation.
- Between options of equal size, take the one that is correct on edge cases.
- Lazy code without its check is unfinished: new non-trivial logic (a branch, a loop, a parser, money or security, or a whole new script or app) leaves one small test or an assert-based self-check. Trivial changes need none.
- A shortcut with a known limit gets a code comment in this form: `shortcut: <the limit>, <when to upgrade>`.

Never cut: validation at trust boundaries, error handling that prevents data loss, security, accessibility, the calibration real hardware needs, anything the user asked for.

(Yes, this file also applies to agents working on the ponytail repo itself. Especially to them.)

PONYTAIL_RULES
      # Sem hooks, o cliente recebe o nivel como regra (tabela Levels do SKILL.md oficial).
      case "$PONYTAIL_MODE" in
        lite) printf '## Level: lite\n\nBuild what was asked. Name the smaller option in one line and let the user pick.\n' >> "$out" ;;
        ultra) printf '## Level: ultra\n\nAlso question the request: before building, push back on any part the need does not justify.\n' >> "$out" ;;
      esac ;;
    graphify) cat > "$out" <<'RULES'
## Graphify
Before exploring a Git repository broadly (reading many files, searching across the tree or mapping its architecture), run `graphify-preflight ensure` in the repository. It compares the graph's recorded commit and tree hash with Git at no token cost, and creates or updates the local code graph (graphify-out/, offline AST extraction) when it is missing or stale. Then ask the graph first with `graphify query "<question>"`, `graphify explain "<symbol>"` or `graphify path "A" "B"`, and open only the files it points to. When the preflight reports the graph as current, trust it without re-checking. Do not commit graphify-out/; the preflight keeps it in .git/info/exclude. If graphify-preflight or graphify is unavailable, explore normally.
RULES
      ;;
    *) die "Addon sem regras gerenciadas: $1" ;;
  esac
}

# Uso: graphify_skill PLATAFORMA ORIGEM DESTINO. Roda graphify install em HOME temporario (no
# Claude ele editaria o CLAUDE.md fora dos blocos gerenciados) e copia so a skill para DESTINO.
# Deixa em GRAPHIFY_SCRATCH a pasta temporaria, para quem precisar de outro arquivo gerado.
graphify_skill() {
  local source dest="$3"
  GRAPHIFY_SCRATCH="$TMP_WORKDIR/graphify-$1"
  rm -rf -- "$GRAPHIFY_SCRATCH"
  mkdir -p "$GRAPHIFY_SCRATCH/.config"
  (cd "$GRAPHIFY_SCRATCH" && env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u COPILOT_HOME -u KIMI_CODE_HOME \
    HOME="$GRAPHIFY_SCRATCH" XDG_CONFIG_HOME="$GRAPHIFY_SCRATCH/.config" \
    "$LOCAL_BIN/graphify" install --platform "$1" </dev/null) >&2
  source="$GRAPHIFY_SCRATCH/$2"
  [[ -f "$source/SKILL.md" ]] || die "graphify install --platform $1 nao gerou a skill esperada."
  [[ ! -L "$dest" ]] || die "Revise o link simbolico antes de prosseguir: $dest"
  if [[ -d "$dest" ]] && diff -rq -- "$source" "$dest" >/dev/null 2>&1; then
    printf 'Skill graphify ja confere: %s\n' "$dest"
    return 0
  fi
  backup_path "$dest"
  rm -rf -- "$dest"
  mkdir -p "${dest%/*}"
  cp -R -- "$source" "$dest"
  printf 'Skill graphify: %s\n' "$dest"
}

# Uso: rtk_cline_rules SAIDA. Regras do RTK para clientes sem hook de comando (rtk init --agent cline).
rtk_cline_rules() {
  local dir="$TMP_WORKDIR/rtk-cline-rules"
  mkdir -p "$dir"
  (cd "$dir" && "$LOCAL_BIN/rtk" init --agent cline)
  [[ -s "$dir/.clinerules" ]] || die 'RTK nao gerou instrucoes esperadas.'
  cp -- "$dir/.clinerules" "$1"
}

# Uso: rtk_kimi_rules SAIDA. Gera as regras do Kimi em temporario, sem tocar no projeto atual.
rtk_kimi_rules() {
  local dir="$TMP_WORKDIR/rtk-kimi-rules"
  mkdir -p "$dir"
  (cd "$dir" && "$LOCAL_BIN/rtk" init --agent kimi)
  [[ -s "$dir/AGENTS.md" ]] || die 'RTK nao gerou instrucoes esperadas para Kimi.'
  cp -- "$dir/AGENTS.md" "$1"
}

set_ponytail_default_mode() {
  assert_regular_or_absent "$PONYTAIL_CONFIG"
  backup_path "$PONYTAIL_CONFIG"
  python3 - "$PONYTAIL_CONFIG" "$PONYTAIL_MODE" "${PONYTAIL_QUIET:-}" "${PONYTAIL_HIDE:-}" <<'PY'
import json, os, pathlib, stat, sys, tempfile
p, mode, quiet, hide = pathlib.Path(sys.argv[1]), *sys.argv[2:]
if p.exists():
    try:
        data = json.loads(p.read_text(encoding="utf-8-sig") or "{}")
    except Exception as exc:
        raise SystemExit(f"{p} nao e JSON valido; nenhuma alteracao feita: {exc}")
    if not isinstance(data, dict):
        raise SystemExit(f"{p} precisa conter um objeto JSON no topo")
    file_mode = stat.S_IMODE(p.stat().st_mode)
else:
    data, file_mode = {}, 0o600
wanted = {"defaultMode": mode}
for key, value in (("quietStartup", quiet), ("hideStatus", hide)):
    if value:
        wanted[key] = value == "true"
if any(data.get(key) != value for key, value in wanted.items()):
    data.update(wanted)
    p.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".config.json.", dir=str(p.parent))
    try:
        os.fchmod(fd, file_mode)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
        os.replace(tmp, p)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
print(f"Ponytail: {', '.join(f'{k}={v}' for k, v in wanted.items())} em {p}")
PY
}
