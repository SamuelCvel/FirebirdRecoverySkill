# Changelog

Todas as mudanças notáveis a este projeto são documentadas aqui.

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/); versionamento segue [SemVer](https://semver.org/lang/pt-BR/).

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
