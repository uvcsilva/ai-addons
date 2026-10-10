# Addons para Claude Code e Codex no Ubuntu

Cada addon tem seu próprio arquivo Bash completo. Os arquivos podem ser copiados
e executados separadamente; nenhuma biblioteca comum nem outro instalador é necessário.
Os seis scripts usam um bloqueio compartilhado para impedir alterações simultâneas
entre estes instaladores. Execute com o mesmo usuário e o mesmo `XDG_STATE_HOME`.
O bloqueio não impede alterações feitas por agentes ou editores abertos.

## Comece por aqui

1. Prepare os pré-requisitos e os dois agentes conforme a seção [Preparação](#preparação).
2. Extraia o pacote, entre na pasta `addons-ubuntu` e confira `SHA256SUMS`.
3. Leia `--help` e confira o plano com `--dry-run` antes de executar cada script.
4. Siga a [ordem recomendada](#ordem-recomendada), começando pelo Engram.
5. Reinicie os agentes e revise a confiança dos hooks no Codex.

A configuração desejada é **Serena sem memórias e Engram como única memória
persistente dos agentes**, no mesmo usuário da máquina.

## Conteúdo

- [Arquivos e responsabilidades](#arquivos-e-responsabilidades)
- [Preparação](#preparação)
- [Execução](#execução)
- [Ordem recomendada](#ordem-recomendada)
- [Memória](#memória)
- [Conferência após a instalação](#conferência-após-a-instalação)
- [Backups, logs, repetição e erros](#backups-logs-repetição-e-erros)
- [Versões e verificação](#versões-e-verificação)
- [Fontes oficiais consultadas](#fontes-oficiais-consultadas)

## Arquivos e responsabilidades

| Arquivo | Instalação e configuração |
|---|---|
| `install-rtk-ubuntu.sh` | RTK em `~/.local/bin`; hooks globais de Claude Code e Codex. |
| `install-serena-ubuntu.sh` | uv/uvx e Serena; MCP de cada agente com seu contexto e `--add-mode no-memories`. |
| `install-engram-ubuntu.sh` | Engram; setups oficiais dos dois agentes; desativa as memórias nativas do Claude e do Codex. |
| `install-context7-ubuntu.sh` | MCP Context7 nos dois agentes via `npx`; pacote baixado ao iniciar o servidor. |
| `install-ccusage-ubuntu.sh` | ccusage via npm global com prefixo do usuário `~/.local`. |
| `install-ponytail-ubuntu.sh` | Plugin Ponytail do marketplace oficial para cada agente. |

O pacote contém exatamente esses seis addons. uv e Python são ferramentas necessárias
para o Serena. Não há instalador de Headroom, OpenSpec, Beads, Context Mode,
jCodeMunch, codebase-memory-mcp nem orquestrador.

## Preparação

Execute no Ubuntu com Bash 4 ou superior, como seu usuário normal, sem `sudo`.
Os instaladores de binários suportam x86_64 e aarch64/arm64.
Use versões atuais de Claude Code e Codex que ofereçam os comandos de MCP e plugins.
Os agentes precisam estar instalados e autenticados antes das integrações.
A instalação do ccusage, isoladamente, requer apenas os pré-requisitos de sua linha
na tabela abaixo; os registros dos agentes serão necessários para gerar relatórios.

| Script | Pré-requisitos conferidos |
|---|---|
| RTK | curl, Python 3, sha256sum, flock, claude, codex |
| Serena | curl, Python 3, sha256sum, flock, claude, codex |
| Engram | curl, git, jq, Python 3, sha256sum, flock, claude, codex |
| Context7 | Node.js, npm, npx, Python 3, flock, claude, codex |
| ccusage | Node.js, npm, flock |
| Ponytail | git, Node.js, Python 3, flock, claude, codex |

`flock` é fornecido pelo pacote Ubuntu `util-linux`; `sha256sum` por `coreutils`.
São utilizados também utilitários básicos do Ubuntu, como `install`, `tee`, `sed` e `mktemp`.
Node precisa estar disponível no PATH das sessões dos agentes e dos hooks.
O npm recusa uma versão incompatível de Node na instalação do ccusage.

Os scripts informam os pré-requisitos ausentes e encerram. Eles não instalam os
agentes nem alteram pacotes do sistema. O Serena instala seu Python 3.13 isolado via uv.
Para editar configurações Codex com strings TOML de várias linhas, o script Engram
requer Python 3.11+; com Python anterior ele recusa esse formato sem alterar o arquivo.

Garanta este diretório no PATH do terminal e das sessões que iniciam os agentes:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Persista essa linha no arquivo de inicialização adequado do seu shell. O comando
acima afeta apenas a sessão atual. Evite acrescentar a mesma linha várias vezes.

## Execução

Extraia o ZIP e entre na pasta `addons-ubuntu`. Feche as sessões dos agentes antes
de alterar configurações. Pode conferir a integridade do pacote com:

```bash
sha256sum -c SHA256SUMS
```

Cada arquivo aceita as mesmas opções. Estes dois comandos exibem informações:

```bash
bash ./install-engram-ubuntu.sh --help
bash ./install-engram-ubuntu.sh --dry-run
```

`--dry-run` mostra o plano sem acessar rede, gravar arquivos ou executar os agentes.
É uma simulação do plano; não verifica a disponibilidade dos pré-requisitos.

### Ordem recomendada

| Etapa | Addon | Motivo da posição |
|---|---|---|
| 1 | Engram | Desativa as memórias nativas e configura a memória compartilhada. |
| 2 | Serena | Registra a análise de código com o modo sem memórias. |
| 3 | Context7 | Disponibiliza a consulta de documentação. |
| 4 | RTK | Configura os hooks de redução de saída do terminal. |
| 5 | ccusage | Disponibiliza os relatórios de consumo. |
| 6 | Ponytail | Adiciona o plugin de qualidade de código. |

A sequência é uma recomendação de configuração. Cada instalador funciona por si
só e pode ser executado novamente quando necessário.

Para instalar a seleção completa, execute o bloco abaixo. O `&&` faz a sequência
parar no primeiro erro, inclusive se você colar o bloco inteiro no terminal:

```bash
bash ./install-engram-ubuntu.sh &&
bash ./install-serena-ubuntu.sh &&
bash ./install-context7-ubuntu.sh &&
bash ./install-rtk-ubuntu.sh &&
bash ./install-ccusage-ubuntu.sh &&
bash ./install-ponytail-ubuntu.sh
```

Para instalar apenas um addon, execute seu comando individual, sem o `&&` final.
Por exemplo: `bash ./install-serena-ubuntu.sh`. Não execute os instaladores em paralelo.

Pare se houver erro e resolva a causa informada antes de continuar. A ordem coloca
a política de memória em vigor primeiro; os arquivos continuam independentes.
No setup Claude do Engram, responda ao pedido de permissões MCP conforme sua política.
Ao terminar, reinicie os agentes. No Codex, abra `/hooks`, revise os hooks dos plugins
e conceda confiança quando solicitado; depois inicie uma nova sessão.

## Memória

O script Serena registra dois MCPs com `--add-mode no-memories`. Esse modo oficial
exclui as ferramentas de memória e de onboarding.

O script Engram aplica estas configurações no escopo do usuário:

- Claude Code: `autoMemoryEnabled: false` em `settings.json`.
- Codex: `memories = false` na tabela `[features]`; `use_memories = false` e
  `generate_memories = false` na tabela `[memories]`, em `config.toml`.
- Engram nos dois agentes: executável absoluto com `mcp --tools=agent`, além
  dos plugins e hooks instalados pelos setups oficiais.

As configurações do Codex correspondem aos controles descritos na
[documentação oficial de memórias locais](https://learn.chatgpt.com/docs/customization/memories).
A política completa depende da conclusão dos scripts **Engram e Serena**:
o instalador Engram não altera um servidor Serena instalado anteriormente.

O Engram usa sua base local padrão `~/.engram/engram.db`, compartilhada pelo mesmo
usuário da máquina. Variáveis personalizadas `ENGRAM_*` podem mudar o destino;
use os padrões para que os dois agentes utilizem a mesma memória local.
Arquivos antigos de memória são preservados. As configurações de projeto, gerenciadas
ou de ambiente podem prevalecer sobre as configurações do usuário; confira essas
camadas se houver uma política de memória diferente no seu ambiente.
Integrações de memória que já existam fora desta seleção também precisam ser
revisadas: estes instaladores não as removem automaticamente.

## Conferência após a instalação

Os scripts verificam suas próprias alterações. Após reiniciar os agentes, confira
também os registros no Ubuntu:

```bash
claude mcp list
codex mcp list
claude plugin list
codex plugin list
rtk init --show
ccusage --help
```

Nos MCPs, procure Serena, Engram e Context7. Nos plugins, procure Engram e Ponytail
habilitados. Context7 pode baixar o pacote na primeira inicialização; precisa de
rede nesse momento. O registro de um MCP confirma sua configuração, enquanto uma
consulta bem-sucedida dentro do agente confirma que o servidor está acessível.

Em uma nova sessão, confira que as ferramentas de memória/onboarding do Serena
estão ausentes e que as ferramentas de memória do Engram estão disponíveis. Os
scripts não executam uma conversa de teste nem gravam uma memória de teste.

## Backups, logs, repetição e erros

Todos usam `${XDG_STATE_HOME:-$HOME/.local/state}/six-addons-installer`:

- `install-<addon>-<data>-<pid>.log`: log privado de cada execução, modo 600.
- `backups/<addon>-<data>-<pid>/`: cópias dos arquivos existentes que a integração
  pode alterar, incluindo instruções e registros de plugins quando aplicável.
- `install.lock`: bloqueio comum aos seis arquivos. Uma execução simultânea
  encerra com uma mensagem para tentar novamente depois.

Cada script cria seu próprio backup antes das alterações. A reexecução pode atualizar
os pacotes; MCPs já configurados com os mesmos comandos são reutilizados. Entradas
MCP com comando ou argumentos diferentes são conflitos e encerram a execução.
Configurações por link simbólico são recusadas para evitar destinos inesperados.

As alterações de memória preservam os demais valores. JSON inválido ou com chaves
duplicadas, entradas MCP com valor `null`, tabelas de
memória duplicadas e formatos TOML ambíguos são recusados. Em Python 3.11+, o editor
também compara os valores TOML antes e depois da alteração.

Os scripts encerram em erro e informam log e backup. Uma falha pode deixar etapas
anteriores concluídas: não há transação nem restauração automática de instalações,
caches ou bancos de dados. Corrija a causa e reexecute, ou restaure somente os
arquivos afetados a partir do backup. A base de memórias Engram não é sobrescrita.

Respeitam `CLAUDE_CONFIG_DIR`, `CODEX_HOME` e `XDG_STATE_HOME` quando definidos como
caminhos absolutos. As integrações são executadas em uma pasta temporária fora de
repositórios para evitar configuração de projeto durante a instalação.

## Versões e verificação

RTK, uv e Engram resolvem a release estável atual na API oficial do GitHub e conferem
o SHA-256 publicado pela API antes de instalar. O processo para se o digest estiver
ausente ou não conferir. O SHA confirma a integridade em relação à API; não é uma
assinatura independente do fornecedor. A extração lê somente o binário esperado
e recusa caminhos perigosos no arquivo compactado.

Serena é instalado/atualizado via uv; ccusage via npm com registro oficial explícito.
Context7 usa a resolução de versão do npx ao iniciar. Plugins usam os marketplaces
oficiais. Não há congelamento de todas as versões; versões de binários e plugins
são registradas no log. Reexecutar em outra data pode obter versões mais recentes.

Cada script confere sua instalação: versões e ajuda das CLIs quando disponíveis,
entradas MCP, hooks RTK ou presença/habilitação dos plugins, conforme o addon.
Context7 verifica o registro dos MCPs; o servidor será baixado e iniciado pelo agente.
Essas verificações não comprovam login nos agentes, conectividade a todos os serviços
nem uso efetivo dos hooks em uma nova conversa.

Os seis arquivos passaram por `bash -n`, ShellCheck e verificações isoladas de ajuda,
simulação, memória, conflitos MCP e backup. Consulte `VALIDACAO.txt` para o resultado.
A validação foi feita em macOS; não foi executada instalação real em Ubuntu.
Na revisão adicional, foram reproduzidos e corrigidos três casos: chaves JSON
duplicadas, entrada MCP Claude com valor `null` e consulta Codex que falha mesmo
retornando JSON válido. Os testes dessas situações passaram após as correções.

## Fontes oficiais consultadas

- [RTK — integrações por agente](https://github.com/rtk-ai/rtk/blob/develop/docs/guide/getting-started/supported-agents.md)
- [Serena — instalação](https://github.com/oraios/serena/blob/main/docs/02-usage/010_installation.md)
  e [memórias e modo no-memories](https://github.com/oraios/serena/blob/main/docs/02-usage/045_memories.md)
- [Engram — setup dos agentes](https://github.com/Gentleman-Programming/engram/blob/main/docs/AGENT-SETUP.md)
- [Context7 — clientes](https://github.com/upstash/context7/blob/master/docs/resources/all-clients.mdx)
- [ccusage — instalação](https://github.com/ccusage/ccusage/blob/main/docs/guide/installation.md)
- [Ponytail — instalação](https://github.com/DietrichGebert/ponytail/blob/main/INSTALL.md)
- [Claude Code — memória](https://code.claude.com/docs/en/memory)
- [Codex — configuração](https://learn.chatgpt.com/docs/config-file/config-reference)
  e [implementação oficial dos comandos de plugins](https://github.com/openai/codex/blob/main/codex-rs/cli/src/plugin_cmd.rs)

Pacote preparado em 10/10/2026.
