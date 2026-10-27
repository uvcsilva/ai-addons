# AGENTS.md

Instaladores Bash, para Ubuntu, dos addons (Engram, Serena, Context7, RTK, ccusage, Ponytail e
Graphify) nos clientes de IA, com **um instalador por provedor**. Detalhes de uso e de
compatibilidade ficam no `README.md`.

## Ferramentas dos addons nesta sessão

Use cada ferramenta abaixo **somente se ela estiver disponível na sessão** (MCP registrado,
plugin ou hook ativo, ou comando no PATH). Se não estiver, siga sem ela e não a instale nem
simule. Quando houver integração nativa, prefira-a às instruções; não duplique o que um
plugin ou hook já faz.

- **Graphify — grafo do repositório antes de varrê-lo.** Sempre que precisar explorar um
  repositório Git de forma ampla (ler muitos arquivos, buscar pela árvore, mapear a
  arquitetura), rode antes `graphify-preflight ensure` na pasta do repositório.
  - O pre-flight compara o `_meta` de `graphify-out/graph.json` (commit, hash da árvore e da
    árvore de trabalho) com o Git, sem gastar tokens.
  - Se o grafo **não existir** ou estiver desatualizado, o pre-flight o cria ou atualiza
    localmente (AST, sem LLM). Saídas do `check`: 0 atualizado, 1 desatualizado, 2 sem grafo,
    3 fora de repositório Git.
  - Com o grafo atualizado, consulte primeiro `graphify query "<pergunta>"`,
    `graphify explain "<símbolo>"` ou `graphify path "A" "B"`, e abra só os arquivos indicados.
  - Quando o pre-flight disser "atualizado", confie no grafo sem conferir de novo. Para o que
    o grafo não cobre, use o Serena.
  - Não versione `graphify-out/`: o pre-flight o coloca em `.git/info/exclude`.
- **Engram — memória persistente exclusiva.** No início, recupere contexto (`mem_context`,
  `mem_search`) antes de redescobrir decisões. Salve decisões, correções com causa,
  convenções e descobertas não óbvias com `mem_save` (O quê/Por quê/Onde/Aprendido) e use
  `topic_key` para atualizar um tema em vez de duplicá-lo. Feche com `mem_session_summary`.
  Não use outro armazenamento de memória (Memory Bank, memórias do Serena, memória nativa
  do cliente, notas em `AGENTS.md`/`CLAUDE.md`). Nunca grave segredos, credenciais ou logs
  brutos. Se as chamadas falharem, informe e conclua o trabalho mesmo assim.
- **Serena — navegação e edição por símbolos.** Para código Bash e Python deste
  repositório (`.serena/project.yml` declara `bash` e `python`), prefira a visão geral de
  símbolos, a busca e as referências do Serena a ler arquivos inteiros. Se o servidor de
  linguagem falhar, informe: um MCP registrado não prova que a análise funciona.
- **Context7 — documentação atual.** Consulte antes de afirmar sintaxe, flags ou formatos de
  configuração de ferramentas externas (CLIs dos clientes, `rtk`, `engram`, `uv`, `npm`,
  OpenCode, Copilot). Resolva o identificador da biblioteca antes de consultar.
- **RTK — saída condensada de comandos.** Com o hook ativo, os comandos já são reescritos.
  Sem hook, prefixe os comandos de shell compatíveis com `rtk`. Trate a saída condensada
  como completa; use `rtk bypass <cmd>` só quando ela vier vazia, contraditória ou
  ilegível.
- **Ponytail — a menor mudança completa.** Resolva o problema inteiro com o mínimo de código
  novo, reaproveitando o que já existe em `lib/`. Sem abstrações, opções ou "para depois"
  que ninguém pediu. Ao final, diga em uma ou duas linhas o que ficou sem verificar.
- **ccusage** é uma CLI de relatórios de uso; rode só quando pedirem relatório de consumo.

## Comandos

Execute na raiz. São os mesmos das CIs (`.gitlab-ci.yml` e `.github/workflows/ci.yml`):

```bash
for f in install-*-ubuntu.sh opencode-desktop/ai-tooling-vm lib/*.sh bin/*; do bash -n "$f"; done
shellcheck -x -S warning install-*-ubuntu.sh opencode-desktop/ai-tooling-vm lib/*.sh bin/*
python3 -m unittest discover -v tests
```

- Os testes não usam rede e simulam CLIs e downloads em diretórios temporários. Os testes
  de fluxo executam o preâmbulo real (`installer_begin`), que **recusa root**: rode-os como
  usuário comum. Na CI, isso é feito com `runuser -u tester`.
- Para conferir um instalador sem alterar nada, use `--dry-run` (sem rede, arquivos ou
  logs). **Não execute um instalador sem `--dry-run` no `HOME` real**: ele grava nas
  configurações dos clientes do usuário. Para ensaios reais, use um `HOME` temporário ou um
  ambiente descartável.
- Em `orb -m <vm> bash -lc`, inclua sempre `cd /caminho/absoluto/do/repositorio &&` no
  shell da VM: o diretório de trabalho do chamador não é preservado. Antes de `git init`,
  `graphify-preflight build|ensure` ou instaladores, confira `pwd` para não escrever no
  `HOME` por engano.

## Validação de integrações

- Registro em `mcp.json`, versão do executável e `kimi doctor` não provam funcionamento:
  o diagnóstico do Kimi confere os arquivos TOML, não chamadas MCP. Teste handshake e uma
  chamada real de leitura; quando possível, repita pelo modelo do cliente. Diferencie MCPs,
  skills e regras: RTK e Ponytail no Kimi não são hooks/plugins interativos.
- Para validar o Kimi ponta a ponta, abra a sessão na raiz do projeto, confie na pasta e
  conclua `/login`. Em um workspace descartável e conhecido,
  `KIMI_CODE_TRUST_WORKSPACE=1` substitui apenas a confirmação interativa, não o login.
  Não grave memórias de teste no Engram sem necessidade; prefira `mem_search` e análise de
  símbolos do Serena.

## Mapa

- `install-<provedor>-ubuntu.sh` (`claude`, `codex`, `kimi`, `copilot`, `cline`, `opencode` e
  `antigravity`): todo o código específico de um provedor. O fluxo fica em `main()`, que só
  roda quando o script é executado diretamente; os testes o carregam com `source`.
- `install-all-ubuntu.sh`: lê o `addons.json` e roda o bootstrap e um instalador por
  provedor de `clients`, com `--dry-run` de todos antes.
- `install-dependencies-ubuntu.sh`: bootstrap (pacotes do Ubuntu e CLIs dos clientes);
  independente da `lib/`.
- `lib/common.sh` (preâmbulo, bloqueio, backup, log, blocos `six-addons:<addon>`),
  `lib/config.sh` (`addons.json`), `lib/addons.sh` (opções, argv MCP, textos das regras),
  `lib/tools.sh` (instalação das ferramentas) e `lib/json-mcp.sh` (editor JSON/JSONC).
- `bin/graphify-preflight`: pre-flight do grafo (`check|build|ensure`), instalado em
  `~/.local/bin` por `lib/tools.sh`.
- `tests/`: `test_install_<provedor>.py` usa `tests/provider_harness.py`; `test_lib.py`,
  `test_tools.py`, `test_install_all.py`, `test_graphify_preflight.py`; `test_installers.py`
  reúne cenários de funções.
- `opencode-desktop/ai-tooling-vm`: adaptador do OpenCode Desktop no macOS para as VMs
  OrbStack.

## Regras do projeto

- Cada instalador de provedor configura **todos** os addons e **nunca escreve em arquivos de
  outro provedor**. Setups externos que fariam isso rodam com `HOME` temporário e só o
  necessário é copiado (veja `install-opencode-ubuntu.sh`).
- Confira todos os MCPs e conflitos antes de `tools_install`: um conflito interrompe tudo
  sem alterar nada. Faça backup antes de editar e preserve conteúdo do usuário. Blocos de
  regras só mudam por `write_managed_rule`/`remove_managed_rule`.
- Uma função da `lib/` não pode ser redefinida num instalador que carrega
  `lib/common.sh`; `test_lib_functions_are_not_redefined` garante isso.
- As opções dos addons vêm só do `addons.json`. As flags dos instaladores ficam restritas a
  `--config`, `--dry-run`, `--help` e caminhos do provedor. Mudanças de schema exigem
  atualizar `lib/config.sh`, `addons.json`, `addons.exemple.json` e o README.
- Mensagens dos scripts ficam em português sem acentos, como no código existente. Use
  `die` para erros e `exit 2` para opção ou configuração inválida.
- Mudança de comportamento leva teste no arquivo do provedor ou da `lib/` correspondente.
  Atualize o README quando opções, destinos ou o fluxo mudarem.
- Um provedor novo segue o README §4.5: instalador próprio, inclusão em
  `install-all-ubuntu.sh` e na lista de clientes de `lib/config.sh`, e testes com o
  `provider_harness`.
- Planos e handoffs ficam em `.ia/` (ignorada pelo Git); nunca a versione.

## Temporários, Docker e limpeza

- Registre os temporários, containers, imagens e worktrees criados pela tarefa. Antes de
  concluir, remova só os atribuíveis à tarefa e descartáveis; preserve entregáveis,
  recursos que o usuário pediu para manter e qualquer coisa de terceiros. Na dúvida,
  preserve e informe.
- Antes de excluir, faça um inventário somente de leitura com os caminhos ou IDs exatos;
  confira conteúdo, uso atual, symlinks e variáveis que definem o destino. Idade, falta de
  referência ou estar no `.gitignore` não provam que algo pode ser apagado.
- Ensaios em containers usam o Docker local via `sudo`. Remova somente os containers e as
  imagens que a tarefa criou, por nome ou ID. `docker system prune`, `docker volume prune`,
  `git clean -fdx` e varreduras de caches ou do diretório pessoal exigem autorização
  explícita para o escopo inventariado.
- Worktrees temporários da tarefa: confira alterações e arquivos não versionados, encerre
  processos que os usem e remova com `git worktree remove`, sem forçar. Não apague branches
  nem worktrees de terceiros.
- Antes de downloads ou imagens volumosas, confira o espaço livre no volume de destino. Se
  houver risco de esgotar o disco, pare e informe. No encerramento, relate o que foi limpo e
  o que ficou, com o motivo.
