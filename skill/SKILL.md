---
name: firebird-recovery
description: Diagnostica e recupera bancos Firebird/InterBase 2.x (.fdb, .gdb, .ib) corrompidos ou inacessíveis e valida bancos em produção (health check). ACIONAR quando (a) o usuário pedir para recuperar/consertar/diagnosticar/validar banco Firebird; (b) sintomas como "unable to allocate memory", "wrong page type", "checksum error", "I/O error", "database shutdown", "transaction in limbo", "connection lost to database", "cannot find tip page"; (c) falha de gstat/gfix/gbak/isql; (d) suspeita de corrupção em .fdb/.gdb/.ib mesmo sem pedir a skill. Cobre header corrompido (page_size, ODS, flags), páginas com checksum/page type inválido, índices/FKs quebrando restore, salvamento tabela-a-tabela quando o gbak para (no FB 2.5, sem -skip_data, por cópia via EDS lendo pela chave), transações em limbo, sinal de parar cedo em corrupção massiva, validação em 4 lentes e troca segura em produção. Cada procedure traz passo-a-passo com fallback explícito. Use também para treinamento/demo sobre corrupção em Firebird.
---

# Firebird Recovery (Firebird 2.5 / ODS 11.2)

Esta skill orquestra a recuperação de bancos Firebird/InterBase corrompidos e a validação de bancos em uso. Cobre desde a corrupção de 1 byte no header (caso real) até falhas que exigem extração tabela-a-tabela. Todo procedimento tem **fallback explícito** para quando a ferramenta principal falha.

**Pasta da skill:** `${CLAUDE_SKILL_DIR}`. Todos os caminhos `scripts/...`, `sql/...`, `procedures/...` e `references/...` são relativos a ela — nas procedures, `<SKILL>` significa esta pasta. O diretório de trabalho normalmente é a pasta do banco, então chame os scripts pelo caminho completo:

```powershell
& "${CLAUDE_SKILL_DIR}/scripts/Diagnose-FirebirdHeader.ps1" -Database "<banco>"
```

Foco: **Firebird 2.5 (ODS 11.2)**, verificado no 2.5.9. Muito vale para FB 2.0/2.1; FB 3.0+ (ODS 12/13) tem on-disk diferente — confira o ODS antes de aplicar.

Idioma: responda no idioma do usuário (o material desta skill está em pt-BR).

---

## Princípios não-negociáveis

Estes 5 princípios precedem qualquer comando. Quebrá-los já piorou recuperações antes.

1. **Nunca opere sobre o original.** Primeiro ato é sempre uma cópia de segurança. O arquivo corrompido é evidência forense — você pode precisar dele de novo se o primeiro caminho de recuperação falhar.
2. **Diagnostique antes de tocar.** Identifique a *classe* da corrupção (header? página? índice? metadata?) antes de escolher a ferramenta. Aplicar `gfix -mend` num header corrompido, por exemplo, não funciona porque o `gfix` nem consegue atachar.
3. **Reversibilidade.** Toda alteração binária direta no arquivo grava um sidecar (`.hdrbak`, `.flagsbak`) com os bytes originais. Se a correção for pior que o problema, dá para voltar.
4. **Quatro lentes na verificação.** Sucesso só é declarado quando `gstat -h`, `gfix -v -full`, `gbak -b` (backup completo) e `isql` (contagens conferem) **todos** passam. Cada um detecta um tipo diferente de problema; um sozinho não basta.
5. **Menos invasivo primeiro.** Esta ordem é deliberada: `gfix -shut` (banco) antes de `Stop-Service` (servidor); `-ignore` antes de `-mend`; `gbak` backup+restore antes de patch binário; extração via `isql` antes de mexer em bytes.

---

## Primeiro: qual é o pedido?

| Pedido | Caminho |
|---|---|
| "O banco funciona, quero **validar** / health check" | **08** (as 4 lentes; com usuários conectados use a validação online e a cópia por `nbackup`, procedure 02 seção 1) |
| "O banco **não abre** / dá erro" | tabela de triagem abaixo |
| Sintoma ambíguo, vários erros | **01-triagem** |

## Triagem rápida (sintoma → procedure)

| Sintoma observado | Causa típica | Procedure |
|---|---|---|
| `gstat -h` retorna *"unable to allocate memory from operating system"* | page_size inválido no header | **03-header-corrompido** |
| ODS version inválido / `not a valid database` | header destruído | **03-header-corrompido** |
| ODS 12/13 (`0x800C`/`0x800D`) | banco de Firebird 3+ — não é corrupção | fora do escopo; use as ferramentas da versão certa |
| `wrong page type`, `checksum error`, `page X is of wrong type` | corrupção em página de dados/índice/PIP | **04-paginas-corrompidas** |
| `consistency check` em página específica | mesma — corrupção de página | **04-paginas-corrompidas** |
| `gfix -v` mostra **centenas de erros**, mas o sistema funciona | quase sempre cosmético | **04** seção 2 — teste o `gbak -ignore` (lente 3) antes de escalar |
| `gbak -c` (restore) falha em índice/constraint/FK | dado inconsistente impede recriar índice único / FK | **05-indices-restricoes** |
| `record format not found` durante restore | metadata vs dados divergiram | **05-indices-restricoes** |
| `gbak -b` para numa tabela específica com erro | uma tabela tem páginas ruins; outras estão ok | **06-tabelas-individuais** |
| `transaction is in limbo`, `outstanding limbo transaction` | crash de servidor durante 2PC ou cópia indevida | **07-transacoes-limbo** |
| `connection lost to database` / `bad parameters on attach` depois de restore | banco ficou em `single-user maintenance` (só 1 conexão) | **08** seção 0 (`gfix -online`) |
| `database shutdown`, `not available`, `lock conflict on no wait transaction` | banco offline ou serviço/estado, não corrupção | **02-protocolo-seguranca** (seção 3) |
| `I/O error during read/write` em offset específico, ou arquivo com tamanho que não é múltiplo do page_size | disco com setor ruim ou arquivo truncado | **02-protocolo-seguranca** → **04-paginas-corrompidas** |
| Sintoma ambíguo ou múltiplos erros misturados | precisa entrevistar | **01-triagem** |

Se houver dúvida, **sempre comece por 01-triagem** para conduzir a entrevista e levantar artefatos antes de escolher o caminho.

---

## Fluxo padrão de recuperação

```
01-triagem (se sintoma incerto)
    ↓
02-protocolo-seguranca       (cópia, isolamento, servico/estado)
    ↓
03 ou 04 ou 05 ou 06 ou 07   (procedimento específico)
    ↓
Salvage-Backup (gbak -b -ignore -g)        ← scripts/Salvage-Backup.ps1
    ↓
Restore-Clean (gbak -c)                    ← scripts/Restore-Clean.ps1
    ↓
08-pos-recuperacao            (4 lentes + reintegração)
```

---

## Procedures (procedures/)

Carregue **apenas a procedure** correspondente ao sintoma — não leia todas. Cada uma é independente.

| Arquivo | Quando usar | O que entrega |
|---|---|---|
| `procedures/01-triagem.md` | sintoma ambíguo / múltiplos erros | roteiro de entrevista, leitura inicial do header, decisão da próxima procedure |
| `procedures/02-protocolo-seguranca.md` | **sempre, antes de qualquer escrita** | cópia (inclusive de banco vivo via nbackup), sidecars, modos de shutdown, credenciais |
| `procedures/03-header-corrompido.md` | page_size inválido ("unable to allocate"), ODS/flags/sequence | inspeção hex, scan de page_size real, patch reversível |
| `procedures/04-paginas-corrompidas.md` | checksum/page type errados, I/O errors | mapear todas as tabelas ruins, `gbak -ignore`, `-mend`, hardware, sinal de parar cedo |
| `procedures/05-indices-restricoes.md` | restore para por FK/PK/unique | restore em 2 fases (`-inactive`/`-one_at_a_time`), órfãs (inclusive FK composta), ativação |
| `procedures/06-tabelas-individuais.md` | gbak para numa tabela específica | Caminho A (salvar → dropar → gbak) e B (copiar tudo por EDS), extração por chave, `RDB$DB_KEY` |
| `procedures/07-transacoes-limbo.md` | "transaction in limbo" | `gfix -list`, `-commit`/`-rollback` (inclusive `all`), `gbak -limbo` |
| `procedures/08-pos-recuperacao.md` | restore pronto **ou** health check | 4 lentes, contagens, órfãs, troca em produção e rollback |

---

## Scripts (scripts/)

Scripts PowerShell (Windows PowerShell 5.1 e PowerShell 7). Cada um tem ajuda completa: `Get-Help <script> -Full`.

| Script | Função | Quando chamar |
|---|---|---|
| `scripts/Diagnose-FirebirdHeader.ps1` | leitura RO do header + scan de page_size real + checagem de truncamento + `gstat -h` | sempre, primeiro passo de qualquer suspeita |
| `scripts/Repair-FirebirdHeader.ps1` | corrige page_size por `-PageSize`, sidecar `.hdrbak` ou scan (para se divergirem); reversível | procedure 03 |
| `scripts/Salvage-Backup.ps1` | `gbak -b -v -ignore -g` com log, análise de erros e **tabela que quebrou** | depois do diagnóstico; lente 3 |
| `scripts/Restore-Clean.ps1` | `gbak -c -v` com log + verificação pós-restore + aviso de banco em manutenção | depois do salvage backup |
| `scripts/Salvage-TableByTable.ps1` | `list` (contagem de todas as tabelas), `pump` (copia uma janela por chave via EDS), `skip-bad-table` (só FB 3+) | procedure 06 |
| `scripts/Firebird-Service.ps1` | status/start/stop do serviço; `gfix -shut full\|single\|multi` / `-online` para isolar 1 banco | qualquer escrita binária no arquivo; troca em produção |
| `scripts/Demo-CorrupcaoHeader.ps1` | demonstração reversível (setup com o banco de exemplo, corrompe, diagnostica, corrige) | treinamento de equipe |
| `scripts/_FirebirdCommon.ps1` | funções compartilhadas (carregado pelos outros) | — |

### Convenções

- **Parâmetros:** `-User`/`-Password` (padrão SYSDBA/masterkey) e `-GstatPath`/`-GfixPath`/`-GbakPath`/`-IsqlPath` (padrão `C:\Program Files\Firebird\Firebird_2_5\bin\`). Se a senha não for a padrão, pergunte — nunca tente adivinhar.
- **Escrita com confirmação:** `Repair-FirebirdHeader` e `Demo` (corrupt/fix) pedem confirmação. Em execução não-interativa, **mostre o plano ao usuário** e passe `-Confirm:$false`; `-WhatIf` mostra sem gravar. `Salvage-Backup` (`-Force`) e `Restore-Clean` (`-Replace`) não sobrescrevem nada sem a chave.
- **Windows PowerShell 5.1:** chame de dentro de uma sessão (`& "<script>" ...`). Via `powershell -File`, o `-Confirm:$false` não é convertido.
- **Exit codes:** 0 sucesso; 1 parâmetro inválido/recusado; 2 ferramenta falhou; 3 lock/permissão/serviço; 4 nada foi feito (destino existe, `-WhatIf`, confirmação negada). O `Diagnose` tem códigos próprios (ver ajuda).
- **Logs** ao lado do banco/backup: `<arquivo>.log`, `<destino>.restore.log`. **Sidecars**: `<banco>.hdrbak`, `<banco>.pre-repair.hdrbak`.
- **Credenciais fora da linha de comando:** `$env:ISC_USER`/`$env:ISC_PASSWORD` valem para gbak, gfix, isql, nbackup e fbsvcmgr. Os scripts mascaram a senha no que imprimem.

### Armadilhas do isql (verificadas no 2.5.9)

- `-o arquivo` e `OUTPUT arquivo` **anexam** — apague o arquivo antes de gerar de novo.
- `-b` só para no erro com `-i arquivo` (com script por pipe o isql continua).
- `SET TERM ^ ;` para entrar e `SET TERM ; ^` para sair. `SET TERM ;^` usado para **entrar** faz o isql engolir os comandos seguintes sem erro.
- `RDB$INDEX_INACTIVE`: NULL ou 0 = ativo, 1 = inativo, 3 = pendente — filtre com `COALESCE(..., 0)`.

---

## SQL helpers (sql/)

| Script | Para que serve |
|---|---|
| `sql/contagem-objetos.sql` | conta tabelas/views/procedures/triggers/generators/constraints/índices (ativos, inativos, pendentes) — comparar antes/depois |
| `sql/contagem-registros-por-tabela.sql` | `TABELA\|QTD` de todas as tabelas (`-1` = ilegível); diff antes/depois prova "0 perda" |
| `sql/sondar-tabelas.sql` | lê **todas** as tabelas por inteiro (colunas e BLOBs) e lista as ilegíveis numa passada — conta os sítios de corrupção |
| `sql/validar-fk-orfas.sql` | `FK\|FILHA\|PAI\|ORFAS` para todas as FKs, inclusive compostas |
| `sql/gerar-script-salvage.sql` | gera o script que copia todos os dados da origem para um destino com o mesmo schema via EDS (CHECKs, triggers e generators tratados) |

---

## Referências (references/)

Consulta passiva. Carregue só quando a procedure pedir.

- `references/ods11-header-layout.md` — layout byte-a-byte da página 0 e bits de `hdr_flags` (medidos no 2.5.9).
- `references/codigos-erro-firebird.md` — mensagem de erro → causa provável → procedure.
- `references/gbak-gfix-gstat-flags.md` — cheatsheet verificado (abreviações perigosas, modos de shutdown, validação online, nbackup).
- `references/checklist-pos-recuperacao.md` — lista de verificação antes de devolver o banco para produção.

---

## Quando pedir ajuda humana (parar e perguntar)

Não automatize por automatizar. Pare e converse com o usuário quando:

1. **Não tem backup recente.** Antes de aplicar `-mend` ou patch binário, confirme que o usuário tem outra cópia. Se for o único arquivo, redobre o cuidado.
2. **Banco está em produção ativa.** Confirme janela de manutenção; ofereça `gfix -shut` por banco em vez de parar o serviço inteiro.
3. **Sintomas de hardware** (`I/O error`, setores ruins, RAM ECC reportando). Pode ser inútil recuperar sem trocar o hardware primeiro.
4. **Perda de registros (>0,1%) ou órfãs a apagar.** Mostre os números e o dump forense; a decisão é do usuário.
5. **Senha do SYSDBA não é a padrão.** Não force; peça.

---

## Compatibilidade

Verificado em **Firebird 2.5.9 SuperServer, Windows 11**, com Windows PowerShell 5.1 e PowerShell 7. Boa parte funciona em 2.0/2.1 (mesmo ODS 11.x). Os modos de shutdown (`full`/`single`/`multi`) e o EDS já existem no 2.5; a validação online exige 2.5.4+. Para FB 3.0+ (ODS 12/13) o on-disk muda (sem checksum de página) e o gbak ganha `-skip_data` — trate como outro produto.

InterBase 7.x compartilha boa parte da arquitetura de página, mas comandos podem diferir — trate como semelhante, não idêntico.
