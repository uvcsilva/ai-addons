#!/usr/bin/env bash
# Orquestrador: le um JSON e executa o bootstrap e os seis instaladores, um por vez.
# Os instaladores continuam independentes; este script so monta e encadeia os argumentos.
set -Eeuo pipefail
umask 077

SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/addons.json"
DRY_RUN=0
TMP_DIR=""

usage() {
  cat <<EOF
Uso: bash $SCRIPT_NAME [--config ARQUIVO] [--dry-run]

Le um arquivo JSON e executa, nesta ordem e um por vez:
  install-dependencies-ubuntu.sh (bootstrap), engram, serena, context7, rtk,
  ccusage e ponytail.

  --config ARQUIVO  JSON com os parametros. Padrao: addons.json ao lado deste script.
  --dry-run         Valida o JSON e executa --dry-run em cada instalador, sem
                    alterar nada. O bootstrap so e exibido, pois nao tem simulacao.
  --help            Mostra esta ajuda.

Antes de instalar, todos os instaladores sao conferidos com --dry-run; um
argumento invalido interrompe tudo antes de qualquer alteracao. Formato do JSON
no README, secao "Orquestrador".
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
      CONFIG="$2"
      shift ;;
    --dry-run) DRY_RUN=1 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Opcao desconhecida: $1. Use --help." ;;
  esac
  shift
done

((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))) || die 'Use Bash 4.4 ou superior no Ubuntu.'
command -v python3 >/dev/null 2>&1 || die 'python3 e necessario para ler o JSON. Instale com: sudo apt-get install -y python3'
[[ -f "$CONFIG" ]] || die "Arquivo de configuracao nao encontrado: $CONFIG"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/addons-all.XXXXXX")"
# Plano em NUL: total de etapas, depois nome, script, quantidade de argumentos e argumentos.
python3 - "$CONFIG" > "$TMP_DIR/plan" <<'PY' || die "Configuracao invalida: $CONFIG"
import json, os, re, sys

path = sys.argv[1]
ADDONS = [("engram", "install-engram-ubuntu.sh"), ("serena", "install-serena-ubuntu.sh"),
          ("context7", "install-context7-ubuntu.sh"), ("rtk", "install-rtk-ubuntu.sh"),
          ("ccusage", "install-ccusage-ubuntu.sh"), ("ponytail", "install-ponytail-ubuntu.sh")]
TOP_KEYS = {"$schema", "clients", "options", "bootstrap", "addons"}
BOOTSTRAP_KEYS = {"enabled", "clients", "upgrade", "with-opencode"}
KEY = re.compile(r"^[a-z][a-z0-9-]*$")
# Opcoes que recebem true/false como valor; nas demais, true vira so a flag.
VALUE_BOOLS = {"serena": {"enable-web-dashboard", "open-web-dashboard"},
               "ponytail": {"quiet-startup", "hide-status"},
               "rtk": {"trust-filters", "tracking"}}

def fail(message):
    raise SystemExit(f"{path}: {message}")

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail(f"chave duplicada: {key}")
        result[key] = value
    return result

try:
    with open(path, encoding="utf-8-sig") as f:
        config = json.load(f, object_pairs_hook=unique_object)
except (OSError, ValueError) as exc:
    fail(f"JSON invalido: {exc}")
if not isinstance(config, dict):
    fail("a raiz precisa ser um objeto")
unknown = set(config) - TOP_KEYS
if unknown:
    fail(f"chaves desconhecidas na raiz: {', '.join(sorted(unknown))}")

def clients_value(value, where):
    if isinstance(value, list) and value and all(isinstance(c, str) and c for c in value):
        return ",".join(value)
    if isinstance(value, str) and value:
        return value
    fail(f"{where}.clients precisa ser texto ou lista de textos, nao vazio")

def section(value, where):
    # true/false e atalho para {"enabled": ...}.
    if isinstance(value, bool):
        return {"enabled": value}
    if not isinstance(value, dict):
        fail(f"{where} precisa ser objeto ou booleano")
    if not isinstance(value.get("enabled", True), bool):
        fail(f"{where}.enabled precisa ser booleano")
    return value

def to_args(options, where, addon=None):
    args = []
    for key, value in options.items():
        if key == "enabled":
            continue
        if not KEY.match(key) or key in ("dry-run", "help"):
            fail(f"{where}: opcao invalida: {key}")
        if key == "clients":
            value = clients_value(value, where)
        elif isinstance(value, list):
            # Listas viram texto separado por virgulas, como nas opcoes dos scripts.
            if not all(isinstance(v, str) and v and "," not in v for v in value):
                fail(f"{where}.{key}: lista precisa conter textos sem virgula")
            value = ",".join(value) or None
        elif isinstance(value, dict):
            value = json.dumps(value, ensure_ascii=False) if value else None
        if isinstance(value, bool) and key in VALUE_BOOLS.get(addon, ()):
            value = "true" if value else "false"
        if value is True:
            args.append("--" + key)
        elif value is False or value is None:
            continue
        elif isinstance(value, (int, float)):
            args += ["--" + key, str(value)]
        elif isinstance(value, str):
            if not value or "\0" in value or "\n" in value:
                fail(f"{where}.{key}: valor vazio ou com quebra de linha")
            if value == "~" or value.startswith("~/"):
                value = os.path.expanduser(value)
            args += ["--" + key, value]
        else:
            fail(f"{where}.{key}: use texto, numero, booleano, lista, objeto ou null")
    return args

base = {}
if "clients" in config:
    base["clients"] = clients_value(config["clients"], "raiz")
options = config.get("options", {})
if not isinstance(options, dict):
    fail("options precisa ser objeto")
if "clients" in options:
    fail("use clients na raiz, nao em options")

steps = []
bootstrap = section(config.get("bootstrap", True), "bootstrap")
unknown = set(bootstrap) - BOOTSTRAP_KEYS
if unknown:
    fail(f"bootstrap aceita somente {', '.join(sorted(BOOTSTRAP_KEYS))}; recebido: {', '.join(sorted(unknown))}")
if bootstrap.get("enabled", True):
    steps.append(("bootstrap", "install-dependencies-ubuntu.sh", to_args({**base, **bootstrap}, "bootstrap")))

addons = config.get("addons", {})
if not isinstance(addons, dict):
    fail("addons precisa ser objeto")
unknown = set(addons) - {name for name, _ in ADDONS}
if unknown:
    fail(f"addons desconhecidos: {', '.join(sorted(unknown))}")
for name, script in ADDONS:
    # Addon ausente do JSON e instalado com os padroes.
    addon = section(addons.get(name, True), f"addons.{name}")
    if addon.get("enabled", True):
        steps.append((name, script, to_args({**base, **options, **addon}, f"addons.{name}", name)))
if not steps:
    fail("nenhuma etapa habilitada")

items = [str(len(steps))]
for name, script, args in steps:
    items += [name, script, str(len(args))] + args
sys.stdout.write("\0".join(items) + "\0")
PY
mapfile -d '' -t PLAN < "$TMP_DIR/plan"

# Percorre o plano; phase = preflight (simulacao) ou run (instalacao).
run_steps() {
  local phase="$1" i=1 step=0 total="${PLAN[0]}" name script count
  local -a args
  while ((i < ${#PLAN[@]})); do
    name="${PLAN[i]}" script="${PLAN[i+1]}" count="${PLAN[i+2]}"
    args=("${PLAN[@]:i+3:count}")
    i=$((i + 3 + count))
    step=$((step + 1))
    [[ -f "$SCRIPT_DIR/$script" ]] || die "Script nao encontrado: $SCRIPT_DIR/$script"
    if [[ "$phase" == preflight ]]; then
      if [[ "$name" == bootstrap ]]; then
        printf '[%d/%d] bootstrap (sem simulacao): bash %s' "$step" "$total" "$script"
        printf ' %q' ${args[@]+"${args[@]}"}
        printf '\n'
        continue
      fi
      if ! bash "$SCRIPT_DIR/$script" ${args[@]+"${args[@]}"} --dry-run > "$TMP_DIR/dry-$name.txt" 2>&1; then
        cat "$TMP_DIR/dry-$name.txt" >&2
        die "Argumentos invalidos para $name; nada foi instalado. Revise $CONFIG."
      fi
      printf '[%d/%d] %s: argumentos conferidos.\n' "$step" "$total" "$name"
      if [[ "$DRY_RUN" == 1 ]]; then sed 's/^/    /' "$TMP_DIR/dry-$name.txt"; fi
    else
      printf '\n==> [%d/%d] %s: bash %s' "$step" "$total" "$name" "$script"
      printf ' %q' ${args[@]+"${args[@]}"}
      printf '\n'
      bash "$SCRIPT_DIR/$script" ${args[@]+"${args[@]}"} \
        || die "Falha em $name (etapa $step/$total). Corrija e reexecute; etapas concluidas podem ser repetidas com seguranca."
      # Os CLIs instalados pelo bootstrap precisam estar no PATH das proximas etapas.
      if [[ "$name" == bootstrap ]]; then export PATH="$HOME/.local/bin:$PATH"; fi
    fi
  done
}

printf 'Configuracao: %s\n' "$CONFIG"
run_steps preflight
if [[ "$DRY_RUN" == 1 ]]; then
  printf '\nSimulacao concluida; nenhuma alteracao feita.\n'
  exit 0
fi
run_steps run
printf '\nConcluido: todas as etapas habilitadas em %s terminaram.\n' "$CONFIG"
printf 'Abra uma nova sessao (ou export PATH="$HOME/.local/bin:$PATH") e reinicie os agentes.\n'
