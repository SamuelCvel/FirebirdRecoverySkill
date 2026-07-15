# Changelog

Todas as mudanças notáveis a este projeto são documentadas aqui.

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/); versionamento segue [SemVer](https://semver.org/lang/pt-BR/).

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
