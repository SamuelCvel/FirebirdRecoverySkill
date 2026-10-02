# 08 — Pós-recuperação: validação 4-lentes e reintegração

Esta procedure roda **depois** que o banco recuperado existe (saída de qualquer das procedures 03-07) — e também serve sozinha como **health check** de um banco que está funcionando. Objetivo: provar que está consistente antes de devolver para produção, e conduzir a substituição com segurança.

Pulando esta procedure: já houve mais de um caso de banco "recuperado" voltar para produção e quebrar 48h depois porque uma constraint estava silenciosamente desabilitada ou faltava 0,5% dos registros. Validar é barato; replicar incidente é caro.

> `<SKILL>` = pasta da skill (informada no SKILL.md). `$fb` = `C:\Program Files\Firebird\Firebird_2_5\bin`.

## Sumário

0. [Pré-requisito: banco fora de manutenção](#0-pré-requisito-banco-fora-de-manutenção)
1. [As 4 lentes](#1-as-4-lentes)
2. [Smoke test na aplicação](#2-smoke-test-na-aplicação)
3. [Plano de reintegração](#3-plano-de-reintegração)
4. [Pós-deploy](#4-pós-deploy)
5. [Documentar o incidente](#5-documentar-o-incidente)
6. [Quando NÃO declarar sucesso](#6-quando-não-declarar-sucesso)

## 0. Pré-requisito: banco fora de manutenção

Um restore que termina com erro (FK, constraint) costuma deixar o banco em **`single-user maintenance`** — visível em `gstat -h` como `Attributes: force write, single-user maintenance`. Nesse estado só cabe **uma** conexão: a segunda (outro isql, o gbak da lente 3) recebe `connection lost to database` (SQLSTATE 08006); outras ferramentas reclamam `bad parameters on attach or create database`. Em `full shutdown` ninguém conecta.

Antes de rodar as lentes, tire o banco desse modo:

```powershell
& "$fb\gfix.exe" -online -user SYSDBA -password <senha> "<RECUPERADO.FDB>"
```

Confirme com `gstat -h`: `Attributes` deve mostrar só `force write` (sem `maintenance`, sem `shutdown`).

## 1. As 4 lentes

Cada uma cobre um tipo de problema. Sucesso só é declarado quando **todas** passam.

**Automatizado:** o `Test-FirebirdHealth.ps1` roda as 4 lentes e gera `<banco>.health-<data>.md`/`.json` (exit 0 = nenhuma FALHA):

```powershell
# banco recuperado (ninguém usando): validação completa + comparação com o original
& "<SKILL>\scripts\Test-FirebirdHealth.ps1" -Database "<RECUPERADO.FDB>" -Validation full -ReferenceDatabase "<cópia do original>"

# banco em produção, com usuários conectados: cópia consistente por nbackup + validação online
& "<SKILL>\scripts\Test-FirebirdHealth.ps1" -Database "<PRODUCAO.FDB>" -SnapshotCopy "<pasta de análise>\copia.fdb"
```

A lente 3 do script faz o backup **sem** `-ignore` (é o backup que a rotina faria); se falhar, repete com `-ignore` para dizer se os dados ainda saem. As seções abaixo explicam cada lente e servem para rodar à mão.

### Lente 1 — gstat (header)

```powershell
& "$fb\gstat.exe" -h "<RECUPERADO.FDB>"
```

Esperado:
- `Page size` válido (1024/2048/4096/8192/16384) e `ODS version 11.2`.
- `Flags 0` — essa linha é o `pag_flags` da página 0, não o estado do banco.
- `Attributes: force write` **presente** e sem `shutdown`/`maintenance`/`read only`/`backup lock`. Sem `force write` = forced writes desligado: ligue com `gfix -write sync` antes de produção.
- `Database dialect` **igual ao do original** (normalmente 3).
- `Next transaction` baixo depois de restore (o contador recomeça); no original, compare com o limite do 2.5 (2.147.483.647).

### Lente 2 — gfix -v -full (páginas e registros)

O gfix de validação exige **acesso exclusivo**: com outra conexão aberta ele falha com `secondary server attachments cannot validate databases`. No recuperado (ninguém usa ainda) basta rodar; num banco em uso, use `gfix -shut single -force 0` antes ou a validação online.

```powershell
& "$fb\gfix.exe" -v -full -user SYSDBA -password <senha> "<RECUPERADO.FDB>" 2>&1 | Tee-Object "<RECUPERADO>.gfix.log"
```

Esperado: **saída vazia**. O gfix devolve **exit 0 mesmo quando acha erro** (imprime `Summary of validation errors` / `Number of ... errors : N`), então olhe a saída, não o exit code. Qualquer linha é sinal de problema persistente — volte para procedure 04.

Com usuários conectados (health check em produção), a validação online faz a mesma checagem por tabela sem derrubar ninguém (FB 2.5.4+):

```powershell
& "$fb\fbsvcmgr.exe" service_mgr user SYSDBA password <senha> action_validate dbname "<banco>"
```

Esperado: toda tabela `is ok` e a saída termina em `Validation finished` (também sai com exit 0 quando acha erro — procure `ERRORS found`).

### Lente 3 — gbak round-trip (dados + metadados)

Rodar backup completo no recuperado é o teste mais profundo (lê todos os registros, todos os BLOBs):

```powershell
& "<SKILL>\scripts\Salvage-Backup.ps1" -Database "<RECUPERADO.FDB>" -BackupFile "<RECUPERADO>.roundtrip.fbk"
```

Esperado:
- Log termina com `closing file, committing, and finishing. N bytes written`.
- Sem linhas `gbak: ERROR`.
- Sem `gbak: warning` que mencione tabela específica (avisos genéricos são OK).

Bônus: restaure esse `.fbk` para um terceiro arquivo e compare os tamanhos. Se diferirem mais que 5%, suspeite (fragmentação ou perda).

### Lente 4 — isql (objetos, registros, órfãs)

> `-o` do isql **anexa** ao arquivo existente: apague as saídas antes de rodar de novo.

Objetos:

```powershell
& "$fb\isql.exe" -q -user SYSDBA -password <senha> -i "<SKILL>\sql\contagem-objetos.sql" "<RECUPERADO.FDB>"
```

Esperado: `INDICES_INATIVOS = 0`, `INDICES_PENDENTES = 0`, `TRIGGERS_INATIVOS` igual ao original. Os demais números iguais aos do original (ou de um backup anterior, ou do que o usuário lembra).

Registros por tabela (linha `TABELA|QTD`; `-1` = tabela ilegível):

```powershell
Remove-Item "<RECUPERADO>.contagem.txt","<ORIGINAL>.contagem.txt" -ErrorAction SilentlyContinue
& "$fb\isql.exe" -q -user SYSDBA -password <senha> -i "<SKILL>\sql\contagem-registros-por-tabela.sql" -o "<RECUPERADO>.contagem.txt" "<RECUPERADO.FDB>"
& "$fb\isql.exe" -q -user SYSDBA -password <senha> -i "<SKILL>\sql\contagem-registros-por-tabela.sql" -o "<ORIGINAL>.contagem.txt"   "<cópia do original>"
Compare-Object (Get-Content "<ORIGINAL>.contagem.txt") (Get-Content "<RECUPERADO>.contagem.txt")   # sem saída = iguais
```

Discrepância > 0,1% justifica conversa com o usuário antes de prosseguir.

FKs órfãs (esperado: todas as linhas terminando em `|0`):

```powershell
& "$fb\isql.exe" -q -user SYSDBA -password <senha> -i "<SKILL>\sql\validar-fk-orfas.sql" "<RECUPERADO.FDB>"
```

## 2. Smoke test na aplicação

Recomendado, não obrigatório se as 4 lentes passaram:

1. Aponte a aplicação para o banco recuperado em ambiente isolado (não produção).
2. Logue com 1-2 usuários representativos.
3. Faça uma operação de leitura típica (listar pedidos do mês, etc.) e uma de escrita (criar/editar/cancelar um registro).
4. Confira que telas críticas abrem sem erro.

Esse passo costuma flagrar: triggers/procedures faltando, generators desincronizados, problemas de charset.

## 3. Plano de reintegração

Antes de mexer no ambiente:

- [ ] Janela de manutenção combinada com o usuário.
- [ ] Backup do banco em produção (o que está rodando), mesmo que seja o "ruim" — você quer um ponto de retorno.
- [ ] Tamanho do recuperado vs produção conferido; se muito menor, alertar.
- [ ] `Database dialect` e `Page size` do recuperado conferidos com os do original.
- [ ] Usuários finais avisados.

**Automatizado:** o `Swap-ProductionDatabase.ps1` faz as pré-checagens (dialect e page size iguais, índices ativos, candidato online, espaço), isola, confere que ninguém segura o arquivo, renomeia a produção para `<arquivo>.antigo.<data>` (nunca apaga), põe o candidato no lugar, desfaz sozinho se algo falhar no meio e confere com `gstat -h` + conexão. Mostre o plano ao usuário com `-WhatIf` antes:

```powershell
& "<SKILL>\scripts\Swap-ProductionDatabase.ps1" -Production "<PRODUCAO.FDB>" -Candidate "<RECUPERADO.FDB>" -Isolation Service -RunHealthCheck -WhatIf
# depois do OK do usuário (Administrador; ou -Isolation Shutdown para afetar só este banco):
& "<SKILL>\scripts\Swap-ProductionDatabase.ps1" -Production "<PRODUCAO.FDB>" -Candidate "<RECUPERADO.FDB>" -Isolation Service -RunHealthCheck -Confirm:$false
```

Execução manual (parar o serviço é o caminho mais seguro: garante que nenhum processo segura o arquivo):

```powershell
# 1) Parar a aplicação (todas as instâncias)
# 2) Parar o serviço Firebird — ou, para não afetar outros bancos, isolar só este: -Action shutdown (gfix -shut full)
& "<SKILL>\scripts\Firebird-Service.ps1" -Action stop        # requer Administrador

# 3) Renomear o banco antigo (NÃO apagar — guardar)
Move-Item -LiteralPath "<PRODUCAO.FDB>" -Destination "<PRODUCAO.FDB>.antigo.$(Get-Date -F yyyyMMdd-HHmmss)"

# 4) Colocar o recuperado no nome de produção (Move: rápido no mesmo volume; Copy se quiser manter o recuperado)
Move-Item -LiteralPath "<RECUPERADO.FDB>" -Destination "<PRODUCAO.FDB>"

# 5) Subir e conferir
& "<SKILL>\scripts\Firebird-Service.ps1" -Action start
& "$fb\gstat.exe" -h "<PRODUCAO.FDB>"     # Attributes: force write; sem shutdown

# 6) Smoke test 2 — agora com a aplicação real
# 7) Liberar usuários
```

Se usou `-Action shutdown` em vez de parar o serviço: o banco **novo** já entra online (o shutdown era do arquivo antigo); confira com `gstat -h`.

Rollback: parar de novo, renomear `<PRODUCAO.FDB>` para `<PRODUCAO.FDB>.recuperado-falhou`, voltar o `.antigo.<data>` para o nome de produção, subir.

## 4. Pós-deploy

Nas primeiras 24h:

- Acompanhar o `firebird.log` (`C:\Program Files\Firebird\Firebird_2_5\firebird.log`).
- Solicitar feedback dos usuários — uma tela que não abre é mais informativa que qualquer log.
- Não apagar nada (original, cópia de trabalho, `.fbk` de salvage) por **pelo menos 30 dias**.

## 5. Documentar o incidente

Para a equipe e para futuros incidentes, registre (relatório técnico dedicado):

1. Sintoma observado.
2. Causa raiz (qual byte/página/transação; forced writes desligado? queda de energia? disco?).
3. Procedimento executado (procedures e ordem).
4. Perdas identificadas (registros, faixas de chave, índices recriados, FK órfãs apagadas).
5. Recomendações para evitar repetição (forced writes ligado, UPS, backup periódico com `gbak`, hardware).

Use `references/checklist-pos-recuperacao.md` como ponto de partida e os templates:

- `templates/relatorio-tecnico.md` — relatório para a equipe (com os números dos relatórios `*.health-*.md`).
- `templates/mensagem-cliente.md` — mensagem curta para o cliente/representante, em linguagem de negócio.
- Evidências de causa raiz: `& "<SKILL>\scripts\Get-FirebirdEnvironmentReport.ps1" -Database "<banco>"` (somente leitura: forced writes, disco, eventos de disco/NTFS, desligamentos inesperados, antivírus, `firebird.log`).

## 6. Quando NÃO declarar sucesso

Mesmo com as 4 lentes passando, recuse declarar sucesso se:

- O usuário relata, na 1ª comparação, perda de área crítica (ex.: "faltam pedidos de ontem").
- O gbak round-trip teve diferença > 5% no tamanho do `.fbk` vs antes.
- Você usou `gfix -mend` e não conseguiu quantificar a perda.
- Há discrepância de schema (tabela vista no código-fonte está sumida no recuperado).

Nesses casos, ou volte para procedure 06 (tabela-a-tabela) com foco nas áreas problemáticas, ou recomende restaurar de backup mais antigo e reentrar dados manualmente.
