# shellcheck shell=bash disable=SC2154
# Editor dos arquivos MCP em JSON/JSONC (Cline, OpenCode, Copilot CLI, VS Code, Antigravity).
# Requer lib/common.sh e OPENCODE_MAJOR, definido pelo instalador (vazio fora do OpenCode).

edit_client_json() {
  local mode="$1" file="$2" kind="$3" name="$4"; shift 4
  assert_regular_or_absent "$file"
  [[ "$mode" != apply ]] || backup_path "$file"
  python3 - "$mode" "$file" "$kind" "$name" "$OPENCODE_MAJOR" "$@" <<'PY'
import json, os, pathlib, re, shutil, stat, sys, tempfile
mode, filename, kind, name, major = sys.argv[1:6]
args = sys.argv[6:]
p = pathlib.Path(filename)
def read_config_text():
    text=p.read_text() if p.exists() else ''
    # Arquivo vazio (comum no settings.json do VS Code) equivale a objeto vazio.
    return text if text.strip() else '{}\n'
original = read_config_text()
pattern = re.compile(r'\s+|//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null|[{}\[\]:,]')
def parse(text):
    tokens=[]; pos=0
    while pos < len(text):
        m=pattern.match(text,pos)
        if not m: raise ValueError('JSONC invalido; arquivo nao alterado')
        v=m.group(); pos=m.end()
        if not (v.isspace() or v.startswith('//') or v.startswith('/*')): tokens.append((v,m.start(),m.end()))
    i=0; objects={}; spans={}
    def value(path):
        nonlocal i
        if i >= len(tokens): raise ValueError('JSONC incompleto')
        t,start,end=tokens[i]; i+=1
        if t=='{':
            out={}; trailing=False
            while tokens[i][0]!='}':
                k=json.loads(tokens[i][0]); i+=1
                if not isinstance(k,str) or k in out: raise ValueError('Chave duplicada/invalida')
                if tokens[i][0]!=':': raise ValueError('Falta dois-pontos')
                i+=1; out[k]=value(path+(k,)); trailing=False
                if tokens[i][0]==',': i+=1; trailing=True
                elif tokens[i][0]!='}': raise ValueError('Falta virgula')
            close=tokens[i][1]; end=tokens[i][2]; i+=1
            objects[path]=(close,bool(out),trailing)
        elif t=='[':
            out=[]
            while tokens[i][0]!=']':
                out.append(value(path+(len(out),)))
                if tokens[i][0]==',': i+=1
                elif tokens[i][0]!=']': raise ValueError('Falta virgula')
            end=tokens[i][2]; i+=1
        else:
            out=json.loads(t)
        spans[path]=(start,end)
        return out
    root=value(())
    if i!=len(tokens) or not isinstance(root,dict): raise ValueError('Raiz JSONC deve ser objeto unico')
    return root,objects,spans
def build(command, argv):
    if kind=='opencode':
        entry={'type':'local','command':[command]+argv}
        entry.update({'disabled':False} if major=='2' else {'enabled':True})
        return entry
    entry={'command':command,'args':argv}
    if kind=='cline': entry.update(disabled=False,autoApprove=[])
    elif kind=='copilot': entry.update(type='local',tools=['*'])
    elif kind=='vscode': entry.update(type='stdio')
    elif kind=='antigravity': pass
    else: raise ValueError('Cliente desconhecido')
    return entry
if kind=='memory':
    changes=[((key,),False,True,None) for key in ('github.copilot.chat.tools.memory.enabled','github.copilot.chat.copilotMemory.enabled')]
else:
    paths={'cline':('mcpServers',name),'copilot':('mcpServers',name),'vscode':('servers',name),
           'antigravity':('mcpServers',name),
           'opencode':('mcp','servers',name) if major=='2' else ('mcp',name)}
    if kind not in paths: raise ValueError('Cliente desconhecido')
    legacy=json.loads(os.environ.get('LEGACY_MCP_ARGV') or '[]')
    if not isinstance(legacy,list) or not all(isinstance(x,str) for x in legacy):
        raise ValueError('LEGACY_MCP_ARGV precisa ser lista JSON de strings')
    # new_client_mcp stores npx by absolute path, so the legacy entry did too.
    if legacy[:1]==['npx']: legacy[0]=shutil.which('npx') or 'npx'
    changes=[(paths[kind],build(args[0],args[1:]),False,build(legacy[0],legacy[1:]) if legacy else None)]
if kind=='opencode':
    root,_,_=parse(original)
    current=root.get('mcp',{})
    if not isinstance(current,dict): raise ValueError('mcp precisa ser objeto')
    if major=='1' and 'servers' in current: raise ValueError('Encontrado schema MCP v2; confira --opencode-major')
    if major=='2' and any(isinstance(v,dict) and 'type' in v for v in current.values()):
        raise ValueError('Encontrado schema MCP v1; migre antes de instalar no v2')
def owned(node):
    # Mesmo binario instalado por este pacote, com outros argumentos: atualiza as opcoes.
    if kind=='memory' or not isinstance(node,dict) or not args[0].startswith('/'): return False
    command=node.get('command')
    return command[:1]==[args[0]] if kind=='opencode' and isinstance(command,list) else command==args[0]
text=original
for path,expected,replace,legacy in changes:
    root,objects,spans=parse(text)
    node=root
    for depth,key in enumerate(path):
        if not isinstance(node,dict): raise ValueError('Estrutura JSONC conflitante; revise manualmente')
        if key not in node:
            nested=expected
            for child in reversed(path[depth+1:]): nested={child:nested}
            close,has,trailing=objects[path[:depth]]
            insertion=(',' if has and not trailing else '')+'\n'+json.dumps(key)+': '+json.dumps(nested,ensure_ascii=False,indent=2)+'\n'
            text=text[:close]+insertion+text[close:]; break
        if depth==len(path)-1:
            if node[key]!=expected:
                if not replace and (legacy is None or node[key]!=legacy) and not owned(node[key]): raise ValueError(f'Conflito MCP {name}: {filename}; nenhuma entrada substituida')
                a,b=spans[path]; text=text[:a]+json.dumps(expected)+text[b:]
        node=node[key]
# Verify all resulting settings before committing the file.
root,_,_=parse(text)
for path,expected,*_ in changes:
    node=root
    for key in path: node=node[key]
    if node!=expected: raise ValueError('Verificacao JSONC falhou')
if mode=='verify' and text!=original: raise ValueError('Configuracao esperada ausente')
if mode=='apply' and text!=original:
    p.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix='.'+p.name+'.',dir=str(p.parent))
    try:
        with os.fdopen(fd,'w') as f: f.write(text)
        os.chmod(tmp,stat.S_IMODE(p.stat().st_mode) if p.exists() else 0o600)
        if read_config_text()!=original: raise ValueError('Arquivo mudou durante a edicao')
        os.replace(tmp,p)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
print(f'{mode}: {kind}/{name}: {filename}')
PY
}

