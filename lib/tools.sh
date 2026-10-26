# shellcheck shell=bash disable=SC2154
# Instalacao das ferramentas dos addons e dos arquivos globais delas, sem configurar clientes.
# Requer lib/common.sh e lib/config.sh carregadas e config_load executado.
# shortcut: baixa as ferramentas uma vez por provedor; se pesar, pular download quando a mesma execucao do install-all ja instalou.

# Comandos que o instalador deve passar a installer_begin para instalar as ferramentas.
# shellcheck disable=SC2034
TOOLS_PREREQS=(curl sha256sum node npm)
TOOLS_REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RTK_CONFIG="${XDG_CONFIG_HOME:-$HOME_DIR/.config}/rtk/config.toml"
# ccusage le o primeiro diretorio de CLAUDE_CONFIG_DIR, ou ~/.config/claude.
if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then CCUSAGE_CONFIG="${CLAUDE_CONFIG_DIR%%,*}/ccusage.json"; else CCUSAGE_CONFIG="$HOME_DIR/.config/claude/ccusage.json"; fi

# Le e valida as opcoes de instalacao das ferramentas (chame depois de config_load).
tools_load_options() {
  local path
  WITH_GO="$(config_opt serena with-go false)"
  CHECK_GO_PROJECT="$(config_opt serena check-go-project)"
  SERENA_LS_DEPS="$(config_opt serena ls-dependencies)"
  RTK_TELEMETRY="$(config_opt rtk telemetry)"
  RTK_RECALL="$(config_opt rtk recall)"
  RTK_AWARENESS="$(config_opt rtk awareness)"
  RTK_EXCLUDE="$(config_opt rtk exclude-commands)"
  RTK_TRACKING="$(config_opt rtk tracking)"
  RTK_HISTORY_DAYS="$(config_opt rtk history-days)"
  CCUSAGE_SETTINGS="$(config_opt ccusage settings)"
  case "$WITH_GO" in true|false) ;; *) printf 'Use true ou false em addons.serena.with-go\n' >&2; exit 2 ;; esac
  [[ -z "$SERENA_LS_DEPS" || "$SERENA_LS_DEPS" =~ ^[A-Za-z0-9_-]+(,[A-Za-z0-9_-]+)*$ ]] || { printf 'Use uma lista de nomes em addons.serena.ls-dependencies\n' >&2; exit 2; }
  case "$RTK_TELEMETRY" in ''|enable|disable) ;; *) printf 'Use addons.rtk.telemetry enable ou disable\n' >&2; exit 2 ;; esac
  case "$RTK_RECALL" in ''|sqlite|tee|disabled) ;; *) printf 'Use addons.rtk.recall sqlite, tee ou disabled\n' >&2; exit 2 ;; esac
  case "$RTK_AWARENESS" in ''|default|high|full) ;; *) printf 'Use addons.rtk.awareness default, high ou full\n' >&2; exit 2 ;; esac
  case "$RTK_TRACKING" in ''|true|false) ;; *) printf 'Use true ou false em addons.rtk.tracking\n' >&2; exit 2 ;; esac
  [[ -z "$RTK_HISTORY_DAYS" || "$RTK_HISTORY_DAYS" =~ ^[1-9][0-9]*$ ]] || { printf 'Use addons.rtk.history-days com um inteiro positivo\n' >&2; exit 2; }
  if [[ -n "$CCUSAGE_SETTINGS" ]]; then
    python3 -c 'import json,sys; v=json.loads(sys.argv[1]); sys.exit(0 if isinstance(v,dict) and v else 1)' "$CCUSAGE_SETTINGS" 2>/dev/null \
      || { printf 'Use addons.ccusage.settings com um objeto JSON nao vazio (formato do ccusage.json)\n' >&2; exit 2; }
  fi
  for path in "$RTK_CONFIG" "$CCUSAGE_CONFIG" "${CHECK_GO_PROJECT:-/}"; do
    [[ "$path" == /* && "$path" != *$'\n'* ]] || { printf 'Caminho precisa ser absoluto, sem quebra de linha: %s\n' "$path" >&2; exit 2; }
  done
}

# Confere a arquitetura e faz backup dos destinos antes de qualquer download (depois de installer_begin).
tools_check() {
  local path
  case "$(uname -m)" in
    x86_64|amd64) ASSET_ARCH=amd64; RTK_ASSET='rtk-x86_64-unknown-linux-musl.tar.gz'; UV_ASSET='uv-x86_64-unknown-linux-gnu.tar.gz' ;;
    aarch64|arm64) ASSET_ARCH=arm64; RTK_ASSET='rtk-aarch64-unknown-linux-gnu.tar.gz'; UV_ASSET='uv-aarch64-unknown-linux-gnu.tar.gz' ;;
    *) die "Arquitetura nao suportada: $(uname -m). Use x86_64 ou aarch64." ;;
  esac
  for path in "$LOCAL_BIN/engram" "$LOCAL_BIN/rtk" "$RTK_CONFIG" "$LOCAL_BIN/uv" "$LOCAL_BIN/uvx" "$LOCAL_BIN/graphify-preflight"; do
    assert_regular_or_absent "$path"
    backup_path "$path"
  done
}

# Instala Engram, uv+Serena, Graphify, context7-mcp e RTK, nessa ordem (depois de tools_check).
tools_install() {
  local tag
  local -a serena_ls=()
  tag="$(download_verified_release_asset 'Gentleman-Programming/engram' "@engram-linux-$ASSET_ARCH" "$TMP_WORKDIR/engram.tar.gz")"
  extract_archive_binary "$TMP_WORKDIR/engram.tar.gz" engram "$TMP_WORKDIR/engram"
  install -m 0755 "$TMP_WORKDIR/engram" "$LOCAL_BIN/engram"
  printf 'Engram instalado: %s\n' "$tag"
  ENGRAM_INSTALLED_VERSION="$("$LOCAL_BIN/engram" version)"
  printf '%s\n' "$ENGRAM_INSTALLED_VERSION"
  warn_engram_runtime_version "$ENGRAM_INSTALLED_VERSION"

  tag="$(download_verified_release_asset 'astral-sh/uv' "$UV_ASSET" "$TMP_WORKDIR/uv.tar.gz")"
  extract_archive_binary "$TMP_WORKDIR/uv.tar.gz" uv "$TMP_WORKDIR/uv"
  extract_archive_binary "$TMP_WORKDIR/uv.tar.gz" uvx "$TMP_WORKDIR/uvx"
  install -m 0755 "$TMP_WORKDIR/uv" "$LOCAL_BIN/uv"
  install -m 0755 "$TMP_WORKDIR/uvx" "$LOCAL_BIN/uvx"
  printf 'uv instalado: %s\n' "$tag"
  export UV_TOOL_BIN_DIR="$LOCAL_BIN"
  export UV_TOOL_DIR="$HOME_DIR/.local/share/uv/tools"
  export UV_CACHE_DIR="$HOME_DIR/.cache/uv"
  "$LOCAL_BIN/uv" tool install --upgrade -p 3.13 serena-agent
  [[ -x "$LOCAL_BIN/serena" ]] || die 'uv nao criou ~/.local/bin/serena.'
  if [[ "$WITH_GO" == true ]]; then prepare_go; fi
  if [[ -n "$SERENA_LS_DEPS" ]]; then
    "$LOCAL_BIN/serena" --help | grep -Fq download-ls-dependencies || die 'Esta versao do Serena nao tem download-ls-dependencies.'
    IFS=, read -r -a serena_ls <<< "$SERENA_LS_DEPS"
    "$LOCAL_BIN/serena" download-ls-dependencies "${serena_ls[@]}"
  fi
  "$LOCAL_BIN/serena" --version
  if [[ -n "$CHECK_GO_PROJECT" ]]; then check_go_project; fi

  "$LOCAL_BIN/uv" tool install --upgrade -p 3.13 graphifyy
  [[ -x "$LOCAL_BIN/graphify" ]] || die 'uv nao criou ~/.local/bin/graphify.'
  "$LOCAL_BIN/graphify" --version
  # O pre-flight compara o _meta do grafo com o Git antes de o agente consultar o grafo.
  install -m 0755 "$TOOLS_REPO_DIR/bin/graphify-preflight" "$LOCAL_BIN/graphify-preflight"

  npm install --global --prefix "$HOME_DIR/.local" --registry=https://registry.npmjs.org --engine-strict=true @upstash/context7-mcp@latest
  [[ -x "$LOCAL_BIN/context7-mcp" ]] || die 'context7-mcp nao apareceu em ~/.local/bin.'

  tag="$(download_verified_release_asset 'rtk-ai/rtk' "$RTK_ASSET" "$TMP_WORKDIR/rtk.tar.gz")"
  extract_archive_binary "$TMP_WORKDIR/rtk.tar.gz" rtk "$TMP_WORKDIR/rtk"
  install -m 0755 "$TMP_WORKDIR/rtk" "$LOCAL_BIN/rtk"
  printf 'RTK instalado: %s\n' "$tag"
  # Antes do rtk init dos provedores: awareness muda as instrucoes que o init grava.
  if [[ -n "$RTK_TELEMETRY" ]]; then "$LOCAL_BIN/rtk" telemetry "$RTK_TELEMETRY"; fi
  if [[ -n "$RTK_RECALL" ]]; then "$LOCAL_BIN/rtk" config recall "$RTK_RECALL"; fi
  set_rtk_config
  "$LOCAL_BIN/rtk" --version
}

# Somente o instalador do Claude: ccusage analisa os dados do Claude Code.
tools_install_ccusage() {
  npm install --global --prefix "$HOME_DIR/.local" --registry=https://registry.npmjs.org --engine-strict=true ccusage@latest
  [[ -x "$LOCAL_BIN/ccusage" ]] || die 'ccusage nao apareceu em ~/.local/bin.'
  "$LOCAL_BIN/ccusage" --version
  "$LOCAL_BIN/ccusage" --help >/dev/null
  if [[ -n "$CCUSAGE_SETTINGS" ]]; then set_ccusage_settings; fi
}

# Resolve an official release asset and its GitHub API SHA-256 digest.
release_asset_metadata() {
  local repo="$1" asset="$2" api_json="$TMP_WORKDIR/release.json" auth=()
  # GITHUB_TOKEN opcional evita o limite anonimo da API; vai por arquivo, fora da linha de comando.
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" > "$TMP_WORKDIR/github-auth.header"
    auth=(-H "@$TMP_WORKDIR/github-auth.header")
  fi
  curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 \
    ${auth[@]+"${auth[@]}"} \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    -H 'User-Agent: six-addons-ubuntu-installer' \
    "https://api.github.com/repos/$repo/releases/latest" -o "$api_json"
  python3 - "$repo" "$asset" "$api_json" <<'PY'
import json, pathlib, sys, urllib.parse
repo, wanted, path = sys.argv[1:]
data = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
if data.get("draft") or data.get("prerelease"):
    raise SystemExit("GitHub API retornou release nao-estavel")
tag = data.get("tag_name", "")
if wanted.startswith("@engram-linux-"):
    arch = wanted.rsplit("-", 1)[1]
    version = tag[1:] if tag.startswith("v") else tag
    wanted = f"engram_{version}_linux_{arch}.tar.gz"
hits = [a for a in data.get("assets", []) if a.get("name") == wanted]
if len(hits) != 1:
    raise SystemExit(f"Asset {wanted!r} nao existe unicamente na ultima release estavel de {repo}")
a = hits[0]
digest = a.get("digest", "")
if not digest.startswith("sha256:"):
    raise SystemExit(f"Release {repo}/{tag} nao publicou digest SHA-256 pela API do GitHub")
url = a.get("browser_download_url", "")
parsed = urllib.parse.urlparse(url)
if parsed.scheme != "https" or parsed.netloc != "github.com" or not parsed.path.startswith(f"/{repo}/releases/download/"):
    raise SystemExit("URL do asset nao corresponde ao repositorio oficial esperado")
print(tag + "\t" + url + "\t" + digest.split(":", 1)[1])
PY
}

download_verified_release_asset() {
  local repo="$1" asset="$2" destination="$3" metadata tag url expected actual
  metadata="$(release_asset_metadata "$repo" "$asset")"
  IFS=$'\t' read -r tag url expected <<< "$metadata"
  [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || die "Digest SHA-256 invalido recebido para $repo/$asset"
  printf 'Baixando %s (%s) de %s\n' "$asset" "$tag" "$repo" >&2
  curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 \
    -H 'User-Agent: six-addons-ubuntu-installer' "$url" -o "$destination"
  actual="$(sha256sum "$destination" | awk '{print $1}')"
  [[ "${actual,,}" == "${expected,,}" ]] || die "SHA-256 nao confere para $repo/$asset; arquivo descartado"
  printf 'SHA-256 validado: %s\n' "$asset" >&2
  printf '%s\n' "$tag"
}

extract_archive_binary() {
  local archive="$1" binary="$2" output="$3"
  python3 - "$archive" "$binary" "$output" <<'PY'
import os, pathlib, sys, tarfile
archive, wanted, output = sys.argv[1:]
matches = []
with tarfile.open(archive, "r:gz") as tf:
    for member in tf.getmembers():
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit(f"Caminho inseguro no arquivo: {member.name}")
        if path.name == wanted:
            if not member.isfile():
                raise SystemExit(f"O item {wanted} nao e arquivo regular")
            matches.append(member)
    if len(matches) != 1:
        raise SystemExit(f"Esperava um unico binario {wanted}; achei {len(matches)}")
    source = tf.extractfile(matches[0])
    if source is None:
        raise SystemExit(f"Nao foi possivel ler o binario {wanted}")
    data = source.read()
if not data:
    raise SystemExit(f"Binario vazio: {wanted}")
fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o700)
with os.fdopen(fd, "wb") as f:
    f.write(data)
PY
}

prepare_go() {
  local go_version go_archive go_sha go_root
  local -a go_asset
  if ! command -v go >/dev/null 2>&1; then
    for binary in go gofmt; do
      [[ ! -e "$LOCAL_BIN/$binary" && ! -L "$LOCAL_BIN/$binary" ]] || die "Conflito: $LOCAL_BIN/$binary ja existe."
    done
    curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 'https://go.dev/dl/?mode=json' -o "$TMP_WORKDIR/go-releases.json"
    python3 - "$TMP_WORKDIR/go-releases.json" "$(uname -m)" > "$TMP_WORKDIR/go-asset.txt" <<'PYGO'
import json,re,sys
arch={'x86_64':'amd64','amd64':'amd64','aarch64':'arm64','arm64':'arm64'}[sys.argv[2]]
releases=json.load(open(sys.argv[1]))
release=next(r for r in releases if r['stable'])
f=next(f for f in release['files'] if f['os']=='linux' and f['arch']==arch and f['kind']=='archive')
assert re.fullmatch(r'go[0-9]+\.[0-9]+\.[0-9]+',f['version'])
assert f['filename']==f['version']+'.linux-'+arch+'.tar.gz'
assert re.fullmatch(r'[0-9a-f]{64}',f['sha256'])
print(f['version']); print(f['filename']); print(f['sha256'])
PYGO
    mapfile -t go_asset < "$TMP_WORKDIR/go-asset.txt"
    go_version="${go_asset[0]}"; go_archive="${go_asset[1]}"; go_sha="${go_asset[2]}"
    go_root="$HOME_DIR/.local/lib/go/$go_version"
    [[ ! -e "$go_root" && ! -L "$go_root" ]] || die "Destino Go ja existe: $go_root; revise antes de instalar."
    curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 "https://go.dev/dl/$go_archive" -o "$TMP_WORKDIR/go.tar.gz"
    printf '%s  %s\n' "$go_sha" "$TMP_WORKDIR/go.tar.gz" | sha256sum --check --status
    "$UV_TOOL_DIR/serena-agent/bin/python" - "$TMP_WORKDIR/go.tar.gz" "$TMP_WORKDIR/go-unpack" <<'PYGO'
import sys,tarfile
with tarfile.open(sys.argv[1]) as archive:
    archive.extractall(sys.argv[2],filter='data')
PYGO
    mkdir -p "${go_root%/*}"
    mv "$TMP_WORKDIR/go-unpack/go" "$go_root"
    ln -s "$go_root/bin/go" "$LOCAL_BIN/go"
    ln -s "$go_root/bin/gofmt" "$LOCAL_BIN/gofmt"
  fi
  go version
  if ! command -v gopls >/dev/null 2>&1; then
    [[ ! -e "$LOCAL_BIN/gopls" && ! -L "$LOCAL_BIN/gopls" ]] || die "Conflito: $LOCAL_BIN/gopls ja existe."
    # Compilacao sequencial evita esgotar memoria em maquinas pequenas.
    GOMAXPROCS=2 GOBIN="$LOCAL_BIN" go install -p=1 golang.org/x/tools/gopls@latest
  fi
  gopls version
}

check_go_project() {
  [[ -d "$CHECK_GO_PROJECT" && -f "$CHECK_GO_PROJECT/go.mod" ]] || die 'O teste requer um projeto Go com go.mod na raiz.'
  command -v go >/dev/null 2>&1 && command -v gopls >/dev/null 2>&1 || die 'Go/gopls ausentes; use --with-go ou instale-os antes do teste.'
  "$UV_TOOL_DIR/serena-agent/bin/python" - "$LOCAL_BIN/serena" "$CHECK_GO_PROJECT" <<'PYCHECK'
import asyncio,json,os,pathlib,sys,tempfile
from mcp import ClientSession,StdioServerParameters
from mcp.client.stdio import stdio_client
async def check():
    root=pathlib.Path(sys.argv[2]).resolve()
    files=sorted(p for p in root.rglob('*.go') if not any(x in {'.git','vendor','node_modules'} for x in p.relative_to(root).parts))
    if not files: raise RuntimeError('Nenhum arquivo Go encontrado para o teste')
    args=['start-mcp-server','--context','codex','--agent-interface','tools','--project',str(root),'--add-mode','no-memories','--enable-web-dashboard','False','--open-web-dashboard','False']
    params=StdioServerParameters(command=sys.argv[1],args=args,env=dict(os.environ,GOMAXPROCS='2'))
    with tempfile.TemporaryFile(mode='w+') as log:
        async with stdio_client(params,errlog=log) as (read,write):
            async with ClientSession(read,write) as session:
                await session.initialize()
                result=await session.call_tool('get_symbols_overview',{'relative_path':str(files[0].relative_to(root)),'depth':0,'max_answer_chars':10000})
                text='\n'.join(c.text for c in result.content if hasattr(c,'text'))
                # MCP v1 usa isError; v2 renomeou o atributo para is_error.
                if getattr(result,'is_error',getattr(result,'isError',False)) or 'Error executing tool' in text: raise RuntimeError(text)
                symbols=json.loads(text)
                if not isinstance(symbols,dict) or not any(symbols.values()): raise RuntimeError('LSP nao retornou simbolos; revise o arquivo/projeto')
                print('Serena: leitura real de simbolos confirmada em',files[0])
try:
    asyncio.run(asyncio.wait_for(check(),timeout=180))
except Exception as exc:
    raise SystemExit('Falha na validacao Serena/Go: '+str(exc))
PYCHECK
}

# Edita somente as chaves pedidas no config.toml do RTK, preservando o resto do arquivo.
set_rtk_config() {
  python3 - "$RTK_CONFIG" "$RTK_AWARENESS" "$RTK_EXCLUDE" "$RTK_TRACKING" "$RTK_HISTORY_DAYS" <<'PY'
import copy, json, os, pathlib, re, stat, sys, tempfile
p = pathlib.Path(sys.argv[1]); awareness, exclude, tracking, history = sys.argv[2:]
changes = []
if awareness: changes.append(("awareness", "level", awareness))
if exclude: changes.append(("hooks", "exclude_commands", [c.strip() for c in exclude.split(",") if c.strip()]))
if tracking: changes.append(("tracking", "enabled", tracking == "true"))
if history: changes.append(("tracking", "history_days", int(history)))
if not changes:
    raise SystemExit(0)
text = p.read_text(encoding="utf-8") if p.exists() else ""
mode = stat.S_IMODE(p.stat().st_mode) if p.exists() else 0o600
try:
    import tomllib
except ImportError:
    tomllib = None
if tomllib:
    before = tomllib.loads(text)
elif chr(34) * 3 in text or chr(39) * 3 in text:
    raise SystemExit("TOML multiline requer Python 3.11+; config.toml do RTK nao alterado")
def literal(value):
    if isinstance(value, bool): return "true" if value else "false"
    if isinstance(value, int): return str(value)
    if isinstance(value, list): return "[" + ", ".join(json.dumps(v, ensure_ascii=False) for v in value) + "]"
    return json.dumps(value, ensure_ascii=False)
def bracket_depth(line):
    # Saldo de colchetes fora de strings e comentarios TOML.
    depth, quote, i = 0, None, 0
    while i < len(line):
        c = line[i]
        if quote:
            if c == "\\" and quote == '"': i += 1
            elif c == quote: quote = None
        elif c in "\"'": quote = c
        elif c == "#": break
        elif c == "[": depth += 1
        elif c == "]": depth -= 1
        i += 1
    return depth
header = re.compile(r"^\s*\[")
lines = text.splitlines()
first_header = next((i for i, l in enumerate(lines) if header.match(l)), len(lines))
for section, key, value in changes:
    if any(re.match(r"^\s*" + section + r"\s*[.=]", l) for l in lines[:first_header]):
        raise SystemExit(f"config.toml define {section} fora de uma tabela; revise manualmente, sem alteracao")
    starts = [i for i, l in enumerate(lines) if re.match(r"^\s*\[\s*" + section + r"\s*\]\s*(#.*)?$", l)]
    if len(starts) > 1:
        raise SystemExit(f"Tabela [{section}] duplicada; config.toml nao alterado")
    entry = f"{key} = {literal(value)}"
    if not starts:
        if lines and lines[-1].strip(): lines.append("")
        lines += [f"[{section}]", entry]
        continue
    start = starts[0]
    end = next((j for j in range(start + 1, len(lines)) if header.match(lines[j])), len(lines))
    hits = [i for i in range(start + 1, end) if re.match(r"^\s*" + key + r"\s*=", lines[i])]
    if len(hits) > 1:
        raise SystemExit(f"Chave duplicada [{section}].{key}; config.toml nao alterado")
    if hits:
        # O proprio rtk grava listas em varias linhas; substitui o bloco inteiro ate fechar os colchetes.
        last = hits[0]
        depth = bracket_depth(lines[last].split("=", 1)[1])
        if depth and not tomllib:
            raise SystemExit(f"[{section}].{key} ocupa varias linhas e requer Python 3.11+; config.toml nao alterado")
        while depth > 0:
            last += 1
            if last >= end:
                raise SystemExit(f"[{section}].{key} sem fechamento; config.toml nao alterado")
            depth += bracket_depth(lines[last])
        lines[hits[0]:last + 1] = [entry]
    else:
        last = max([start] + [i for i in range(start + 1, end) if lines[i].strip()])
        lines.insert(last + 1, entry)
new_text = "\n".join(lines).rstrip() + "\n"
if tomllib:
    expected = copy.deepcopy(before)
    for section, key, value in changes:
        table = expected.setdefault(section, {})
        if not isinstance(table, dict):
            raise SystemExit(f"{section} nao e tabela TOML; config.toml nao alterado")
        table[key] = value
    if tomllib.loads(new_text) != expected:
        raise SystemExit("Edicao alteraria outra configuracao do RTK; config.toml nao alterado")
if new_text != text:
    p.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".config.toml.", dir=str(p.parent))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(new_text)
        os.replace(tmp, p)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
print("RTK config.toml: " + ", ".join(f"{s}.{k}" for s, k, _ in changes))
PY
}

# Mescla --settings no ccusage.json do usuario, preservando as demais chaves.
set_ccusage_settings() {
  assert_regular_or_absent "$CCUSAGE_CONFIG"
  backup_path "$CCUSAGE_CONFIG"
  python3 - "$CCUSAGE_CONFIG" "$CCUSAGE_SETTINGS" <<'PY'
import json, os, pathlib, stat, sys, tempfile
p, settings = pathlib.Path(sys.argv[1]), json.loads(sys.argv[2])
if p.exists():
    try:
        data = json.loads(p.read_text(encoding="utf-8-sig") or "{}")
    except ValueError as exc:
        raise SystemExit(f"{p} nao e JSON valido; nenhuma alteracao feita: {exc}")
    if not isinstance(data, dict):
        raise SystemExit(f"{p} precisa conter um objeto JSON no topo")
    mode = stat.S_IMODE(p.stat().st_mode)
else:
    data, mode = {"$schema": "https://ccusage.com/config-schema.json"}, 0o600
def merge(base, extra):
    # Objetos sao mesclados; outros valores substituem os existentes.
    for key, value in extra.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            merge(base[key], value)
        else:
            base[key] = value
merge(data, settings)
p.parent.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".ccusage.json.", dir=str(p.parent))
try:
    os.fchmod(fd, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    os.replace(tmp, p)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
print(f"ccusage.json atualizado: {p}")
PY
}

warn_engram_runtime_version() {
  local installed="$1" health endpoint="${ENGRAM_URL:-http://127.0.0.1:${ENGRAM_PORT:-7437}}"
  local -a curl_args=(--silent --fail --max-time 2)
  if [[ -n "${ENGRAM_SOCKET:-}" && -z "${ENGRAM_URL:-}" ]]; then
    curl_args+=(--unix-socket "$ENGRAM_SOCKET")
    endpoint="http://localhost"
  fi
  health=$(curl "${curl_args[@]}" "${endpoint%/}/health" 2>/dev/null) || return 0
  python3 - "$installed" "$health" <<'PY'
import json, re, sys
try:
    health = json.loads(sys.argv[2])
except ValueError:
    sys.exit(0)
if not isinstance(health, dict) or health.get("service") != "engram" or health.get("status") != "ok":
    sys.exit(0)
running = health.get("version")
if not isinstance(running, str):
    sys.exit(0)
installed = re.fullmatch(r"engram v?([0-9]+)\.([0-9]+)\.([0-9]+)", sys.argv[1].strip())
active = re.fullmatch(r"v?([0-9]+)\.([0-9]+)\.([0-9]+)", running)
if installed and active and tuple(map(int, active.groups())) < tuple(map(int, installed.groups())):
    print(f"[AVISO] Servidor Engram ativo {running}; binario instalado {sys.argv[1].strip()}. "
          "Encerre as sessoes dos agentes e reinicie o servidor Engram antes de iniciar novas sessoes. "
          "O instalador nao reiniciou processos.", file=sys.stderr)
PY
}
