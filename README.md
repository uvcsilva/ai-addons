# Seis addons no Ubuntu — scripts independentes

**RTK, Serena, Engram, Context7, ccusage e Ponytail**, na mesma máquina e no mesmo
usuário. Suporte a Claude Code, Codex, Cline, OpenCode, Copilot CLI e Copilot no VS Code.
OpenRouter é configurado como provedor dentro do cliente.

Cada `.sh` é completo e pode ser copiado sozinho. Não há instalador unificado,
biblioteca externa compartilhada ou orquestrador. Um bloqueio compartilhado evita
que estes scripts alterem configurações ao mesmo tempo. Execute um por vez.

## 1. Compatibilidade real

| Addon | Claude Code / Codex | Cline | OpenCode 1 / 2 | Copilot CLI | Copilot VS Code |
|---|---|---|---|---|---|
| RTK | Hooks globais | Regras | Regras | Regras | Regras |
| Serena | MCP, contextos próprios | MCP, contexto `ide` | MCP, contexto `ide` | MCP, `copilot-cli` | MCP, `vscode` |
| Engram | MCP + setup/plugin oficial | MCP + protocolo por instruções | MCP + protocolo por instruções | MCP + protocolo por instruções | MCP + protocolo por instruções |
| Context7 | MCP via npx | MCP via npx | MCP via npx | MCP via npx | MCP via npx |
| ccusage | Relatórios locais | Sem fonte Cline documentada | Relatórios locais | Relatórios locais | Sem fonte da extensão documentada |
| Ponytail | Plugin oficial | Regras oficiais | Regras oficiais | Regras oficiais | Regras oficiais |

**Regras não equivalem a hooks/plugins.** Nos quatro novos clientes, o agente precisa
seguir as instruções do RTK e chamar seus comandos; não há reescrita automática de
comandos. Ponytail fornece as diretrizes de qualidade, sem seleção persistente de
níveis, comandos `/ponytail` ou injeção automática em subagentes. Engram fornece as
ferramentas de memória e um protocolo resumido; salvar/recuperar depende do agente,
sem hooks de ciclo de sessão ou recuperação automática após compactação.

Essa escolha mantém o mesmo mecanismo de instruções nos novos clientes e evita
conflitos entre hooks. Existem integrações nativas adicionais de RTK/Ponytail para
alguns deles; **este pacote não as instala**. O setup OpenCode completo do Engram
também pode instalar `opencode-subagent-statusline`; por isso usamos MCP + instruções,
preservando o escopo de exatamente seis addons.

Serena recebe **`--add-mode no-memories` em todos os seis clientes**. Engram é a
memória persistente escolhida; veja as etapas necessárias para exclusividade na seção 6.

## 2. Preparação

Prepare os pré-requisitos compartilhados e o Codex CLI antes de executar os
instaladores:

```bash
bash install-dependencies-ubuntu.sh
```

O script instala `curl`, `git`, `jq`, Python 3, `sha256sum`, `flock`, Node.js LTS,
`npm`, `npx` e Codex CLI. Execute como usuário normal; ele pede `sudo` apenas para
instalar pacotes do Ubuntu. Node.js, npm e Codex ficam no escopo do usuário, em
`~/.local`. Na primeira execução do Codex, autentique com `codex login`. Outros
clientes, como Claude Code, continuam sendo instalados separadamente. Como o padrão
dos seis instaladores é `claude,codex`, use `--clients codex` se ainda não tiver
instalado o Claude Code.

Para também preparar OpenCode:

```bash
bash install-dependencies-ubuntu.sh --with-opencode
export PATH="$HOME/.local/bin:$PATH"
```

Essa opção instala OpenCode 1 (`opencode-ai@1`) se o comando estiver ausente,
conforme o [método npm oficial](https://opencode.ai/docs/). Uma instalação existente
de OpenCode 1 ou 2 é preservada e sua versão é conferida. Os demais clientes
continuam com instalação e autenticação próprias.

**`--clients all` significa todos os clientes, não todos os addons.** Os seis addons
podem ser instalados apenas no Codex passando `--clients codex` a cada instalador.
Para `all`, OpenCode precisa estar disponível no PATH para detectar o schema 1/2;
também é necessário Claude Code. O bootstrap informa essas pendências ao terminar.
Só use `--opencode-major 1|2` para preparar a configuração de uma versão conhecida;
essa opção não instala OpenCode e não deve ser escolhida por tentativa.

- Ubuntu Linux, Bash 4+, usuário normal, sem executar os scripts com `sudo`.
- x86_64 ou aarch64/arm64 para os instaladores de binários.
- Instale e autentique os clientes que pretende usar. Apenas Claude/Codex selecionados
  exigem seus CLIs no PATH; a integração de Cline/VS Code pode ser feita sem CLI.
- Feche os agentes e editores durante a alteração. O bloqueio protege apenas contra
  outros instaladores deste pacote, não contra edições externas.
- Use versões atuais dos clientes. Claude/Codex precisam oferecer MCP e plugins.

| Script | Pré-requisitos básicos |
|---|---|
| RTK | curl, Python 3, sha256sum, flock |
| Serena | curl, Python 3, sha256sum, flock |
| Engram | curl, git, jq, Python 3, sha256sum, flock |
| Context7 | Node.js, npm, npx, Python 3, flock |
| ccusage | Node.js, npm, Python 3, flock |
| Ponytail | git, Node.js, Python 3, flock |

`flock` vem de `util-linux`; `sha256sum`, de `coreutils`. São necessários também os
utilitários básicos do Ubuntu (`install`, `tee`, `sed`, `mktemp`, entre outros).
Os seis instaladores relatam dependências ausentes; não alteram pacotes do sistema
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
absoluto para `npx` nos novos clientes, o processo precisa conseguir localizar Node.

## 3. Clientes, caminhos e opções

Todos os scripts aceitam:

```text
--help
--dry-run
--clients claude,codex,cline,opencode,copilot,vscode
--clients all
--cline-config /caminho/absoluto/cline_mcp_settings.json
--vscode-user-dir /caminho/absoluto/Code/User
--opencode-major 1|2
--project-dir /caminho/absoluto/do/projeto
```

O padrão permanece **`claude,codex`**. `copilot` identifica a CLI; `vscode`, o Copilot
no VS Code. Escolha apenas os clientes desejados. `--dry-run` não acessa a rede,
não cria logs/arquivos e não instala nada. Ele mostra o plano, não confirma que as
dependências ou configurações da máquina são válidas.

| Cliente | Destino padrão e comportamento |
|---|---|
| Claude | Configuração de usuário via CLI; respeita `CLAUDE_CONFIG_DIR`. |
| Codex | Configuração de usuário via CLI; respeita `CODEX_HOME`. |
| Cline | **Padrão da CLI:** `~/.cline/data/settings/cline_mcp_settings.json`. Também aceita `CLINE_MCP_SETTINGS_PATH`. |
| OpenCode | `${XDG_CONFIG_HOME:-~/.config}/opencode/opencode.json` ou `.jsonc`, se já existir. |
| Copilot CLI | `${COPILOT_HOME:-~/.copilot}/mcp-config.json`, chave `mcpServers`. |
| Copilot VS Code | `${XDG_CONFIG_HOME:-~/.config}/Code/User/mcp.json`, chave `servers`. |

### Cline na extensão

No Cline, abra **MCP Servers → Configure → Configure MCP Servers** e confira o
caminho do arquivo usado pela extensão. Passe esse caminho em `--cline-config`
**em todos os instaladores MCP**. Configurar o caminho padrão da CLI não configura
a extensão automaticamente. As regras globais são gravadas em `~/.cline/rules/`.

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

### VS Code, perfis, SSH e WSL

O padrão atende ao VS Code Stable no Ubuntu. Use `--vscode-user-dir` para Insiders
ou outro perfil, indicando a pasta efetiva com `settings.json`, `mcp.json` e `prompts/`.
As instruções são `prompts/six-addons-ADDON.instructions.md`, com `applyTo: "**"`.

Em SSH/WSL/containers, execute no Ubuntu onde os servidores devem rodar e selecione
os arquivos do mesmo ambiente. Não use caminhos do Windows/macOS no Bash Ubuntu.
Este pacote não instala servidores remotos nem detecta perfis/ambientes automaticamente.

### Projeto do Serena

Claude, Codex, Copilot CLI e OpenCode usam `--project-from-cwd`. Inicie esses clientes
na pasta do projeto. Para Cline e VS Code, o padrão deixa a ativação para a sessão:
peça ao Serena para ativar o caminho absoluto do projeto atual.

`--project-dir` fixa um projeto para **Cline/OpenCode/VS Code**, na configuração global.
Use apenas quando isso for intencional; não alterna automaticamente ao mudar de
workspace. Alterar o projeto de uma entrada existente resulta em conflito que deve
ser resolvido explicitamente. Essa opção não muda o diretório de instalação, nem
configura o projeto do Engram ou dos três clientes CLI.

## 4. Ordem de execução

Extraia o ZIP, entre em `addons-ubuntu` e confira o pacote:

```bash
sha256sum -c SHA256SUMS
bash install-engram-ubuntu.sh --help
bash install-engram-ubuntu.sh --clients all --dry-run
```

A ordem recomendada estabelece a memória primeiro. Os scripts continuam independentes.
A sequência abaixo é para todos os clientes, usando o **Cline CLI e o perfil padrão
VS Code**; ajuste as opções conforme a seção 3:

```bash
bash install-engram-ubuntu.sh --clients all &&
bash install-serena-ubuntu.sh --clients all &&
bash install-context7-ubuntu.sh --clients all &&
bash install-rtk-ubuntu.sh --clients all &&
bash install-ccusage-ubuntu.sh --clients all &&
bash install-ponytail-ubuntu.sh --clients all
```

`&&` interrompe a sequência se algum script falhar. Não rode em paralelo.
Para apenas os clientes novos:

```bash
bash install-engram-ubuntu.sh --clients cline,opencode,copilot,vscode \
  --cline-config /caminho/real/da/extensao/cline_mcp_settings.json \
  --opencode-major 2
```

Substitua o caminho de exemplo. Repita as mesmas opções de cliente/destino nos demais
scripts. `ccusage` aceita as opções para padronizar a execução, mas instala somente
a CLI de relatórios e não altera configurações dos clientes.

## 5. OpenRouter

OpenRouter é o provedor de modelos. Os MCPs e as regras são carregados pelo cliente,
portanto use `--clients cline,opencode`, por exemplo. `--clients openrouter` é recusado
com orientação, pois não há configuração local de MCP do provedor.

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

O script Engram:

- Desativa `autoMemoryEnabled` no Claude selecionado.
- Desativa `features.memories`, `memories.use_memories` e
  `memories.generate_memories` no Codex selecionado.
- No VS Code selecionado, desativa `github.copilot.chat.tools.memory.enabled` e
  `github.copilot.chat.copilotMemory.enabled` no `settings.json` de usuário escolhido.
- Nos quatro novos clientes, adiciona instruções para usar exclusivamente o Engram
  e evitar Memory Banks ou notas de memória nos arquivos de instruções.
- Registra o mesmo binário Engram, com `mcp --tools=agent`; no mesmo usuário e sem
  overrides distintos, os processos compartilham a base padrão em `~/.engram`.

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

Serena é registrado sem memórias pelo próprio script Serena. A verificação automática
confirma o argumento no registro; após iniciar o servidor, confira se as ferramentas
de memória e onboarding excluídas pelo modo estão ausentes.

## 7. Conferência depois da instalação

Os scripts verificam versões/ajuda dos executáveis instalados, registros MCP,
plugins nativos selecionados e arquivos de regras/configuração gravados. Não abrem
uma conversa nem confirmam uma chamada real ao modelo ou o handshake de todo MCP.

Reinicie os clientes e faça a conferência no ambiente Ubuntu:

1. Revise a confiança dos MCPs e, no Codex, dos hooks em `/hooks`; abra uma nova sessão.
2. Nos clientes selecionados, confira os servidores `engram`, `serena` e `context7`.
   Claude/Codex/OpenCode/Copilot CLI oferecem listagem de MCP; nos editores use o painel
   MCP. No VS Code, confirme que as instruções de usuário estão sendo carregadas.
3. Ative o projeto correto no Serena e confira a ausência das ferramentas de memória.
4. Peça ao agente para abrir uma sessão Engram com o diretório real e recuperar contexto.
   Para validar persistência, salve uma informação de teste sem dados privados e
   recupere-a em outra sessão/cliente. Exclua o registro de teste depois.
5. Confira uma consulta de documentação com Context7. No RTK por regras, observe se o
   agente realmente usa `rtk` nos comandos compatíveis. Confirme as regras Ponytail.

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
- Arquivos de arquivo compactado são lidos seletivamente, sem extração indiscriminada.
  Não há `curl | bash`. Pacotes e plugins oficiais instalados continuam sendo código
  de terceiros executado com as permissões do usuário.
- O bootstrap usa a versão LTS do Node.js publicada em nodejs.org, validando o SHA-256
  publicado para o arquivo baixado, e instala Codex CLI com `@latest` via npm.
- Serena usa `uv tool install --upgrade -p 3.13 serena-agent`; ccusage usa `@latest`
  com validação de requisitos de Node pelo npm. Context7 usa o pacote oficial via npx,
  sem versão fixa, resolvido ao iniciar. Plugins nativos usam os marketplaces oficiais.
- Regras Ponytail dos novos clientes são um snapshot incorporado de `AGENTS.md`, commit
  `9b58c1ffb790c075ca32e70a89cf1d80588f4abf`. Licença em `PONYTAIL-LICENSE.txt`.
  Regras RTK são geradas pelo binário instalado. O protocolo Engram desses clientes é
  uma adaptação resumida incluída no script.
- Reexecutar pode atualizar binários/pacotes/plugins. Configurações iguais e blocos
  gerenciados não são duplicados. **Não é uma instalação reproduzível com lockfile**.
- Os editores JSON/JSONC preservam comentários e outras entradas; rejeitam chaves
  duplicadas, formato inválido, schema conflitante e servidores diferentes com o
  mesmo nome. TOML é editado de modo conservador. Não há sobrescrita silenciosa de MCP.
- Instruções existentes são preservadas; apenas blocos `six-addons:...` são atualizados.
  Arquivos gerenciados de instruções VS Code preexistentes sem marcador são recusados.
- Configurações por link simbólico são recusadas. Faça alterações deliberadas no alvo
  ou adapte sua configuração antes de reexecutar; não remova links sem avaliar seu uso.
- Logs e backups ficam em `${XDG_STATE_HOME:-~/.local/state}/six-addons-installer/`.
  Diretórios privados usam modo 700; logs, 600. Configurações existentes mantêm seu modo.
  Backups podem conter credenciais preexistentes: não publique o conteúdo.
- Há backup antes das alterações de configuração. Não há snapshot integral de pacotes,
  rollback automático ou remoção de arquivos novos na falha. Uma falha pode deixar
  etapas anteriores concluídas; o erro informa linha/código, log e backup.
- Para restaurar, feche os clientes, compare os arquivos com o backup indicado no log
  e restaure apenas os destinos necessários. Arquivos criados pela execução não têm
  versão anterior. Para plugins/pacotes, use o gerenciador oficial se precisar reverter.
- HTTP limitado pela API, falha de download, dependência ausente ou configuração
  conflitante interrompem o script. Resolva a causa indicada e reexecute.

O pacote não adiciona Headroom, OpenSpec, Beads, Context Mode, jCodeMunch,
codebase-memory-mcp ou orquestrador; também não remove instalações anteriores deles.

## 9. Validação entregue

Veja `VALIDACAO.txt`: `bash -n` nos seis arquivos, ShellCheck, compilação dos Python
embutidos, help/dry-run em HOME isolado, testes de preservação/idempotência/conflitos,
backups, flags de memória e schemas/despacho dos novos clientes.

**Executado em macOS arm64, com verificações estáticas e cenários simulados. Não houve
instalação real em Ubuntu nem teste com modelos/clientes autenticados.** A confirmação
operacional na sua máquina segue a seção 7. Scripts de validação estão incluídos em
`validation/`, são opcionais e não são dependências dos instaladores.

A seleção de GPT-6.1 Sol / reasoning High para este chat é feita pelo controle de
modelo/esforço do aplicativo; os instaladores não alteram esse controle nem modelos
configurados nos clientes.

## 10. Fontes oficiais

Revisão: 10/10/2026. Referências usadas para formatos e limites de integração:

- [RTK](https://github.com/rtk-ai/rtk) (incluindo os adaptadores em `src/hooks/init/`).
- [Serena — clientes](https://github.com/oraios/serena/blob/main/docs/02-usage/030_clients.md) e [repositório](https://github.com/oraios/serena).
- [Engram — setup](https://github.com/Gentleman-Programming/engram/blob/main/docs/AGENT-SETUP.md), [documentação](https://github.com/Gentleman-Programming/engram/blob/main/DOCS.md) e [implementação](https://github.com/Gentleman-Programming/engram/tree/main/internal/setup).
- [Context7](https://github.com/upstash/context7), [ccusage e fontes suportadas](https://github.com/ryoppippi/ccusage/blob/main/apps/ccusage/README.md).
- [Ponytail — instalação e portabilidade](https://github.com/DietrichGebert/ponytail/blob/main/INSTALL.md).
- [Cline MCP](https://docs.cline.bot/mcp/mcp-overview), [Cline regras](https://docs.cline.bot/customization/cline-rules).
- [OpenCode V1 MCP](https://opencode.ai/docs/mcp-servers/), [V2 MCP](https://dev.opencode.ai/v2/docs/mcp-servers/), [V2 instruções](https://dev.opencode.ai/v2/docs/instructions/).
- [Copilot CLI — diretórios e precedência](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference).
- [VS Code MCP](https://code.visualstudio.com/docs/copilot/customization/mcp-servers), [instruções](https://code.visualstudio.com/docs/agent-customization/custom-instructions), [flags no código oficial](https://github.com/microsoft/vscode-copilot-chat/blob/main/package.json).
- [Claude — memória](https://code.claude.com/docs/en/memory), [Codex — configuração](https://developers.openai.com/codex/config-reference/).
