# 08 — Pós-recuperação: validação 4-lentes e reintegração

Esta procedure roda **depois** que o banco recuperado existe (saída de qualquer das procedures 03-07). Objetivo: provar que está consistente antes de devolver para produção, e conduzir a substituição com segurança.

Pulando esta procedure: já houve mais de um caso de banco "recuperado" voltar para produção e quebrar 48h depois porque uma constraint estava silenciosamente desabilitada ou faltava 0,5% dos registros. Validar é barato; replicar incidente é caro.

## 1. As 4 lentes

Cada uma cobre um tipo de problema. Sucesso só é declarado quando **todas** passam.

### Lente 1 — gstat (estrutura física do header)

```powershell
& "C:\Program Files\Firebird\Firebird_2_5\bin\gstat.exe" -h "<RECUPERADO.FDB>"
```

Esperado:
- Page size: valor válido (1024/2048/4096/8192/16384).
- ODS version: 11.2.
- Flags: 0 (ou só "force write").
- Sem "shutdown" em Attributes.

### Lente 2 — gfix -v -full (consistência de páginas)

```powershell
& "C:\Program Files\Firebird\Firebird_2_5\bin\gfix.exe" -v -full -user SYSDBA -password masterkey "<RECUPERADO.FDB>" 2>&1 | Tee-Object "<RECUPERADO>.gfix.log"
$LASTEXITCODE   # esperado 0
```

Esperado: exit 0, log vazio. Qualquer linha "Wrong page type", "Checksum", "doubly allocated" é sinal de problema persistente — volte para procedure 04.

### Lente 3 — gbak round-trip (dados + metadados)

Rodar backup completo no recuperado é o teste mais profundo (lê todos os registros, todos os índices):

```powershell
.\scripts\Salvage-Backup.ps1 -Database "<RECUPERADO.FDB>" -BackupFile "<RECUPERADO>.roundtrip.fbk"
```

Esperado:
- Log termina com `closing file, committing, and finishing. N bytes written`.
- Sem linhas `gbak: ERROR`.
- Sem `gbak: warning` que mencione tabela específica (avisos genéricos são OK).

Bônus: restore esse `.fbk` para um terceiro arquivo e compare os tamanhos. Se diferirem mais que 5%, suspeite (fragmentação ou perda).

### Lente 4 — isql (contagens e amostra)

Contagens de objetos:

```sql
SET LIST ON;
SELECT COUNT(*) AS TABELAS  FROM RDB$RELATIONS WHERE RDB$SYSTEM_FLAG=0 AND RDB$VIEW_BLR IS NULL;
SELECT COUNT(*) AS VIEWS    FROM RDB$RELATIONS WHERE RDB$SYSTEM_FLAG=0 AND RDB$VIEW_BLR IS NOT NULL;
SELECT COUNT(*) AS PROCS    FROM RDB$PROCEDURES;
SELECT COUNT(*) AS GERADORES FROM RDB$GENERATORS WHERE RDB$SYSTEM_FLAG=0;
SELECT COUNT(*) AS TRIGGERS FROM RDB$TRIGGERS WHERE RDB$SYSTEM_FLAG=0;
SELECT COUNT(*) AS INDICES_INACTIVE FROM RDB$INDICES WHERE RDB$INDEX_INACTIVE=1 AND RDB$SYSTEM_FLAG=0;
```

(Use `sql/contagem-objetos.sql`.)

Comparar contra:
- O que o usuário lembra (perguntou na procedure 01).
- Backup anterior (se disponível) — restaure em paralelo e compare.
- Se houver schema em git, contagens batem com `CREATE TABLE` count.

Esperado: `INDICES_INACTIVE = 0`. Qualquer outro número aceito se você sabe explicar.

Contagens de registros por tabela:

```sql
SET TERM ^;
EXECUTE BLOCK RETURNS (TABELA VARCHAR(31), QTD INT) AS
DECLARE VARIABLE R VARCHAR(31);
BEGIN
  FOR SELECT RDB$RELATION_NAME FROM RDB$RELATIONS
      WHERE RDB$SYSTEM_FLAG=0 AND RDB$VIEW_BLR IS NULL
      INTO :R DO BEGIN
    TABELA = :R;
    EXECUTE STATEMENT 'SELECT COUNT(*) FROM "' || :R || '"' INTO :QTD;
    SUSPEND;
  END
END^
SET TERM ;^
```

Salve a saída. Compare contra última cópia íntegra (backup, espelhamento, réplica) — se houver. Discrepância > 0,1% justifica conversa com o usuário antes de prosseguir.

## 2. Smoke test na aplicação

Recomendado, não obrigatório se as 4 lentes passaram:

1. Aponte a aplicação para o banco recuperado em ambiente isolado (não produção).
2. Logue com 1-2 usuários representativos.
3. Faça uma operação de leitura típica (listar pedidos do mês, etc.) e uma de escrita (criar/editar/cancelar um registro).
4. Confira que telas críticas abrem sem erro.

Esse passo costuma flagrar: triggers/procedures faltando, generators desincronizados, problemas de charset.

## 3. Plano de reintegração

Antes de mexer no ambiente:

- [ ] Janela de manutenção combinada com usuário.
- [ ] Backup do banco em produção (o que está rodando), mesmo que seja o "ruim" — você quer um ponto de retorno.
- [ ] Conferir tamanho do recuperado vs produção; se muito menor, alertar.
- [ ] Avisar usuários finais.

Execução:

```powershell
# 1) Parar a aplicação (todas as instâncias)
# 2) Parar o serviço Firebird (ou gfix -shut no banco ativo)
.\scripts\Firebird-Service.ps1 -Database "<PRODUCAO.FDB>" -Action shutdown

# 3) Renomear o banco corrompido (NÃO apagar — guardar)
Move-Item -LiteralPath "<PRODUCAO.FDB>" -Destination "<PRODUCAO.FDB>.corrompido.$(Get-Date -F yyyyMMdd-HHmmss)"

# 4) Mover/copiar o recuperado para o nome de produção
Copy-Item -LiteralPath "<RECUPERADO.FDB>" -Destination "<PRODUCAO.FDB>"

# 5) Voltar online
.\scripts\Firebird-Service.ps1 -Database "<PRODUCAO.FDB>" -Action online

# 6) Smoke test 2 — agora com a aplicação real
# 7) Liberar usuários
```

## 4. Pós-deploy

Nas primeiras 24h:

- Acompanhar logs do servidor Firebird (`firebird.log` em `C:\Program Files\Firebird\Firebird_2_5\`).
- Solicitar feedback dos usuários — uma tela que não abre é mais informativa que qualquer log.
- Não apagar nada (corrompido original, fix.fdb, .fbk de salvage) por **pelo menos 30 dias**.

## 5. Documentar o incidente

Para a equipe e para futuros incidentes, registre (relatório técnico dedicado):

1. Sintoma observado.
2. Causa raiz (qual byte/página/transação).
3. Procedimento executado (procedures e ordem).
4. Perdas identificadas (registros, índices recriados, etc.).
5. Recomendações para evitar repetição (UPS, backup periódico, hardware).

Use o template `references/checklist-pos-recuperacao.md` como ponto de partida.

## 6. Quando NÃO declarar sucesso

Mesmo com as 4 lentes passando, recuse declarar sucesso se:

- O usuário relata, na 1ª comparação, perda de área crítica (ex.: "faltam pedidos de ontem").
- O gbak round-trip teve diferença > 5% no tamanho do `.fbk` vs antes.
- Você usou `gfix -mend` e não conseguiu quantificar a perda.
- Há discrepância de schema (tabela vista no schema do código-fonte está sumida no recuperado).

Nesses casos, ou volte para procedure 06 (tabela-a-tabela) com foco nas áreas problemáticas, ou recomende restaurar de backup mais antigo e reentrar dados manualmente.
