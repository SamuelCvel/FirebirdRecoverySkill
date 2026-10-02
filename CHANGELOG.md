# Changelog

Todas as mudanças notáveis a este projeto são documentadas aqui.

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/); versionamento segue [SemVer](https://semver.org/lang/pt-BR/).

## [1.3.0] — 2026-10-02

### Added

- **Pump automático por chave** (`Salvage-TableByTable -Action pump -Auto`): copia a tabela inteira por chave primária via EDS e, quando uma janela falha por página danificada, encolhe a janela (→ 50 → 5 → 1), pula **só** as linhas ilegíveis e segue. A próxima chave legível é achada por sondagem exponencial + bissecção; chave composta é decomposta por níveis (`A = a AND B > b`, depois `A >= a+1` — no 2.5, `A > a` num índice composto ainda lê as linhas de `A = a`); chave numérica tenta a lacuna até `-MaxGap`. As faixas copiadas e perdidas vão para um CSV (`-ReportFile`). Erro que **não** é de página (SQL, login, constraint no destino) para o pump em vez de pular dados. Chave de texto: para na região ruim e indica o `-StartKey` para retomar. Conferido contra um gabarito tirado do `RDB$DB_KEY`: o destino fica com **exatamente** as linhas da origem menos as das páginas zeradas (chave inteira, composta — inclusive página na troca de prefixo — e texto).
- **Testes** (`tests/Run-Tests.ps1`, sem módulo externo, Windows PowerShell 5.1 e PowerShell 7):
  - 21 unitários, sem Firebird: parser do `gstat -h`, dicas de header, varredura de page_size em arquivos sintéticos, classificação de erro de página, resumo de erro do isql/EDS, credenciais pelo ambiente, empacotador e trava de termos sensíveis.
  - 35 de integração (`-Integration`) no Firebird 2.5: todos os scripts e SQLs da skill sobre cópias do `EMPLOYEE.FDB` e bancos sintéticos com corrupção provocada (header, arquivo e `.fbk` truncados, página zerada, FK composta órfã), numa pasta temporária.
- **Evals**:
  - 5 casos de qualidade em `evals.json`: 170 erros no gfix com o sistema funcionando; FK órfã (salvar e perguntar antes do `DELETE`); `single-user maintenance` depois de restore falho; restore só de metadata com `-m`; corrupção massiva (parar cedo).
  - 10 casos de **gatilho** para `claude plugin eval` em `evals/`: 6 em que a skill deve disparar (inclusive pedido em inglês) e 4 quase-acertos em que não deve (PostgreSQL, SQLite, SQL de relatório, stored procedure).
- **CI**: PSScriptAnalyzer (severidade Error; exceções justificadas em `PSScriptAnalyzerSettings.psd1`) e testes unitários nos dois PowerShell; actions `checkout`/`upload-artifact` v7.

### Changed

- **`Salvage-TableByTable`**: o erro mostrado é a causa real do Firebird (ex.: `checksum error on database page 750`), não o eco do comando e o caminho do `.sql` temporário (`Get-FbErrorSummary` no módulo comum).
- **`_FirebirdCommon`**: `ConvertFrom-FbGstatHeader` separado do `Get-FbHeaderInfo`, para testar o parser sem Firebird.
- **`Demo-CorrupcaoHeader`**: exit codes iguais aos dos outros scripts (cancelado = 4; header já inválido = 1; correção sem efeito = 2).
- Procedure 06 (seção 3.a) e SKILL.md documentam o `-Auto`; README com testes, evals e roadmap.

## [1.2.0] — 2026-10-02

### Added

- **`scripts/Test-FirebirdHealth.ps1`** — health check em 4 lentes com relatório `.md`/`.json`: estado e header (forced writes, % do limite de transações, OIT parado, truncamento), validação online (`fbsvcmgr action_validate`, com usuários conectados) ou `gfix -v -full`, backup **sem** `-ignore` (com reteste usando `-ignore` se falhar), objetos, índices não ativos, registros por tabela, FKs órfãs e comparação com referência. `-SnapshotCopy` faz a cópia consistente por `nbackup -L/-N/-F` e analisa a cópia. Testado em 9 cenários (saudável, página ruim, FK órfã, shutdown, snapshot, referência).
- **`scripts/Swap-ProductionDatabase.ps1`** — troca segura em produção: pré-checagens (dialect, page size, índices, candidato online, espaço), isolamento por serviço ou `gfix -shut full`, open exclusivo, rename com data (nunca apaga), rollback automático, conferência final, `-WhatIf`/`-Confirm`.
- **`scripts/Get-FirebirdEnvironmentReport.ps1`** — evidências de causa raiz, somente leitura: arquitetura/versão, `firebird.conf`, banco em rede, forced writes, saúde do disco, eventos de disco/NTFS, desligamentos inesperados, Defender, `firebird.log`.
- **`templates/relatorio-tecnico.md`** e **`templates/mensagem-cliente.md`**.
- **Plugin e marketplace do Claude Code** (`.claude-plugin/plugin.json` e `marketplace.json`): `/plugin marketplace add SamuelCvel/FirebirdRecoverySkill` + `/plugin install firebird-recovery@samuelcvel`.
- **CI** (`.github/workflows/ci.yml`): consistência do repositório, termos sensíveis, validação do frontmatter e pacote `.skill` publicado como asset de cada Release.
- `tools/Test-Repository.ps1` (JSON, nomes, versão, sintaxe dos `.ps1`, referências a arquivos nas docs), `tools/Build-SkillPackage.ps1` (empacotador próprio com validação YAML), `tools/Install-DevLink.ps1` (junction da skill instalada para o repositório).

### Changed

- **Estrutura:** `skill/` → `skills/firebird-recovery/` (o nome da pasta passa a ser o nome da skill, como a especificação exige). `dist/` sai do git: o `.skill` vem das Releases ou do `Build-SkillPackage.ps1`.
- **Frontmatter** com `license`, `compatibility` e `metadata.version` (só chaves aceitas pelo upload do claude.ai).
- **Módulo comum**: localiza o Firebird sozinho (variável `FIREBIRD`, registro, caminhos padrão); credenciais vão para gbak/gfix/isql/fbsvcmgr por `ISC_USER`/`ISC_PASSWORD` **só durante a chamada** (a senha não aparece mais na linha de comando nem na lista de processos); `-User`/`-Password` usam essas variáveis como padrão.
- **`Diagnose-FirebirdHeader`** mostra dicas de saúde do header (forced writes, shutdown, nbackup, contador de transações, OIT parado).
- SKILL.md, procedures 01/02/04/08 e README apontam para os scripts novos e para os templates.

## [1.1.1] — 2026-10-02

Release de **correções**. Tudo que a skill afirma sobre comandos, flags e comportamento foi **verificado no Firebird 2.5.9**: ajuda das ferramentas, código-fonte do 2.5 (`burpswi.h`, `aliceswi.h`, `ods.h`) e testes em cópias do banco de exemplo `EMPLOYEE.FDB`, inclusive com corrupção provocada (página de dados zerada, header com bit trocado, arquivo truncado, `.fbk` truncado, FK composta órfã).

### Fixed — comandos que falhavam ou faziam outra coisa

- **`gbak -mo` não é "só metadata"**: é `-mode read_only|read_write` (e consome o argumento seguinte). Metadata é `-m`/`-meta_data`. Corrigido no cheatsheet, nas procedures 05 e 06, na tabela de erros e no `Restore-Clean -MetadataOnly`.
- **`gbak -l` / `-t`**: `-l` = ignora limbo (não "inclui shadows"); `-t` = transportable (não "inclui limbo"). `-r` no 2.5 é RECREATE (só sobrescreve com `-r o`).
- **Abreviações perigosas documentadas**: no gfix 2.5, `-m` é **mend**; `-pa` no gbak é **page_size**; `-u` é `-use`. O gfix exige a ação primeiro (`-v -full`, não `-full -v`).
- **`hdr_flags`**: `0x100` é **dialect 3** (não read-only). A procedure 03 mandava **zerar o campo de flags**, o que transformaria o banco em dialect 1 e desligaria forced writes — agora só os bits de shutdown/nbackup são limpos (snippet testado). Bits medidos: `0x2` forced writes, `0x20` no reserve, `0x80`/`0x1000`/`0x1080` shutdown multi/full/single, `0x200` read-only, `0x400` backup lock.
- **Offsets do header** a partir de `0x3C` corrigidos (campos de 2 bytes; `hdr_end` em `0x42`, OST em `0x4C`, clumplets em `0x60`); OIT/OAT rotulados certo.
- **`gfix -shut -force 0` sem modo é `multi`**: SYSDBA continua conectando. Scripts e procedures passam a usar `-shut full` (mexer no arquivo) ou `-shut single` (manutenção).
- **`RDB$INDEX_INACTIVE`**: índice ativo é NULL **ou** 0; filtros passam a usar `COALESCE(...,0)` (o `= 1` perdia o estado 3; o `= 0` perdia os ativos).
- **`GEN_ID(EVAL(...))`** não existe — trocado por `EXECUTE BLOCK` + `EXECUTE STATEMENT`.
- **`sql/encontrar-paginas-ruins.sql` removido**: usava `MON$TABLE_STATS` (FB 3+) e não rodava no 2.5. Substituído por `sql/sondar-tabelas.sql`.
- **`sql/validar-fk-orfas.sql` reescrito**: a versão anterior validava FK composta coluna por coluna e **não achava** órfãs reais (provado com o par `(2,20)`); agora é um `EXECUTE BLOCK` com todas as colunas e regra de NULL igual à do engine.
- **`sql/gerar-script-salvage.sql` reescrito**: gerava `INSERT ... SELECT` entre bancos (não existe). Agora gera a cópia completa via `EXECUTE STATEMENT ... ON EXTERNAL`, tratando triggers, generators e **CHECKs** (no 2.5 não dá para desligar trigger de CHECK; o script remove e recria a constraint, como o gbak). Testado no EMPLOYEE: contagens, objetos, generators e FKs idênticos à origem.
- **Docs que citavam o que não existia**: `-SourceDatabase`/`-ExcludeTables`/`-CountOnly`, seção "Caminho FB 2.5" (agora existe), "todos os scripts têm `-WhatIf`", "pacote assinado".
- **"`SET TERM ;^` é inválido"** era impreciso: é válido para **sair** do modo `^`; usado para **entrar**, o isql engole os comandos seguintes **sem erro**.

### Fixed — scripts

- **Windows PowerShell 5.1**: com `$ErrorActionPreference='Stop'`, qualquer linha de stderr de gstat/gfix/gbak/isql virava erro terminante — o `Diagnose` morria exatamente com header corrompido e o `Salvage-Backup` exatamente quando o backup falhava. Novo `scripts/_FirebirdCommon.ps1` (`Invoke-FbNative`, `Invoke-FbIsql`); gbak passa a gravar o log com `-y`.
- **Exit codes**: `Write-Error` + `exit N` sempre saía com 1. Agora os códigos documentados (2, 3, 4) chegam a quem chamou.
- **Execução não-interativa**: `Read-Host` quebrava sem console e "Cancelado" saía com exit 0. `Salvage-Backup -Force`, `Restore-Clean -Replace`, `Repair`/`Demo` com `-WhatIf`/`-Confirm:$false` (o `-Force` do Repair, que também desligava a trava de header válido, virou `-AllowValidHeader`).
- **`Salvage-Backup`**: identifica a tabela que quebrou pelos índices escritos depois do último `records written` (a versão anterior não achava; a heurística por "writing table" apontava a tabela errada); dica de `-skip_data` só para FB 3+; senha mascarada no que imprime.
- **`Restore-Clean`**: avisa quando o restore falho deixa o destino em `single-user maintenance` (reproduzido).
- **`Repair-FirebirdHeader`**: para se sidecar e varredura discordarem; aceita `-PageSize`; grava os 2 bytes num único open exclusivo.
- **`Diagnose-FirebirdHeader`**: detecta arquivo **truncado** (tamanho não múltiplo do page_size, exit 4), banco de FB 3+ e forced writes desligado.
- **`Firebird-Service`**: descobre os serviços pelo executável, `-Mode full|single|multi`, confere se start/stop funcionou.
- **`Salvage-TableByTable`**: o modo `pump` gerava janelas `FIRST/SKIP` (o SKIP relê as linhas puladas e bate sempre na página ruim); agora copia uma janela **por chave primária** via EDS (PK simples ou composta). `list` faz o inventário numa execução só.
- **`Demo-CorrupcaoHeader`**: `-Action setup` cria o banco de treino a partir do `EMPLOYEE.FDB` de exemplo.

### Added — conhecimento verificado

- Validação online (`fbsvcmgr action_validate`, 2.5.4+) com usuários conectados; `gfix -v` exige acesso exclusivo e **sai com 0 mesmo achando erro**.
- `connection lost to database` depois de restore = banco em `single-user maintenance` recusando a 2ª conexão (a v1.1.0 atribuía a um JOIN pesado).
- isql: `-o`/`OUTPUT` **anexam**; `-b` só funciona com `-i`.
- Cópia consistente de banco vivo com `nbackup -L`/`-N` (+ `-F` na cópia); credenciais por `ISC_USER`/`ISC_PASSWORD`.
- Procedure 06 reescrita: Caminho A (salvar por chave → dropar → gbak → recriar), Caminho B (copiar tudo por EDS), leitura por `RDB$DB_KEY` como último recurso.
- Procedure 04: o padrão "todas as janelas depois de N falham" com `FIRST/SKIP` é artefato do SKIP — não prova perda grande.
- `tools/Test-SensitiveTerms.ps1` + `.githooks/pre-commit`: bloqueia termos sensíveis (lista local em `.git/info`) inclusive dentro do `.skill`.

### Security

- Nomes reais de tabela num exemplo da procedure 04 trocados por nomes genéricos; histórico da 1.1.0 reescrito.

## [1.1.0] — 2026-08-27

### Added

- **Novo SQL helper** `sql/contagem-registros-por-tabela.sql` — `EXECUTE BLOCK` que faz `COUNT(*)` linha-por-tabela e emite `NOMETABELA|QTD`, com `-1` em tabelas que dão erro (não aborta o inventário). Ideal para diff antes/depois provando "0 perda" de dados após restore.

### Changed / Fixed (aprendizados incorporados de health check em banco de produção de 1,6 GB)

- **procedure 04 (páginas corrompidas)** — nova subseção "O que o `firebird.log` diz em paralelo" com os padrões `Record N has bad transaction K in table T` e `Page N is an orphan`. Também novo **achado empírico documentado**: um banco pode reportar 170 erros no `gfix -v -full` e ainda ser 100% recuperável via `gbak -b -ignore` + restore (checksum cosmético). **Sempre testar a lente 3 antes de escalar a procedure destrutiva.**
- **procedure 05 (índices e restrições)** — 2 novas seções:
  - **4b**: documenta `RDB$INDICES.RDB$INDEX_INACTIVE = 3` (estado "cannot commit / pending" após restore que quebrou em FK). Query correta usa `!= 0`, não `= 1`.
  - **4c**: workflow completo de 8 passos "restore quebrou em FK → limpeza → validação", com backup forense antes do `DELETE`. Inclui aviso sobre `SQLSTATE 08006 - connection lost to database` em JOINs pesados em `RDB$` em banco degradado; usar `SHOW TABLE <nome>` como alternativa.
- **procedure 08 (pós-recuperação)** — nova **seção 0** obrigatória antes das lentes: verificar se banco não está em `single-user maintenance` (comum após restore com FK violation). Se estiver, `gfix -online` primeiro — senão `gbak` reclama `bad parameters on attach or create database`.
- **references/codigos-erro-firebird.md** — 2 novas entradas: `bad parameters on attach or create database` (banco em single-user) e `SQLSTATE 08006 connection lost` em JOIN complexo (usar SHOW TABLE).

### Nota de versão

Nenhuma quebra de compatibilidade em relação à 1.0.0. Adição de conhecimento + novo SQL helper. Consumidores que já dependem dos comandos e procedures existentes continuam funcionando sem ajuste.

## [1.0.0] — 2026-06-05

### Added

- Versão inicial da skill `firebird-recovery` para Claude Code.
- **SKILL.md** com tabela de triagem por sintoma e princípios não-negociáveis.
- **8 procedures** cobrindo do diagnóstico inicial ao pós-recuperação:
  - `01-triagem.md` — roteiro de entrevista quando o sintoma é ambíguo.
  - `02-protocolo-seguranca.md` — cópia, sidecars, estado do serviço, isolamento com `gfix -shut`.
  - `03-header-corrompido.md` — page_size inválido, ODS, flags (caso clássico).
  - `04-paginas-corrompidas.md` — checksum, wrong page type, `-mend`; inclui **sinal de parar cedo** para corrupção massiva.
  - `05-indices-restricoes.md` — restore em 2 fases (`-i` `-o`), limpeza de duplicatas.
  - `06-tabelas-individuais.md` — drop+recreate manual em FB 2.5, pump em janelas SKIP/FIRST.
  - `07-transacoes-limbo.md` — `gfix -commit`/`-rollback`/`-prompt`, default conservador rollback.
  - `08-pos-recuperacao.md` — verificação 4-lentes + reintegração em produção.
- **7 scripts PowerShell**:
  - `Diagnose-FirebirdHeader.ps1` — leitura somente-leitura + scan de page_size real via checksum 12345.
  - `Repair-FirebirdHeader.ps1` — patch reversível com sidecar `.hdrbak`; recusa operar em header válido.
  - `Salvage-Backup.ps1` — wrapper de `gbak -b -v -ignore -g` com log e análise de erros.
  - `Restore-Clean.ps1` — wrapper de `gbak -c -v` com verificação 4-lentes pós-restore.
  - `Salvage-TableByTable.ps1` — inventário, modo skip-bad-table (com detecção de FB 2.5 vs 3.0+), modo pump.
  - `Firebird-Service.ps1` — status/start/stop do serviço + `gfix -shut`/`-online` para isolar 1 banco.
  - `Demo-CorrupcaoHeader.ps1` — demonstração reversível corrupt+diagnose+fix para treinamento.
- **4 SQL helpers** (`contagem-objetos`, `encontrar-paginas-ruins`, `validar-fk-orfas`, `gerar-script-salvage`).
- **4 references** (`ods11-header-layout`, `codigos-erro-firebird`, `gbak-gfix-gstat-flags`, `checklist-pos-recuperacao`).
- **3 casos de teste** em `evals/evals.json` com assertions por caso.

### Aprendizados incorporados

Vindos de casos reais (banco pequeno com corrupção de header + banco de 11 GB com múltiplos sítios de corrupção):

- `gbak -skip_data` é **Firebird 3.0+** e NÃO existe no 2.5. Referência e script corrigidos.
- `gfix` pode falhar no attach com `cannot find tip page` enquanto `gbak` atacha (caminhos diferentes no engine).
- `gbak -ignore` cobre só **checksum**; não bypass `wrong page type` nem `I/O error / EOF`.
- **Sinal de parar cedo** (procedure 04 seção 5b): 3+ sítios de corrupção independentes indicam falha de hardware — recuperar de `.fbk` antigo é mais barato e seguro que insistir in-place.
- Armadilha do `SET TERM ;^` (inválido; documentado como pitfall na procedure 06).
