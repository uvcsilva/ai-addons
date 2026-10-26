# Addons de IA no Ubuntu — um instalador por provedor

**RTK, Serena, Engram, Context7, ccusage, Ponytail e Graphify**, na mesma máquina e no mesmo
usuário. Suporte a Claude Code, Codex, Cline, OpenCode, Copilot CLI, Copilot no VS Code e Antigravity.
OpenRouter é configurado como provedor dentro do cliente.

Há **um instalador por provedor**. Cada um instala ou atualiza as ferramentas dos addons
e configura nele **todos** os addons (MCPs, regras, plugins e hooks), usando o que aquele
provedor oferece de nativo:

| Instalador | Provedor / superfícies |
|---|---|
| `install-claude-ubuntu.sh` | Claude Code (CLI); também instala o ccusage |
| `install-codex-ubuntu.sh` | OpenAI Codex CLI |
| `install-copilot-ubuntu.sh` | GitHub Copilot: `--surfaces cli,vscode` (padrão: as duas) |
| `install-cline-ubuntu.sh` | Cline (CLI ou extensão) |
| `install-opencode-ubuntu.sh` | OpenCode 1 ou 2 |
| `install-antigravity-ubuntu.sh` | Google Antigravity (`~/.gemini`) |

`install-dependencies-ubuntu.sh` prepara os pré-requisitos e os CLIs dos clientes
(seção 2). `install-all-ubuntu.sh` lê o `addons.json` e roda o bootstrap e os instaladores
dos provedores listados em `clients` (seção 4.1). As opções dos addons ficam no
`addons.json`, lido por todos os instaladores. O código comum fica em `lib/`: **copie a
pasta inteira**, porque os scripts não funcionam sozinhos. Os instaladores de provedor
compartilham um bloqueio de configuração; o bootstrap não participa dele. Execute um
script por vez.

Para instalar tudo de uma vez, com Ponytail no modo `ultra`:

```bash
bash install-all-ubuntu.sh --dry-run
bash install-all-ubuntu.sh
```

Para um provedor só, por exemplo o Codex:

```bash
bash install-codex-ubuntu.sh --dry-run
bash install-codex-ubuntu.sh
```

Os antigos `install-<addon>-ubuntu.sh` foram removidos; veja a migração na seção 4.4.

## 1. Compatibilidade real

| Addon | Claude Code / Codex | Cline | OpenCode 1 / 2 | Copilot CLI | Copilot VS Code | Antigravity |
|---|---|---|---|---|---|---|
| RTK | Hooks globais | Regras | Plugin `rtk.ts` + regras | Hook PreToolUse (`rtk init --copilot`) | Regras | Plugin/hook oficial |
| Serena | MCP, contextos próprios | MCP, contexto `ide` | MCP, contexto `ide` | MCP, `copilot-cli` | MCP, `vscode` | MCP, contexto `antigravity` |
| Engram | MCP + setup/plugin oficial | MCP + protocolo por instruções | MCP + plugin `engram.ts` + instruções | MCP + protocolo por instruções | MCP + protocolo por instruções | MCP + protocolo por instruções |
| Context7 | MCP local (npm) | MCP local (npm) | MCP local (npm) | MCP local (npm) | MCP local (npm) | MCP local (npm) |
| ccusage | Relatórios locais | Sem fonte Cline documentada | Relatórios locais | Relatórios locais | Sem fonte da extensão documentada | Sem fonte Antigravity documentada |
| Ponytail | Plugin oficial | Regras oficiais | Plugin oficial (`opencode plugin`) | Plugin oficial | Regras oficiais | Regras oficiais + plugin de skills (com `agy`) |
| Graphify | Skill + regra de uso | Regra de uso | Skill + plugin (lembrete) + regra | Skill + regra | Regra de uso | Skill + regra |

O ccusage é uma CLI de relatórios; quem a instala é o `install-claude`, e os relatórios
de outros clientes usam a mesma CLI.

**Regras não equivalem a hooks/plugins.** Onde o addon não tem integração nativa para o
cliente (RTK no Cline e no VS Code; Ponytail no Cline, no VS Code e no Antigravity; Engram
fora de Claude, Codex e OpenCode), o agente precisa seguir as instruções. Não há reescrita
automática de comandos pelo RTK, o nível do Ponytail fica fixo nas regras (sem troca por
`/ponytail` nem injeção automática em subagentes), e salvar/recuperar no Engram depende do
agente, sem hooks de ciclo de sessão ou recuperação automática após compactação.

Onde existe integração nativa, o instalador do provedor a usa (seção 3): plugins
`engram.ts`, `rtk.ts` e Ponytail no OpenCode; hook RTK e plugin Ponytail no Copilot CLI;
plugin RTK do Antigravity e, com o CLI `agy`, o plugin de skills do Ponytail. Quando o
plugin injeta as mesmas regras, o bloco antigo sai do arquivo de instruções. Nenhum
instalador escreve em arquivos de outro provedor: setups que fariam isso (`engram setup
opencode`, `rtk init --opencode`) rodam com HOME temporário, e só o plugin é copiado.

Serena recebe **`--add-mode no-memories` em todos os sete clientes**. Engram é a
memória persistente escolhida; veja as etapas necessárias para exclusividade na seção 6.

## 2. Preparação

Prepare os pré-requisitos compartilhados e o Codex CLI antes de executar os
instaladores:

```bash
bash install-dependencies-ubuntu.sh
export PATH="$HOME/.local/bin:$PATH"
codex login
```

O script instala `curl`, `git`, `jq`, Python 3, `sha256sum`, `flock`, Node.js LTS,
`npm`, `npx` e Codex CLI. Execute como usuário normal; ele pede `sudo` apenas para
instalar pacotes do Ubuntu. As novas instalações de Node.js, npm e Codex ficam no
escopo do usuário, em `~/.local`. Um Codex já disponível no PATH é preservado.
Use `codex login` se ainda não estiver autenticado. O `install-claude` e o
`install-codex` exigem o CLI do próprio provedor; prepare os demais CLIs com `--clients`
abaixo.

Para preparar também os CLIs dos demais clientes, passe ao bootstrap a mesma lista
que usará nos instaladores:

```bash
bash install-dependencies-ubuntu.sh --clients all
export PATH="$HOME/.local/bin:$PATH"
```

Cada CLI selecionado é instalado via npm em `~/.local`, somente se ausente:
Claude Code (`@anthropic-ai/claude-code`), Codex (`@openai/codex`), Cline CLI
(`cline`), OpenCode 1 (`opencode-ai@1`) e Copilot CLI (`@github/copilot`). VS Code é
um editor e continua sendo instalado separadamente. O Codex é sempre incluído.
Autentique cada cliente depois (`codex login`, `claude`, `cline auth`, `copilot`).

Para também preparar OpenCode:

```bash
bash install-dependencies-ubuntu.sh --with-opencode
export PATH="$HOME/.local/bin:$PATH"
```

Essa opção instala OpenCode 1 (`opencode-ai@1`) se o comando estiver ausente,
conforme o [método npm oficial](https://opencode.ai/docs/). Uma instalação existente
de OpenCode 1 ou 2 é preservada e sua versão é conferida. Os demais clientes
continuam com instalação e autenticação próprias.

**`--clients all` significa todos os clientes.** No bootstrap, a lista escolhe quais CLIs
preparar; no `addons.json`, quais instaladores de provedor o `install-all` executa. Cada
instalador de provedor sempre configura todos os addons. O `install-opencode` detecta o
schema 1/2 com `opencode --version`; `bash install-dependencies-ubuntu.sh --clients all`
instala o OpenCode e o Claude Code, e o bootstrap informa pendências ao terminar.
Só use `--opencode-major 1|2` para preparar a configuração de uma versão conhecida;
essa opção não instala OpenCode e não deve ser escolhida por tentativa.

O script de preparação aceita somente `--help`, `--clients`, `--with-opencode`
(equivale a incluir `opencode` em `--clients`) e `--upgrade`. Com `--upgrade`, os CLIs
selecionados que o próprio bootstrap instalou em `~/.local` são atualizados; instalações
de outra origem são preservadas, e OpenCode só é atualizado dentro do major 1, nunca
rebaixado de 2. Ele não aceita `--dry-run`. A alteração do PATH dentro de um script não se propaga
ao terminal que o iniciou; por isso os exemplos incluem `export PATH=...`.

- Ubuntu Linux, Bash 4+, usuário normal, sem executar os scripts com `sudo`.
- x86_64 ou aarch64/arm64 para os instaladores de binários.
- Instale e autentique os clientes que pretende usar. `install-claude` e `install-codex`
  exigem o CLI do provedor no PATH. Os demais configuram sem CLI, mas o plugin Ponytail
  precisa de `opencode`, `copilot` ou `agy`; sem eles, o Ponytail fica só nas regras.
- Feche os agentes e editores durante a alteração. O bloqueio protege apenas contra
  outros instaladores deste pacote, não contra edições externas.
- Use versões atuais dos clientes. Claude/Codex precisam oferecer MCP e plugins.

| Script | Pré-requisitos básicos |
|---|---|
| Todos os instaladores de provedor | curl, sha256sum, Node.js, npm, Python 3, flock (ferramentas dos addons) |
| `install-claude`, `install-codex` | também o CLI do provedor, `git` e `jq` (plugins e setup do Engram) |

`flock` vem de `util-linux`; `sha256sum`, de `coreutils`. São necessários também os
utilitários básicos do Ubuntu (`install`, `tee`, `sed`, `mktemp`, entre outros).
Os instaladores de provedor relatam dependências ausentes; não alteram pacotes do sistema
nem instalam clientes. O bootstrap acima cuida dessa preparação separadamente.
Serena instala uv/uvx e Python 3.13 isolado como dependências.
Para TOML Codex com strings multilinha, a edição de memória requer Python 3.11+;
em Python anterior, esse formato é recusado.

O bootstrap inclui `~/.local/bin` no `~/.profile`. Confira se as sessões que iniciam
os clientes recebem esse PATH; se necessário, adicione a linha abaixo ao arquivo
adequado do shell:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Persista a linha no arquivo adequado do seu shell, sem duplicá-la. Node também
precisa estar no PATH dos processos de editor e hooks. Mesmo usando um caminho
absoluto para `context7-mcp` nos clientes, o processo precisa conseguir localizar Node.

## 3. Clientes, caminhos e opções

Opções dos instaladores de provedor (nenhuma se aplica a `install-dependencies-ubuntu.sh`):

| Opção | Instaladores | Efeito |
|---|---|---|
| `--help`, `--dry-run` | todos | Ajuda; plano sem rede, arquivos, logs ou alterações. |
| `--config ARQUIVO` | todos | `addons.json` com as opções dos addons. Padrão: `addons.json` ao lado do script, se existir; sem ele, os padrões de cada addon. |
| `--surfaces cli,vscode` | copilot | `cli` (Copilot CLI), `vscode` (Copilot no VS Code) ou as duas (padrão). |
| `--vscode-user-dir DIR` | copilot | Pasta User do perfil VS Code. |
| `--cline-config ARQUIVO` | cline | Arquivo MCP do Cline CLI ou da extensão. |
| `--opencode-major 1\|2` | opencode | Schema MCP instalado; sem ela, detecta por `opencode --version`. |
| `--project-dir DIR` | cline, opencode, copilot, antigravity | Projeto fixo do Serena (no Copilot, só no VS Code). |

As flags prevalecem sobre `options` do `addons.json` (seção 4.1). `--dry-run` não acessa
a rede, não cria logs/arquivos e não instala nada. Ele mostra o plano, não confirma que
as dependências ou configurações da máquina são válidas.

| Cliente | Destino padrão e comportamento |
|---|---|
| Claude | Configuração de usuário via CLI; respeita `CLAUDE_CONFIG_DIR`. |
| Codex | Configuração de usuário via CLI; respeita `CODEX_HOME`. |
| Cline | **Padrão da CLI:** `~/.cline/data/settings/cline_mcp_settings.json`. Também aceita `CLINE_MCP_SETTINGS_PATH`. |
| OpenCode | `${XDG_CONFIG_HOME:-~/.config}/opencode/opencode.json` ou `.jsonc`, se já existir; plugins em `opencode/plugins/` e no `plugin` do config. |
| Copilot CLI | `${COPILOT_HOME:-~/.copilot}/mcp-config.json`, chave `mcpServers`; hook RTK em `hooks/rtk-rewrite.json`; plugin Ponytail via `copilot plugin`. |
| Copilot VS Code | `${XDG_CONFIG_HOME:-~/.config}/Code/User/mcp.json`, chave `servers`. |
| Antigravity | `~/.gemini/config/mcp_config.json` (chave `mcpServers`), regras globais em `~/.gemini/GEMINI.md` e plugin RTK em `~/.gemini/config/plugins/rtk/`. |

### Cline na extensão

No Cline, abra **MCP Servers → Configure → Configure MCP Servers** e confira o
caminho do arquivo usado pela extensão. Passe esse caminho em `--cline-config` do
`install-cline-ubuntu.sh` (ou em `options.cline-config` do `addons.json`). Configurar o
caminho padrão da CLI não configura a extensão automaticamente. As regras globais são
gravadas em `~/.cline/rules/`.

### OpenCode

O script detecta o major com `opencode --version`; use `--opencode-major 1` ou `2`
quando necessário. A escolha precisa corresponder à versão instalada:

- V1: servidores em `mcp.NOME`, ativados com `enabled: true`.
- V2: servidores em `mcp.servers.NOME`, ativados com `disabled: false`.

Se existirem ambos `opencode.json` e `opencode.jsonc`, o script solicita consolidação.
Um schema MCP da outra versão é recusado. Overrides `OPENCODE_CONFIG`,
`OPENCODE_CONFIG_CONTENT` e `OPENCODE_CONFIG_DIR` são recusados para evitar alterar
um arquivo que não seria o efetivo. Configurações de projeto ainda podem ter
precedência; confira-as antes de usar os MCPs. Regras ficam no `AGENTS.md` global.

Além dos MCPs, o `install-opencode` instala os plugins nativos em
`${XDG_CONFIG_HOME:-~/.config}/opencode/plugins/`: `engram.ts`, gerado por `engram setup
opencode`, e `rtk.ts`, gerado por `rtk init --global --opencode`. Os dois setups rodam com
HOME temporário, porque reescreveriam o `opencode.json` (perdendo comentários e o schema
V2) ou gravariam arquivos do Claude. A statusline de sub-agentes do Engram vai para
`tui.json` só se o arquivo ainda não existir; se existir, o instalador apenas avisa. O
Ponytail entra por `opencode plugin @dietrichgebert/ponytail --global`, que acrescenta
`"plugin"` ao config e cria `package.json`/`node_modules` na pasta do OpenCode; com o
plugin, o bloco Ponytail sai do `AGENTS.md`.

### OpenCode Desktop com addons na VM OrbStack

O fluxo Ubuntu acima permanece inalterado. Para o OpenCode Desktop no macOS usando os
binários instalados por este repositório na `***removed***` ou `***removed***`, o adaptador
[`opencode-desktop/ai-tooling-vm`](opencode-desktop/ai-tooling-vm) escolhe a VM e o
diretório pelo `PWD`. Fora dos volumes compartilhados, os MCPs usam `/home/***removed***` na
`***removed***`; o RTK exige um projeto dentro de um dos volumes.

Instale o adaptador no host, a partir deste repositório montado pelo OrbStack:

```bash
install -d ~/.config/opencode/bin
install -m 0755 opencode-desktop/ai-tooling-vm ~/.config/opencode/bin/ai-tooling-vm
```

Mescle somente estas entradas em `~/.config/opencode/opencode.jsonc`, trocando
`/Users/SEU_USUARIO` pelo caminho absoluto do seu home. Não substitua o arquivo nem
remova `model`, `provider`, `plugin`, outros MCPs ou demais configurações:

```jsonc
"mcp": {
  "serena": {
    "type": "local",
    "command": ["/Users/SEU_USUARIO/.config/opencode/bin/ai-tooling-vm", "serena"],
    "enabled": true,
    "timeout": 60000
  },
  "context7": {
    "type": "local",
    "command": ["/Users/SEU_USUARIO/.config/opencode/bin/ai-tooling-vm", "context7"],
    "enabled": true,
    "timeout": 60000
  },
  "engram": {
    "type": "local",
    "command": ["/Users/SEU_USUARIO/.config/opencode/bin/ai-tooling-vm", "engram", "mcp", "--tools=agent"],
    "enabled": true,
    "timeout": 60000
  }
}
```

OpenRouter continua sendo apenas o provedor. Modelos como
`openrouter/moonshotai/kimi-k3.1-pro` usam a mesma integração, sem configuração
específica por modelo. O adaptador não adiciona nem remove plugins: RTK e Ponytail
continuam por regras/skills, e ccusage continua sendo uma CLI. RTK e relatórios ccusage
podem ser chamados pelo mesmo adaptador:

```bash
~/.config/opencode/bin/ai-tooling-vm rtk git status
~/.config/opencode/bin/ai-tooling-vm ccusage opencode daily
```

Reinicie o OpenCode depois de editar `opencode.jsonc`. A variável `ORB_BIN` só existe
para testes ou uma instalação não padrão do `orb`; o padrão é `/usr/local/bin/orb`.

### VS Code, perfis, SSH e WSL

O padrão atende ao VS Code Stable no Ubuntu. Use `--vscode-user-dir` do `install-copilot` para Insiders
ou outro perfil, indicando a pasta efetiva com `settings.json`, `mcp.json` e `prompts/`.
As instruções são `prompts/six-addons-ADDON.instructions.md`, com `applyTo: "**"`.

Em SSH/WSL/containers, execute no Ubuntu onde os servidores devem rodar e selecione
os arquivos do mesmo ambiente. Não use caminhos do Windows/macOS no Bash Ubuntu.
Este pacote não instala servidores remotos nem detecta perfis/ambientes automaticamente.

### Serena em projetos Go

O servidor MCP do Serena precisa também do compilador e do analisador da linguagem.
Para Go, prepare Go e `gopls` e teste uma leitura real de símbolos, com estas chaves no
`addons.json`, e rode o instalador do provedor (por exemplo, `bash install-codex-ubuntu.sh`):

```json
{ "addons": { "serena": { "with-go": true, "check-go-project": "/caminho/absoluto/do/projeto-go" } } }
```

`with-go` preserva Go e `gopls` já disponíveis no PATH. Quando ausentes, instala
Go estável oficial para amd64/arm64 com SHA-256 verificado e `gopls` via `go install`.
Os binários ficam no escopo do usuário; a compilação de `gopls` usa dois processadores
e um pacote por vez para reduzir o consumo de memória. A versão Go exigida pelo
projeto continua definida no `go.mod`; uma instalação existente antiga pode precisar
de atualização. Dependências do módulo podem ser baixadas durante o teste.

`check-go-project` exige `go.mod` na raiz, inicia uma conexão MCP temporária e
confirma símbolos do primeiro arquivo Go encontrado, com limite de 180 segundos.
O diagnóstico usa a interface `tools`, mesmo quando a configuração global usa REPL,
e aceita as respostas dos SDKs MCP v1 e v2. Não altera o projeto ativo do chat.
Serena pode criar sua configuração `.serena`
quando o projeto ainda não está preparado. O teste usa as dependências Go já instaladas;
sem `with-go`, não instala Go/gopls. Essas duas opções só valem para o Serena, e o
`--dry-run` mostra a de Go.

Outras linguagens continuam exigindo seus próprios compiladores/analisadores;
este pacote não instala todos os servidores de linguagem. Após corrigir dependências,
reabra o cliente para reconectar um MCP que tenha encerrado com `Transport closed`.

Cada instalador de provedor registra os gatilhos de uso do Serena e do Context7 no arquivo
de regras do provedor (`CLAUDE.md` do Claude, `AGENTS.md` global do Codex e os arquivos de
regras dos demais), em blocos gerenciados, preservando instruções existentes e sem
duplicação na reexecução. Engram, Ponytail e RTK mantêm suas integrações oficiais. Addons são
usados conforme a tarefa; `ccusage` gera relatórios sob demanda. Visualize é um plugin
adicional do Codex e não integra o conjunto de addons deste repositório.

### Graphify e o pre-flight do grafo

O Graphify (`graphifyy`, via `uv`) monta um grafo do código do repositório em
`graphify-out/graph.json`, por AST local, sem LLM e sem tokens. Cada instalador de provedor
copia a skill oficial do Graphify para o cliente (gerada com `graphify install --platform`
em HOME temporário, porque no Claude ela editaria o `CLAUDE.md` fora dos blocos
gerenciados) e grava uma regra de uso. No OpenCode entra também o plugin `graphify.js`,
que lembra o agente de consultar o grafo. Cline e Copilot no VS Code recebem só a regra.

A regra manda o agente rodar `graphify-preflight ensure` (instalado em `~/.local/bin`)
antes de varrer um repositório Git. O pre-flight resolve, sem chamar o modelo, se o grafo
é confiável:

- grava em `graph.json` um cabeçalho `_meta` com `git_commit`, `git_tree_hash`,
  `worktree_hash` (árvore de trabalho, incluindo arquivos novos não ignorados),
  `dirty` e `generated_at`;
- caminho O(1): mesmo commit, árvore limpa agora e na geração → "atualizado", sem hashing;
- com alterações locais, compara o hash da árvore de trabalho com o da geração; um commit
  que só registra o que o grafo já viu continua "atualizado";
- grafo ausente, sem `_meta` ou desatualizado → `ensure` gera (`graphify extract --code-only`)
  ou atualiza (`graphify update --force`) e regrava o `_meta`.

```bash
graphify-preflight check   # 0 atualizado, 1 desatualizado, 2 sem grafo, 3 fora de repositório Git
graphify-preflight ensure  # padrão: check e, se preciso, build
graphify query "onde o lock é tomado?"
```

`graphify-out/` vai para `.git/info/exclude` do repositório (não altera o `.gitignore` e
não suja o `git status`). Documentos, PDFs e imagens ficam fora do grafo automático; para
incluí-los, use `/graphify` no agente, que usa o modelo do próprio cliente.

### Projeto do Serena

Claude, Codex, Copilot CLI, OpenCode e Antigravity usam `--project-from-cwd`. Inicie esses clientes
na pasta do projeto. Ao criar `.serena/project.yml`, o Serena liga só a linguagem principal; em
projetos com mais de uma (ex.: Go e TypeScript), inclua as demais em `language_servers` e reabra o
cliente, porque o arquivo só é lido quando o MCP inicia. Para Cline e VS Code, o padrão deixa a ativação para a sessão:
peça ao Serena para ativar o caminho absoluto do projeto atual.

`--project-dir` (ou `options.project-dir`) fixa um projeto para **Cline/OpenCode/VS Code/Antigravity**, na configuração global.
Use apenas quando isso for intencional; não alterna automaticamente ao mudar de
workspace. Alterar o projeto em uma reexecução atualiza a entrada que este pacote
registrou (seção 4.3). Essa opção não muda o diretório de instalação, nem
configura o projeto do Engram ou dos três clientes CLI.

## 4. Ordem de execução

Entre na pasta da sua cópia do repositório (por exemplo, `~/addons`) e consulte
as opções antes de instalar:

```bash
bash install-codex-ubuntu.sh --help
bash install-codex-ubuntu.sh --dry-run
```

Cada instalador de provedor, nesta ordem:
1. confere o sistema e os comandos exigidos;
2. faz backup das configurações do provedor;
3. confere todos os MCPs (um conflito interrompe tudo antes de qualquer download);
4. instala ou atualiza as ferramentas;
5. configura os addons na ordem Engram (memória primeiro), Serena, Context7, RTK e Ponytail.

Para todos os addons **somente no Codex**, após a preparação da seção 2:

```bash
bash install-codex-ubuntu.sh
```

Para **todos os clientes**, prepare os CLIs com `bash install-dependencies-ubuntu.sh --clients all`
e use o orquestrador (seção 4.1), ou rode os instaladores um por vez. A sequência abaixo
usa o **Cline CLI e o perfil padrão VS Code**; ajuste os destinos conforme a seção 3. Os
aplicativos e suas contas precisam estar configurados para usar as integrações:

```bash
bash install-claude-ubuntu.sh &&
bash install-codex-ubuntu.sh &&
bash install-cline-ubuntu.sh &&
bash install-opencode-ubuntu.sh &&
bash install-copilot-ubuntu.sh &&
bash install-antigravity-ubuntu.sh
```

`&&` interrompe a sequência se algum script falhar. Não rode em paralelo. Cada instalador
baixa as ferramentas de novo, mesmo que outro já as tenha instalado na mesma sequência.
O setup oficial do Engram pode solicitar confirmação para adicionar ferramentas à lista
de permissões do Claude; responda no terminal. Aguarde a mensagem `Concluido:` de cada
instalador antes de considerá-lo finalizado. Para a extensão do Cline e o OpenCode 2, por
exemplo:

```bash
bash install-cline-ubuntu.sh --cline-config /caminho/real/da/extensao/cline_mcp_settings.json
bash install-opencode-ubuntu.sh --opencode-major 2
```

Substitua o caminho de exemplo. O ccusage é instalado pelo `install-claude`: ele lê os
dados do Claude Code e não altera configurações dos clientes.

### 4.1 Orquestrador e `addons.json`

`install-all-ubuntu.sh` executa, nesta ordem e um por vez: o bootstrap
(`install-dependencies-ubuntu.sh`) e os instaladores dos provedores de `clients`, na ordem
Claude, Codex, Cline, OpenCode, Copilot e Antigravity. `copilot` e `vscode` viram um único
`install-copilot-ubuntu.sh --surfaces`. Todos recebem o mesmo arquivo em `--config`:
`addons.json`, ao lado do script, ou outro:

```bash
bash install-all-ubuntu.sh --config /caminho/absoluto/meus-addons.json
```

Antes de alterar qualquer coisa, o orquestrador valida o JSON e executa cada instalador
com `--dry-run`. Se alguma opção for recusada, nada é instalado. Com `--dry-run`, o
orquestrador para depois dessa conferência e mostra o plano de cada provedor; o
bootstrap só é exibido, pois não tem simulação. Na instalação, a primeira falha
interrompe a sequência; corrija a causa e reexecute, pois as etapas já concluídas
podem ser repetidas. O orquestrador exige Bash 4.4+, `python3` para ler o JSON e a
pasta `lib/` ao lado.

O [addons.json](addons.json) incluído instala todos os addons em todos os clientes,
com Ponytail em `ultra`. Ele lista todas as opções disponíveis; nas opções, `null`,
`false`, `[]` e `{}` significam "usar o padrão do addon". O [addons.exemple.json](addons.exemple.json)
preenche todas as opções com valores de exemplo; copie-o e ajuste:

```bash
cp addons.exemple.json meus-addons.json
bash install-all-ubuntu.sh --config "$PWD/meus-addons.json" --dry-run
```

| Chave | Efeito |
|---|---|
| `clients` | Texto (`"all"`, `"claude,codex"`) ou lista (`["codex"]`). Escolhe quais instaladores de provedor rodam (`copilot`/`vscode` → superfícies do `install-copilot`) e vai para o bootstrap. Sem ela: `claude,codex`, e o bootstrap usa o padrão dele. |
| `options` | Opções de caminho dos provedores: `cline-config`, `vscode-user-dir`, `opencode-major` e `project-dir`. As flags dos instaladores prevalecem. |
| `bootstrap` | `enabled`, `clients`, `upgrade` e `with-opencode`. `false` pula a preparação. |
| `addons.NOME` | As opções do addon (seção 4.3; por exemplo, `mode` do Ponytail, `with-go` e `check-go-project` do Serena). Todos os addons são sempre instalados: `"NOME": false`, `"enabled": false` e `clients` dentro do addon são recusados; `"enabled": true` é aceito. Um addon ausente usa os padrões. |

Cada instalador lê o JSON diretamente (`lib/config.sh`). Listas viram texto separado por
vírgulas (`["planning", "editing"]` → modos `planning,editing`), objetos viram JSON
(`settings` do ccusage) e booleanos viram `true`/`false`; `null` significa "usar o padrão".
Uma opção de caminho dentro de um addon (ex.: `addons.serena.project-dir`) prevalece sobre
a mesma opção em `options`. Caminhos podem começar com `~/`, que é expandido para o
diretório do usuário. Chaves duplicadas, chaves desconhecidas e valores de outros tipos
são recusados antes de qualquer execução; os valores de cada opção são conferidos pelo
`--dry-run` de cada instalador. Exemplo só para o Codex, com Go no Serena e Ponytail em
`full`:

```json
{
  "clients": "codex",
  "addons": {
    "serena": { "with-go": true, "check-go-project": "~/projetos/api" },
    "ponytail": { "mode": "full" }
  }
}
```

### 4.2 Nível do Ponytail

`addons.ponytail.mode` (`lite`, `full` ou `ultra`) define o nível padrão; sem a chave,
usa **`ultra`**, que acrescenta às regras: questionar o pedido antes de construir e
recusar o que a necessidade não justifica. Nos provedores com plugin de hooks (Claude,
Codex e Copilot CLI), o instalador grava `defaultMode` em
`${XDG_CONFIG_HOME:-~/.config}/ponytail/config.json`, preservando as outras chaves e
fazendo backup. Esse arquivo é lido pelos hooks oficiais no início de cada sessão, e
`/ponytail lite|full|ultra` (no Copilot CLI, `/ponytail:ponytail`) troca o nível durante a
sessão. No OpenCode, o plugin injeta as regras a cada turno no nível ativo e também
oferece `/ponytail`. `PONYTAIL_DEFAULT_MODE` no ambiente tem prioridade sobre o arquivo;
o instalador avisa quando ela tem outro valor. Nos clientes só com regras (Cline, VS Code,
Antigravity, e OpenCode/Copilot CLI sem o comando do cliente), o nível é incorporado ao
bloco gerenciado; para mudá-lo, ajuste `mode` e reexecute.

### 4.3 Opções de cada addon

Levantadas nos repositórios oficiais em 15/10/2026 (seção 10). São chaves em
`addons.NOME` do `addons.json`, lidas por todos os instaladores de provedor. Sem a
chave, vale o padrão do addon e a configuração existente é preservada.

| Addon | Opção | Valores | Efeito |
|---|---|---|---|
| Ponytail | `mode` | `lite`, `full`, `ultra` (padrão) | Nível padrão (seção 4.2). |
| Ponytail | `quiet-startup` | `true`/`false` | `quietStartup` do `config.json`: oculta o aviso de início. |
| Ponytail | `hide-status` | `true`/`false` | `hideStatus` do `config.json`: oculta o selo de nível. |
| Engram | `tools` | `agent` (padrão), `admin`, `all` ou lista | Perfil de ferramentas do MCP (`engram mcp --tools=`). `admin` traz exclusão, estatísticas, linha do tempo e mesclagem. |
| Serena | `with-go`, `check-go-project` | `true`/`false` / caminho | Go e `gopls`; teste real de símbolos (seção 3). |
| Serena | `language-backend` | `LSP`, `JetBrains` | Backend de análise de código. `JetBrains` exige o plugin do Serena na IDE. |
| Serena | `agent-interface` | `tools`, `REPL` | Uma ferramenta por operação, ou execução de Python pela ferramenta `serena_repl`. |
| Serena | `enable-web-dashboard` | `true`/`false` | Dashboard web do Serena. |
| Serena | `open-web-dashboard` | `true`/`false` | Abrir o dashboard no navegador a cada início do MCP. |
| Serena | `log-level` | `DEBUG` … `CRITICAL` | Nível de log. |
| Serena | `tool-timeout` | segundos | Tempo limite das ferramentas. |
| Serena | `modes` | lista (ex.: `planning`, `editing`, `interactive`, `one-shot`, `no-onboarding`) | Modos adicionais (`--add-mode`); `no-memories` é sempre aplicado. `interactive` e `editing` já são modos base do Serena; `planning` manda não escrever código. |
| Serena | `ls-dependencies` | lista (ex.: `python`, `typescript`, `go`) | Pré-baixa language servers com `serena download-ls-dependencies`. |
| Context7 | `api-key-from-env` | `true`/`false` | Grava a chave de `CONTEXT7_API_KEY` como `--api-key` do MCP em cada cliente. |
| RTK | `init-mode` | `default`, `hook-only` | Claude: hook + `RTK.md`, ou somente o hook. O Codex sempre recebe hook + `AGENTS.md`/`RTK.md`, pois `rtk init --codex` recusa `--hook-only`. |
| RTK | `trust-filters` | `true`/`false` | Confiar nos filtros personalizados detectados (`--trust-filters`/`--no-trust-filters`). |
| RTK | `telemetry` | `enable`, `disable` | Consentimento de telemetria (`rtk telemetry`). |
| RTK | `recall` | `sqlite`, `tee`, `disabled` | Recuperação da saída completa (`rtk config recall`). |
| RTK | `awareness` | `default`, `high`, `full` | Quanto as instruções do `init` contam ao agente sobre o RTK. No Claude só vale com `init-mode` `default`: `hook-only` não grava instruções. |
| RTK | `exclude-commands` | lista | Comandos nunca reescritos (`hooks.exclude_commands`). |
| RTK | `tracking`, `history-days` | `true`/`false`; inteiro | Registro local de economia de tokens e dias de histórico. |
| ccusage | `settings` | objeto | Conteúdo no formato do `ccusage.json` oficial (`defaults`, `commands` e seções por agente), mesclado em `~/.config/claude/ccusage.json` (ou no primeiro diretório de `CLAUDE_CONFIG_DIR`). |
| Graphify | — | — | Sem opções; `addons.graphify` aceita só `true`/`{"enabled": true}`. |

Detalhes:

- **Ponytail, RTK e ccusage** editam somente as chaves pedidas nos arquivos oficiais
  (`~/.config/ponytail/config.json`, `${XDG_CONFIG_HOME:-~/.config}/rtk/config.toml` e
  `ccusage.json`), com backup. O RTK aplica telemetria, `recall` e `config.toml` antes do
  `rtk init`, porque `awareness` muda as instruções gravadas por ele. Uma tabela TOML
  duplicada, chave fora de tabela ou lista em várias linhas é recusada sem alteração.
- **Serena e Engram** acrescentam as opções aos argumentos do MCP em todos os
  provedores. **Context7** faz o mesmo com a chave. Uma entrada que já usa o binário
  instalado por este pacote (`~/.local/bin/...`) é atualizada com os novos argumentos;
  qualquer outra entrada com o mesmo nome continua recusada como conflito. Por isso,
  reexecutar **sem** uma opção também a remove: por exemplo, rodar sem
  `api-key-from-env` registra o Context7 sem chave.
- **Chave do Context7:** a chave nunca vai no JSON. Exporte-a antes
  (`export CONTEXT7_API_KEY=...`); ela fica gravada nas configurações MCP dos clientes
  e pode aparecer no log privado do instalador, pois os CLIs ecoam o comando registrado.
- **Fora do escopo do instalador:** opções que só existem como variável de ambiente do
  processo do agente, como `PONYTAIL_SUBAGENT_MATCHER`, `PONYTAIL_MAP`,
  `PONYTAIL_MAP_CHARS`, `ENGRAM_DATA_DIR`, `ENGRAM_PORT` e `RTK_TELEMETRY_DISABLED`, e
  opções de uso pontual (`engram mcp --project`, transportes HTTP do Serena/Context7,
  comandos de relatório do ccusage). Defina-as no ambiente que inicia os agentes, se
  precisar.

### 4.4 Migração dos instaladores por addon

Os seis `install-<addon>-ubuntu.sh` foram substituídos pelos instaladores de provedor, que
sempre configuram todos os addons. Não há mais instalação de um addon isolado.

| Antes | Agora |
|---|---|
| `bash install-<addon>-ubuntu.sh --clients claude`, um por addon | `bash install-claude-ubuntu.sh` |
| `… --clients codex` | `bash install-codex-ubuntu.sh` |
| `… --clients cline --cline-config F` | `bash install-cline-ubuntu.sh --cline-config F` |
| `… --clients opencode --opencode-major N` | `bash install-opencode-ubuntu.sh --opencode-major N` |
| `… --clients copilot,vscode --vscode-user-dir D` | `bash install-copilot-ubuntu.sh --surfaces cli,vscode --vscode-user-dir D` |
| `… --clients antigravity` | `bash install-antigravity-ubuntu.sh` |
| `--project-dir P` | o mesmo, nos instaladores de Cline, OpenCode, Copilot e Antigravity |
| opções por addon (`--tools`, `--mode`, `--with-go`, …) | chaves em `addons.<addon>` do `addons.json` (seção 4.3), passado com `--config` |
| `install-ccusage-ubuntu.sh` | `install-claude-ubuntu.sh`, porque o ccusage lê os dados do Claude Code |
| `addons.<addon>: false` ou `clients` por addon | recusados: todos os addons são instalados |

Rodar os instaladores novos sobre uma instalação feita pelos scripts antigos reaproveita as
mesmas entradas MCP e os mesmos blocos de regras. Onde o provedor ganhou plugin ou hook
nativo (seção 1), o bloco de regras antigo correspondente é removido.

### 4.5 Estrutura e novos provedores

- `lib/common.sh`: preâmbulo (checagens, bloqueio, backup, log) e blocos de regras gerenciados.
- `lib/config.sh`: leitura e validação do `addons.json`.
- `lib/addons.sh`: opções dos addons, argumentos MCP e textos das regras.
- `lib/tools.sh`: instalação das ferramentas (Engram, uv + Serena, Graphify, context7-mcp, RTK, ccusage).
- `bin/graphify-preflight`: pre-flight do grafo, instalado em `~/.local/bin`.
- `lib/json-mcp.sh`: editor de MCP em JSON/JSONC.
- `install-<provedor>-ubuntu.sh`: tudo o que é específico do provedor.

Para um provedor novo (por exemplo, Kimi ou Gemini CLI):
1. Crie `install-<provedor>-ubuntu.sh` a partir de um dos existentes e carregue a `lib/`.
2. Mantenha o fluxo da seção 4: conferir todos os MCPs antes de `tools_install` e nunca
   escrever em arquivos de outro provedor.
3. Acrescente o provedor ao `install-all-ubuntu.sh` e à lista de clientes em `lib/config.sh`.
4. Escreva `tests/test_install_<provedor>.py` com base em `tests/provider_harness.py`.

Uma nova superfície do mesmo provedor, como o Claude Desktop, entra como `--surfaces` no
instalador dele, como no Copilot.

## 5. OpenRouter

OpenRouter é o provedor de modelos. Os MCPs e as regras são carregados pelo cliente,
portanto use `install-cline-ubuntu.sh` e `install-opencode-ubuntu.sh` (ou `clients` com
`cline`/`opencode`), por exemplo. `openrouter` em `clients` é recusado com orientação,
pois não há configuração local de MCP do provedor.

1. No Cline, selecione **OpenRouter** nas configurações de provedor e cadastre sua chave
   no próprio cliente. Veja o [guia oficial](https://openrouter.ai/works-with-openrouter/cline).
2. No OpenCode, conecte OpenRouter pela interface de provedores da versão instalada e
   escolha um modelo disponibilizado pelo provedor. Consulte [provedores V2](https://dev.opencode.ai/v2/docs/providers/)
   ou [provedores V1](https://opencode.ai/docs/providers/).
3. Escolha um modelo com suporte às ferramentas exigidas pelo cliente e confira a
   disponibilidade dos MCPs na sessão. Consulte [tool calling](https://openrouter.ai/docs/guides/features/tool-calling).

Os scripts preservam modelos, provedores e credenciais existentes. Não recebem,
gravam ou imprimem uma chave OpenRouter. Não reconfiguram Claude/Codex/Copilot para
usar OpenRouter. O uso dos addons nesses clientes segue o provedor já configurado.
O custo cobrado pelo OpenRouter deve ser conferido no painel do provedor; um relatório
local do ccusage não equivale à fatura e não cobre automaticamente todos os clientes.

## 6. Memória: Engram exclusivo

Para o Engram, os instaladores de provedor:

- Desativam `autoMemoryEnabled` no Claude (`install-claude`).
- Desativam `features.memories`, `memories.use_memories` e
  `memories.generate_memories` no Codex (`install-codex`).
- No VS Code (`install-copilot`, superfície `vscode`), desativam
  `github.copilot.chat.tools.memory.enabled` e `github.copilot.chat.copilotMemory.enabled`
  no `settings.json` de usuário escolhido.
- Em Cline, OpenCode, Copilot e Antigravity, adicionam instruções para usar exclusivamente
  o Engram e evitar Memory Banks ou notas de memória nos arquivos de instruções. No
  OpenCode, o plugin `engram.ts` cuida também da sessão e da recuperação após compactação.
- Registram o mesmo binário Engram, com `mcp --tools=` conforme `addons.engram.tools`
  (padrão `agent`); no mesmo usuário e sem overrides distintos, os processos compartilham
  a base padrão em `~/.engram`.

**Etapa manual obrigatória para Copilot CLI e VS Code:** desative Copilot Memory nas
configurações da sua conta GitHub, conforme o [guia oficial](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/copilot-memory/manage-for-yourself).
Um instalador local não modifica esse controle da conta. Se houver controle da
organização, confira a política aplicável. Os scripts imprimem essa pendência.

Confira também regras antigas de Cline/Memory Bank, outros plugins de memória,
configurações do workspace, perfis e variáveis `ENGRAM_DATA_DIR` dos clientes.
Overrides diferentes podem criar bases distintas ou reativar memória nativa.
Os scripts não apagam memórias existentes nem desinstalam ferramentas anteriores.
A exclusividade depende de resolver esses conflitos e desativar a memória da conta.
Históricos de conversa, logs e retomada de sessão dos clientes não são removidos.

Ao terminar, cada instalador confere os ajustes de memória nativa do seu provedor: Claude
e Codex após o setup oficial, e VS Code após editar `settings.json`.
Essa conferência local não valida as configurações da conta GitHub nem overrides
de workspace ou perfil.

Serena é registrado sem memórias (`--add-mode no-memories`) por todos os instaladores. A verificação automática
confirma o argumento no registro; após iniciar o servidor, confira se as ferramentas
de memória e onboarding excluídas pelo modo estão ausentes.

## 7. Conferência depois da instalação

Os scripts verificam versões/ajuda dos executáveis instalados, registros MCP,
plugins nativos selecionados e arquivos de regras/configuração gravados. Não abrem
uma conversa nem confirmam uma chamada real ao modelo ou o handshake de todo MCP.

Reinicie os clientes e faça a conferência no ambiente Ubuntu:

Abra cada cliente na raiz do projeto em que vai trabalhar. Iniciar em `~/` quando
há vários repositórios pode deixar a detecção do Engram ambígua, impedir o registro
da sessão e preencher o mapa do Ponytail com arquivos de outros projetos. Ativar
um projeto apenas no Serena não corrige o diretório inicial do cliente nem registra
a identidade do Engram; nesse caso, abra uma nova sessão na pasta correta.

Depois de atualizar o Engram, o instalador consulta `/health`, quando disponível,
e avisa se o servidor ainda executa uma versão anterior à instalada. Ele não encerra
processos ativos. Ao receber esse aviso, encerre as sessões e reinicie o serviço e
os clientes para carregar o binário atualizado.

1. Revise a confiança dos MCPs e, no Codex, dos hooks em `/hooks`; abra uma nova sessão.
2. Nos clientes configurados, confira os servidores `engram`, `serena` e `context7`.
   Claude/Codex/OpenCode/Copilot CLI oferecem listagem de MCP; nos editores use o painel
   MCP. No VS Code, confirme que as instruções de usuário estão sendo carregadas.
   No Claude, o `install-claude` garante `env.MCP_TIMEOUT` de
   pelo menos `60000` milissegundos no `settings.json` de `CLAUDE_CONFIG_DIR`
   (padrão: `~/.claude`), para acomodar a partida a frio do Node/`uv`.
   Um valor maior já definido é mantido.
3. Ative o projeto correto no Serena, confira a ausência das ferramentas de memória
   e peça uma leitura de símbolos de um arquivo. Para Go, use também o teste acima;
   um registro MCP válido pode coexistir com falha do servidor de linguagem.
4. Peça ao agente para recuperar contexto com Engram. Nos clientes com setup nativo,
   siga o ciclo de sessão e a identidade fornecidos pela integração; no Codex, os hooks
   registram a sessão e o agente não deve chamar `mem_session_start` nem inventar IDs.
   Nos clientes com MCP + instruções (Cline, Copilot e Antigravity), abra a sessão com o diretório real e use
   a identidade retornada, conforme o protocolo instalado. Veja o
   [setup oficial do Engram](https://github.com/Gentleman-Programming/engram/blob/main/docs/AGENT-SETUP.md).
   Para validar persistência, salve uma informação de teste sem dados privados e
   recupere-a em outra sessão/cliente. Exclua o registro de teste depois.
5. Confira uma consulta de documentação com Context7. No RTK por regras, observe se o
   agente realmente usa `rtk` nos comandos compatíveis. Confirme as regras Ponytail e o nível ativo: em Claude, Codex e OpenCode, `/ponytail` sem argumento mostra o nível atual (no Copilot CLI, `/ponytail:ponytail`).

Relatórios ccusage, conforme fontes documentadas e versão instalada:

```bash
ccusage --help
ccusage claude daily
ccusage codex daily
ccusage opencode daily
ccusage copilot daily
```

A ausência de dados antes de usar um cliente é normal. Se uma versão publicada ainda
não expuser uma fonte anunciada no repositório, consulte a ajuda instalada e atualize
quando houver release compatível. Não há promessa de leitura de Cline ou da extensão
Copilot VS Code. Não instalamos outro addon para complementar essa cobertura.

## 8. Segurança, repetição, versões e erros

- Instalações de usuário: binários em `~/.local/bin`, ccusage via npm global com
  prefixo `~/.local`; Serena em ambiente de ferramenta do uv. Nada é instalado por
  projeto, mesmo que `--project-dir` seja informado.
- RTK, Engram e uv: release estável mais recente do repositório oficial, com digest
  SHA-256 informado pela API GitHub; ausência/incompatibilidade do digest interrompe.
  Isso verifica integridade, não é auditoria ou assinatura independente do fornecedor.
- Os instaladores de RTK, Engram e uv extraem seletivamente os binários dos arquivos
  compactados. O bootstrap extrai a distribuição completa do Node.js em `~/.local/lib/nodejs`.
  Não há `curl | bash`. Pacotes e plugins oficiais instalados continuam sendo código
  de terceiros executado com as permissões do usuário.
- O bootstrap usa a versão LTS do Node.js publicada em nodejs.org, validando o SHA-256
  publicado para o arquivo baixado. Instala Codex CLI com `@latest` via npm somente
  se ausente; com `--clients`, instala também os CLIs selecionados (`@latest`, ou
  `opencode-ai@1`) somente se ausentes.
  Reexecutar o bootstrap pode atualizar o Node LTS, mas preserva os clientes existentes,
  exceto com `--upgrade`.
- As consultas à API do GitHub são anônimas por padrão (limite de 60 por hora por IP).
  Em redes compartilhadas, exporte `GITHUB_TOKEN` antes de executar: o token vai só para
  `api.github.com`, por um arquivo temporário privado, e não aparece na linha de comando.
- Serena usa `uv tool install --upgrade -p 3.13 serena-agent`; ccusage usa `@latest`
  com validação de requisitos de Node pelo npm. Context7 instala `@upstash/context7-mcp@latest`
  em `~/.local` e registra `~/.local/bin/context7-mcp`; a versão só muda ao reexecutar o
  instalador. Ele migra automaticamente a entrada antiga com comando `npx` e argumentos
  `-y --registry=https://registry.npmjs.org @upstash/context7-mcp`; nos quatro clientes
  novos, o comando antigo precisa corresponder ao caminho absoluto de `npx` no PATH.
  Uma entrada diferente continua recusada como conflito. Plugins nativos usam os
  marketplaces oficiais.
- As regras Ponytail dos clientes sem plugin são um snapshot incorporado de `AGENTS.md`, commit
  `9b58c1ffb790c075ca32e70a89cf1d80588f4abf`. Consulte a licença no repositório oficial
  do Ponytail listado na seção 10; não há `PONYTAIL-LICENSE.txt` nesta cópia.
  Regras RTK são geradas pelo binário instalado. O protocolo Engram desses clientes é
  uma adaptação resumida incluída em `lib/addons.sh`.
- Reexecutar pode atualizar binários/pacotes/plugins. Configurações iguais e blocos
  gerenciados não são duplicados. **Não é uma instalação reproduzível com lockfile**.
- Os editores JSON/JSONC preservam comentários e outras entradas; rejeitam chaves
  duplicadas, formato inválido, schema conflitante e servidores diferentes com o
  mesmo nome. TOML é editado de modo conservador. Só entradas MCP que já usam o binário
instalado por este pacote têm os argumentos atualizados; as demais são recusadas.
  No Codex, atualizar uma entrada própria preserva as demais opções, como `env`,
  tempos limite e políticas de ferramentas. Essa atualização exige Python 3.11+;
  em versões anteriores, o arquivo é preservado e o instalador informa o requisito.
  Formatos TOML que o editor não reconhece, incluindo comentários dentro de `args`,
  são recusados sem modificar o arquivo.
- Instruções existentes são preservadas; apenas blocos `six-addons:...` são atualizados.
  Arquivos gerenciados de instruções VS Code preexistentes sem marcador são recusados.
- Configurações por link simbólico são recusadas. Faça alterações deliberadas no alvo
  ou adapte sua configuração antes de reexecutar; não remova links sem avaliar seu uso.
- Os logs e backups dos instaladores de provedor ficam em
  `${XDG_STATE_HOME:-~/.local/state}/six-addons-installer/`.
  Diretórios privados usam modo 700; logs, 600. Configurações existentes mantêm seu modo.
  Backups podem conter credenciais preexistentes: não publique o conteúdo.
  O bootstrap não gera esses logs nem backups; sua saída aparece no terminal.
- Há backup antes das alterações de configuração. Não há snapshot integral de pacotes,
  rollback automático ou remoção de arquivos novos na falha. Uma falha pode deixar
  etapas anteriores concluídas; o erro informa linha/código, log e backup.
- Para restaurar, feche os clientes, compare os arquivos com o backup indicado no log
  e restaure apenas os destinos necessários. Arquivos criados pela execução não têm
  versão anterior. Para plugins/pacotes, use o gerenciador oficial se precisar reverter.
  O backup das pastas de plugins omite `cache/` e `marketplaces/`: são downloads que
  voltam ao reexecutar o instalador do plugin. A cópia tenta compartilhar blocos com
  `--reflink=auto`; quando esse recurso não está disponível, faz uma cópia convencional,
  conforme o [GNU Coreutils](https://www.gnu.org/s/coreutils/manual/html_node/cp-invocation.html).
- HTTP limitado pela API, falha de download, dependência ausente ou configuração
  conflitante interrompem o script. Resolva a causa indicada e reexecute.

O pacote não adiciona Headroom, OpenSpec, Beads, Context Mode, jCodeMunch,
codebase-memory-mcp ou orquestradores de agentes; também não remove instalações
anteriores deles.

### Manutenção de espaço

- Os backups ficam em `${XDG_STATE_HOME:-~/.local/state}/six-addons-installer/backups`,
  uma pasta por execução, e não são apagados automaticamente. Remova manualmente as
  pastas antigas que não precisar mais. Reflinks reduzem o espaço inicial quando origem
  e destino permitem compartilhar blocos; alterações posteriores podem aumentar o uso.
- O bootstrap remove distribuições antigas `node-v*-linux-*` em `~/.local/lib/nodejs`
  após selecionar a versão LTS atual. Instalações Node fora dessa pasta são preservadas.
- Para limpar entradas não utilizadas do cache uv, use `uv cache prune`;
  ambientes de projeto centralizados também são removidos e recriados quando necessários.
  Veja a [documentação do uv](https://docs.astral.sh/uv/concepts/cache/).
- Para verificar a integridade do cache npm e remover dados desnecessários, use
  `npm cache verify`. Isso não esvazia todo o cache; veja a
  [documentação do npm](https://docs.npmjs.com/cli/v11/commands/npm-cache/).

### Recuperar uma instalação interrompida

Se aparecer `Instale OpenCode ou informe --opencode-major 1|2`, confira a seleção de
clientes. Para usar OpenCode, execute o bootstrap com `--clients all` ou `--with-opencode`, aplique o
PATH da seção 2 e reexecute o instalador que falhou. Para usar apenas Codex, rode só o
`install-codex-ubuntu.sh` (ou use `"clients": "codex"` no `addons.json`).

Versões anteriores deste instalador Engram podiam parar logo depois de imprimir
`engram 3.3.2`. A causa era a chamada `engram mcp --help`: nessa versão ela inicia
o servidor MCP e aguarda entrada, em vez de exibir ajuda. Essa chamada foi removida
do instalador atual. Se estiver nessa situação:

1. Interrompa a execução antiga com **Ctrl+C**.
2. Atualize a cópia do repositório na máquina Ubuntu (a instalação do Engram fica em
   `lib/tools.sh`).
3. Reexecute o instalador do provedor com as mesmas opções.
4. Após a mensagem `Concluido:`, prossiga com os demais provedores, ou reexecute o
   `install-all-ubuntu.sh`.

Imprimir a versão do Engram não conclui a instalação: a configuração dos addons no
provedor (MCPs, regras, plugins e ajustes de memória) ocorre depois. A interrupção
preserva alterações já realizadas; não apague as configurações para recomeçar.
Se a reexecução apontar um conflito, confira o destino e o backup informado.

Para investigar outros erros, consulte o caminho de log exibido no começo da
execução. A sequência com `&&` e o `install-all` só iniciam o próximo provedor quando o
anterior termina com sucesso.

## 9. Validação e limites conhecidos

Em **26/10/2026**, os seis instaladores de provedor, o bootstrap, o orquestrador, a `lib/`, o
`graphify-preflight` e o adaptador OpenCode Desktop passaram pela verificação de sintaxe Bash e pelo ShellCheck.
Os **109 testes** em `tests/` passaram. O CI do GitLab mantém essas verificações
([.gitlab-ci.yml](.gitlab-ci.yml)). A suíte cobre:
- a `lib/`: leitura e validação do `addons.json`, opções dos addons, textos das regras,
  blocos gerenciados e sua remoção, e o preâmbulo com bloqueio, backup e log;
- a instalação das ferramentas: Go simulado, checksum, preservação de ferramentas
  existentes, limites de compilação do `gopls`, `GITHUB_TOKEN` fora da linha de comando,
  `config.toml` do RTK, mesclagem do `ccusage.json`, aviso de versão antiga do servidor
  Engram e diagnóstico Serena/Go com interface REPL e SDKs MCP v1/v2;
- os editores JSONC/TOML, com preservação de opções e comentários e migração de MCP legado;
- cada instalador de provedor com CLIs simulados: fluxo completo, idempotência, conflito
  antes de qualquer download, `--dry-run` sem arquivos, opções inválidas e os casos
  próprios do provedor (por exemplo, schemas do OpenCode, superfícies do Copilot e
  isolamento dos setups em HOME temporário);
- o orquestrador e o bootstrap;
- o `graphify-preflight` com Git real: grafo ausente, gerado, atualizado, alterado,
  commitado, sem `_meta`, subpasta, fora de repositório e Graphify ausente;
- um teste que impede um instalador de redefinir uma função da `lib/`.

O adaptador OpenCode Desktop é testado nas duas VMs, incluindo fallback, argumentos,
ccusage e recusa de comandos inválidos.

Na mesma data, o `install-all` antigo e o novo foram executados de verdade, com rede, em
dois containers Ubuntu 24.04 descartáveis com todos os clientes. As configurações
resultantes foram equivalentes, com diferenças só em timestamps e nas integrações nativas
da seção 1, e uma segunda execução do novo não alterou nada. Não foram verificados o uso
dos plugins dentro dos agentes (exige login em cada provedor) nem o plugin Ponytail do
Antigravity (`agy` indisponível).

Para conferir localmente a sintaxe dos instaladores, da `lib/` e do adaptador sem instalar nada:

```bash
(
for script in install-*-ubuntu.sh lib/*.sh bin/* opencode-desktop/ai-tooling-vm; do
  bash -n "$script" || exit 1
done
)
```

Os testes podem ser executados sem rede e sem modificar as configurações reais. Fora
do Ubuntu (por exemplo, no macOS), os testes que dependem de Bash 4/4.4+, GNU `cp` ou
Python 3.11+ (`tomllib`) são pulados automaticamente:

```bash
python3 -m unittest discover -s tests -v
```

Os testes automatizados simulam downloads e ferramentas e não comprovam chamadas ao modelo
nem o funcionamento de todos os clientes. Faça a conferência da seção 7 e, para projetos
Go, use `check-go-project`.

## 10. Fontes oficiais

Referências para os formatos e limites de integração usados pelos scripts:

- [RTK](https://github.com/rtk-ai/rtk) (incluindo os adaptadores em `src/hooks/init/`).
- [Go — instalação](https://go.dev/doc/install) e [gopls](https://go.dev/gopls/).
- [Serena — clientes](https://github.com/oraios/serena/blob/main/docs/02-usage/030_clients.md) e [repositório](https://github.com/oraios/serena).
- [Graphify](https://github.com/Graphify-Labs/graphify) (`graphifyy` no PyPI).
- [Engram — setup](https://github.com/Gentleman-Programming/engram/blob/main/docs/AGENT-SETUP.md), [documentação](https://github.com/Gentleman-Programming/engram/blob/main/DOCS.md) e [implementação](https://github.com/Gentleman-Programming/engram/tree/main/internal/setup).
- [Context7](https://github.com/upstash/context7), [ccusage e fontes suportadas](https://github.com/ccusage/ccusage/blob/main/README.md).
- [Ponytail — instalação e portabilidade](https://github.com/DietrichGebert/ponytail/blob/main/INSTALL.md).
- Opções da seção 4.3: [Ponytail `ponytail-config.js`](https://github.com/DietrichGebert/ponytail/blob/main/hooks/ponytail-config.js), [Engram `engram mcp`](https://github.com/Gentleman-Programming/engram/blob/main/cmd/engram/main.go), [Serena `start-mcp-server`](https://github.com/oraios/serena/blob/main/src/serena/cli.py), [Context7 MCP](https://github.com/upstash/context7/blob/master/packages/mcp/src/index.ts), [RTK `config.toml`](https://github.com/rtk-ai/rtk/blob/develop/src/core/config.rs) e [ccusage `ccusage.json`](https://github.com/ccusage/ccusage/blob/main/docs/guide/config-files.md).
- [Cline MCP](https://docs.cline.bot/mcp/mcp-overview), [Cline regras](https://docs.cline.bot/customization/cline-rules).
- [OpenCode V1 MCP](https://opencode.ai/docs/mcp-servers/), [V2 MCP](https://dev.opencode.ai/v2/docs/mcp-servers/), [V2 instruções](https://dev.opencode.ai/v2/docs/instructions/).
- [Copilot CLI — diretórios e precedência](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference).
- [VS Code MCP](https://code.visualstudio.com/docs/copilot/customization/mcp-servers), [instruções](https://code.visualstudio.com/docs/agent-customization/custom-instructions), [flags no código oficial](https://github.com/microsoft/vscode-copilot-chat/blob/main/package.json).
- [Claude — memória](https://code.claude.com/docs/en/memory), [Codex — configuração](https://developers.openai.com/codex/config-reference/).
- Integrações nativas (pesquisa de 26/10/2026): [OpenCode — plugins](https://opencode.ai/docs/plugins/),
  [Copilot CLI — hooks](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-hooks-reference)
  e [plugins](https://docs.github.com/copilot/concepts/agents/copilot-cli/about-cli-plugins),
  [VS Code — agent hooks](https://code.visualstudio.com/docs/agent-customization/hooks),
  [Cline — hooks](https://docs.cline.bot/features/hooks) (sem integração dos addons) e,
  para plugins do Antigravity, guias de terceiros como o da
  [SonarSource](https://docs.sonarsource.com/agent-centric-development-cycle/developer-tools/agent-plugins/antigravity);
  não há documentação oficial do Google confirmada.
