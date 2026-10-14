# Seis addons no Ubuntu — scripts independentes

**RTK, Serena, Engram, Context7, ccusage e Ponytail**, na mesma máquina e no mesmo
usuário. Suporte a Claude Code, Codex, Cline, OpenCode, Copilot CLI e Copilot no VS Code.
OpenRouter é configurado como provedor dentro do cliente.

Cada `.sh` é completo e pode ser copiado sozinho. Há seis instaladores de addons e
um script de preparação, `install-dependencies-ubuntu.sh`. O script de preparação
instala dependências e clientes conforme suas opções; os addons são instalados
pelos outros seis scripts. Não há biblioteca externa compartilhada ou orquestrador.
Os seis instaladores de addons compartilham um bloqueio de configuração; o script
de preparação não participa desse bloqueio. Execute todos os scripts um por vez.

## 1. Compatibilidade real

| Addon | Claude Code / Codex | Cline | OpenCode 1 / 2 | Copilot CLI | Copilot VS Code |
|---|---|---|---|---|---|
| RTK | Hooks globais | Regras | Regras | Regras | Regras |
| Serena | MCP, contextos próprios | MCP, contexto `ide` | MCP, contexto `ide` | MCP, `copilot-cli` | MCP, `vscode` |
| Engram | MCP + setup/plugin oficial | MCP + protocolo por instruções | MCP + protocolo por instruções | MCP + protocolo por instruções | MCP + protocolo por instruções |
| Context7 | MCP local (npm) | MCP local (npm) | MCP local (npm) | MCP local (npm) | MCP local (npm) |
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
export PATH="$HOME/.local/bin:$PATH"
codex login
```

O script instala `curl`, `git`, `jq`, Python 3, `sha256sum`, `flock`, Node.js LTS,
`npm`, `npx` e Codex CLI. Execute como usuário normal; ele pede `sudo` apenas para
instalar pacotes do Ubuntu. As novas instalações de Node.js, npm e Codex ficam no
escopo do usuário, em `~/.local`. Um Codex já disponível no PATH é preservado.
Use `codex login` se ainda não estiver autenticado. Outros
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

O script de preparação aceita somente `--help` e `--with-opencode`. Ele não aceita
`--clients` nem `--dry-run`. A alteração do PATH dentro de um script não se propaga
ao terminal que o iniciou; por isso os exemplos incluem `export PATH=...`.

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
| Context7 | Node.js, npm, Python 3, flock |
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
absoluto para `context7-mcp` nos clientes, o processo precisa conseguir localizar Node.

## 3. Clientes, caminhos e opções

Os seis instaladores de addons aceitam as opções abaixo. Elas não se aplicam a
`install-dependencies-ubuntu.sh`:

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

### Serena em projetos Go

O servidor MCP do Serena precisa também do compilador e do analisador da linguagem.
Para Go, prepare Go e `gopls` e teste uma leitura real de símbolos:

```bash
bash install-serena-ubuntu.sh --clients codex --with-go \
  --check-go-project /caminho/absoluto/do/projeto-go
```

`--with-go` preserva Go e `gopls` já disponíveis no PATH. Quando ausentes, instala
Go estável oficial para amd64/arm64 com SHA-256 verificado e `gopls` via `go install`.
Os binários ficam no escopo do usuário; a compilação de `gopls` usa dois processadores
e um pacote por vez para reduzir o consumo de memória. A versão Go exigida pelo
projeto continua definida no `go.mod`; uma instalação existente antiga pode precisar
de atualização. Dependências do módulo podem ser baixadas durante o teste.

`--check-go-project` exige `go.mod` na raiz, inicia uma conexão MCP temporária e
confirma símbolos do primeiro arquivo Go encontrado, com limite de 180 segundos.
Não altera o projeto ativo do chat. Serena pode criar sua configuração `.serena`
quando o projeto ainda não está preparado. O teste usa as dependências Go já instaladas;
sem `--with-go`, não instala Go/gopls. Essas duas opções são exclusivas do instalador
Serena e também aparecem no `--dry-run`.

Outras linguagens continuam exigindo seus próprios compiladores/analisadores;
este pacote não instala todos os servidores de linguagem. Após corrigir dependências,
reabra o cliente para reconectar um MCP que tenha encerrado com `Transport closed`.

Os instaladores Serena e Context7 registram gatilhos de uso no `AGENTS.md` global
do Codex, em blocos gerenciados, preservando instruções existentes e sem duplicação
na reexecução. Engram, Ponytail e RTK mantêm suas integrações oficiais. Addons são
usados conforme a tarefa; `ccusage` gera relatórios sob demanda. Visualize é um plugin
adicional do Codex e não integra o conjunto de seis addons deste repositório.

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

Entre na pasta da sua cópia do repositório (por exemplo, `~/addons`) e consulte
as opções antes de instalar:

```bash
bash install-engram-ubuntu.sh --help
bash install-engram-ubuntu.sh --clients codex --dry-run
```

A ordem recomendada estabelece a memória primeiro. Os scripts continuam independentes.
Para instalar os seis addons **somente no Codex**, após a preparação da seção 2:

```bash
bash install-engram-ubuntu.sh --clients codex &&
bash install-serena-ubuntu.sh --clients codex &&
bash install-context7-ubuntu.sh --clients codex &&
bash install-rtk-ubuntu.sh --clients codex &&
bash install-ccusage-ubuntu.sh --clients codex &&
bash install-ponytail-ubuntu.sh --clients codex
```

Para **todos os seis clientes**, prepare também OpenCode com `--with-opencode` e
instale Claude Code. A sequência abaixo usa o **Cline CLI e o perfil padrão
VS Code**; ajuste os destinos conforme a seção 3. Os aplicativos e suas contas
precisam estar configurados para usar as integrações:

```bash
bash install-engram-ubuntu.sh --clients all &&
bash install-serena-ubuntu.sh --clients all &&
bash install-context7-ubuntu.sh --clients all &&
bash install-rtk-ubuntu.sh --clients all &&
bash install-ccusage-ubuntu.sh --clients all &&
bash install-ponytail-ubuntu.sh --clients all
```

`&&` interrompe a sequência se algum script falhar. Não rode em paralelo.
O setup oficial do Engram pode solicitar confirmação para adicionar ferramentas
à lista de permissões do Claude; responda no terminal. Aguarde a mensagem
`Concluido:` de cada instalador antes de considerá-lo finalizado.
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
   No Claude, os instaladores do Context7 e do Serena garantem `env.MCP_TIMEOUT` de
   pelo menos `60000` no `~/.claude/settings.json`, porque a primeira partida do
   Node/`uv` pode passar dos 30s padrão. Um valor maior já definido é mantido.
3. Ative o projeto correto no Serena, confira a ausência das ferramentas de memória
   e peça uma leitura de símbolos de um arquivo. Para Go, use também o teste acima;
   um registro MCP válido pode coexistir com falha do servidor de linguagem.
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
- Os instaladores de RTK, Engram e uv extraem seletivamente os binários dos arquivos
  compactados. O bootstrap extrai a distribuição completa do Node.js em `~/.local/lib/nodejs`.
  Não há `curl | bash`. Pacotes e plugins oficiais instalados continuam sendo código
  de terceiros executado com as permissões do usuário.
- O bootstrap usa a versão LTS do Node.js publicada em nodejs.org, validando o SHA-256
  publicado para o arquivo baixado. Instala Codex CLI com `@latest` via npm somente
  se ausente; com `--with-opencode`, instala `opencode-ai@1` somente se ausente.
  Reexecutar o bootstrap pode atualizar o Node LTS, mas preserva os clientes existentes.
- Serena usa `uv tool install --upgrade -p 3.13 serena-agent`; ccusage usa `@latest`
  com validação de requisitos de Node pelo npm. Context7 instala `@upstash/context7-mcp@latest`
  em `~/.local` e registra `~/.local/bin/context7-mcp`; a versão só muda ao reexecutar o
  instalador. Entradas antigas via `npx` criadas pelo instalador são migradas; qualquer
  outra entrada diferente continua recusada. Plugins nativos usam os marketplaces oficiais.
- Regras Ponytail dos novos clientes são um snapshot incorporado de `AGENTS.md`, commit
  `9b58c1ffb790c075ca32e70a89cf1d80588f4abf`. Consulte a licença no repositório oficial
  do Ponytail listado na seção 10; não há `PONYTAIL-LICENSE.txt` nesta cópia.
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
- Os logs e backups dos seis instaladores de addons ficam em
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
  voltam ao reexecutar o instalador do plugin. A cópia usa `--reflink=auto`, que em
  btrfs/XFS compartilha blocos com o original e quase não ocupa espaço.
- HTTP limitado pela API, falha de download, dependência ausente ou configuração
  conflitante interrompem o script. Resolva a causa indicada e reexecute.

O pacote não adiciona Headroom, OpenSpec, Beads, Context Mode, jCodeMunch,
codebase-memory-mcp ou orquestrador; também não remove instalações anteriores deles.

### Manutenção de espaço

- Os backups ficam em `~/.local/state/six-addons-installer/backups`, uma pasta por
  execução, e não são apagados automaticamente. Remova manualmente as pastas antigas
  que não precisar mais. Em btrfs/XFS a cópia usa reflink e quase não ocupa espaço.
- O bootstrap remove versões antigas do Node em `~/.local/lib/nodejs` ao trocar de LTS.
- Os caches do uv (Serena) e do npm crescem com o uso. Para podar sem afetar o que
  está instalado: `uv cache prune` e `npm cache verify`.

### Recuperar uma instalação interrompida

Se aparecer `Instale OpenCode ou informe --opencode-major 1|2`, confira a seleção de
clientes. Para usar OpenCode, execute o bootstrap com `--with-opencode`, aplique o
PATH da seção 2 e reexecute o instalador que falhou. Para usar apenas Codex, passe
`--clients codex` em todos os seis comandos.

Versões anteriores deste instalador Engram podiam parar logo depois de imprimir
`engram 3.3.2`. A causa era a chamada `engram mcp --help`: nessa versão ela inicia
o servidor MCP e aguarda entrada, em vez de exibir ajuda. Essa chamada foi removida
do instalador atual. Se estiver nessa situação:

1. Interrompa a execução antiga com **Ctrl+C**.
2. Atualize `install-engram-ubuntu.sh` na máquina Ubuntu com a cópia corrigida.
3. Reexecute o instalador Engram com os mesmos clientes e caminhos escolhidos.
4. Após a mensagem `Concluido: Engram instalado/configurado para o usuario.`,
   prossiga com os demais addons na ordem da seção 4. Também é possível reexecutar
   a sequência completa com `&&`, começando pelo Engram.

Imprimir a versão do Engram não conclui sua instalação: a gravação das regras dos
novos clientes e os ajustes de memória do VS Code ocorrem depois. A interrupção
preserva alterações já realizadas; não apague as configurações para recomeçar.
Se a reexecução apontar um conflito, confira o destino e o backup informado.

Para investigar outros erros, consulte o caminho de log exibido no começo da
execução. A sequência com `&&` só inicia o próximo addon quando o anterior termina
com sucesso.

## 9. Validação e limites conhecidos

Na revisão de 11/10/2026, foram realizadas verificações de sintaxe Bash e de diff
nos scripts alterados. O bootstrap passou por seis cenários simulados: instalação
padrão, instalação opcional de OpenCode, preservação de OpenCode 2, rejeição de versão
incompatível, conflito de arquivos antes de `sudo` e recusa de checksum incorreto.
A reexecução também conferiu que o bloco de PATH não é duplicado.

O relato de execução em Ubuntu 26.04 arm64 confirmou a conclusão do bootstrap com
Codex preexistente. A execução do Engram 3.3.2 avançou até as verificações de MCP e
plugins, mas parou na chamada de ajuda descrita acima. A correção passou pela
verificação de sintaxe; a conclusão da sequência completa em Ubuntu ainda precisa
ser confirmada. Esses resultados não comprovam chamadas reais aos modelos ou o
funcionamento de todos os MCPs; faça a conferência da seção 7.

Esta cópia do repositório não inclui `VALIDACAO.txt`, `validation/` nem
`SHA256SUMS`. As simulações mencionadas foram executadas fora do repositório.
Para conferir localmente a sintaxe dos sete scripts sem instalar nada:

```bash
for script in install-*-ubuntu.sh; do
  bash -n "$script" || break
done
```

Os testes locais das novas opções, checksum, conflitos e preservação dos blocos
Codex podem ser executados sem rede e sem modificar as configurações reais:

```bash
python3 -m unittest discover -s tests -v
```

Esses testes simulam downloads e ferramentas; não substituem a leitura real do
projeto com `--check-go-project` nem a conferência dos outros MCPs no cliente.

## 10. Fontes oficiais

Revisão: 10/10/2026. Referências usadas para formatos e limites de integração:

- [RTK](https://github.com/rtk-ai/rtk) (incluindo os adaptadores em `src/hooks/init/`).
- [Go — instalação](https://go.dev/doc/install) e [gopls](https://go.dev/gopls/).
- [Serena — clientes](https://github.com/oraios/serena/blob/main/docs/02-usage/030_clients.md) e [repositório](https://github.com/oraios/serena).
- [Engram — setup](https://github.com/Gentleman-Programming/engram/blob/main/docs/AGENT-SETUP.md), [documentação](https://github.com/Gentleman-Programming/engram/blob/main/DOCS.md) e [implementação](https://github.com/Gentleman-Programming/engram/tree/main/internal/setup).
- [Context7](https://github.com/upstash/context7), [ccusage e fontes suportadas](https://github.com/ryoppippi/ccusage/blob/main/apps/ccusage/README.md).
- [Ponytail — instalação e portabilidade](https://github.com/DietrichGebert/ponytail/blob/main/INSTALL.md).
- [Cline MCP](https://docs.cline.bot/mcp/mcp-overview), [Cline regras](https://docs.cline.bot/customization/cline-rules).
- [OpenCode V1 MCP](https://opencode.ai/docs/mcp-servers/), [V2 MCP](https://dev.opencode.ai/v2/docs/mcp-servers/), [V2 instruções](https://dev.opencode.ai/v2/docs/instructions/).
- [Copilot CLI — diretórios e precedência](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference).
- [VS Code MCP](https://code.visualstudio.com/docs/copilot/customization/mcp-servers), [instruções](https://code.visualstudio.com/docs/agent-customization/custom-instructions), [flags no código oficial](https://github.com/microsoft/vscode-copilot-chat/blob/main/package.json).
- [Claude — memória](https://code.claude.com/docs/en/memory), [Codex — configuração](https://developers.openai.com/codex/config-reference/).
