# 06 — Salvamento tabela-a-tabela (gbak não passa numa tabela específica)

**Sintoma característico:** `gbak -b` (mesmo com `-ignore -g`) **para** numa tabela X com mensagem do tipo `gbak: ERROR: ... reading table FOO` ou similar. As tabelas processadas antes saíram íntegras no `.fbk`, mas o backup não completou.

**Estratégia:** abandonar o `gbak` como caminho único. Bypass: criar um banco destino vazio com o mesmo schema (extraído via `gbak -b -mo` se possível, ou manual), e então **bombear dados tabela-a-tabela via isql**. Para tabelas problemáticas, usar `FIRST N SKIP M` para isolar a faixa de registros íntegra.

> **IMPORTANTE — Firebird 2.5 NÃO tem `-skip_data`.** Esse switch só existe a partir do FB 3.0. No 2.5 o caminho é: **dropar** a tabela problema **antes** do `gbak -b` (salvando antes os registros íntegros via INSERT em uma tabela auxiliar). Veja a seção "Caminho FB 2.5" abaixo.

> **Armadilha de SQL: `SET TERM ;^` é inválido.** A sintaxe correta para mudar o terminador no isql é `SET TERM <novo> <atual>;` — ou seja, `SET TERM ^ ;` para mudar para `^`, e `SET TERM ; ^` para voltar. Escrever `SET TERM ;^` gera "Token unknown - line 1, column 1" e pode fazer o restante do script rodar com o terminador errado (statements falham silenciosamente). Se você não usa `EXECUTE BLOCK`, **não precisa de SET TERM**, deixe o padrão `;`.

## Pré-requisitos

- Procedures 02 e (04 ou 03) executadas.
- Você sabe **qual tabela** está quebrando (anotada no log do `Salvage-Backup`).
- O `gstat -h` funciona no banco corrompido (header íntegro).

## 1. Criar destino com schema

Estratégia A (melhor): use `gbak -b -mo` para extrair só metadata.

```powershell
$gbak = "C:\Program Files\Firebird\Firebird_2_5\bin\gbak.exe"
$src  = "<corrompido.fdb>"
$skel = "<basename>.metadata-only.fbk"
$dst  = "<RECUPERADO_T2T>.fdb"

# Backup só de metadata
& $gbak -b -v -mo -ignore -g -user SYSDBA -password masterkey $src $skel
# Restore — cria banco vazio com estrutura
& $gbak -c -v -user SYSDBA -password masterkey $skel $dst
```

Estratégia B (fallback): se o `-mo` também trava no objeto que está corrompido, extraia metadata via isql:

```powershell
# Gera script SQL com toda a metadata
& "C:\Program Files\Firebird\Firebird_2_5\bin\isql.exe" -user SYSDBA -password masterkey -x $src > metadata.sql
# Edita removendo objetos problemáticos se for o caso
# Cria banco destino e roda o script
```

Ao final, `$dst` tem todas as tabelas vazias.

## 2. Inventariar tabelas (origem)

```sql
-- Conta registros por tabela no banco corrompido — usar GBAK_BAD.LOG como referência da tabela problema
SELECT R.RDB$RELATION_NAME, R.RDB$RELATION_ID
FROM RDB$RELATIONS R
WHERE R.RDB$SYSTEM_FLAG = 0 AND R.RDB$VIEW_BLR IS NULL
ORDER BY R.RDB$RELATION_NAME;
```

Salve a lista. Vai precisar iterar.

## 3. Pump tabela-a-tabela (caso normal)

Use o script:

```powershell
.\scripts\Salvage-TableByTable.ps1 -SourceDatabase "<corrompido>" -TargetDatabase "<dst>" -ExcludeTables FOO,BAR
```

O que ele faz por baixo:

```sql
-- Para cada tabela íntegra
INSERT INTO destino.TABELA SELECT * FROM origem.TABELA;
COMMIT;
```

Note que Firebird não tem `INSERT FROM <outro banco>` nativo direto — o script usa duas conexões: lê do origem via `isql`, escreve no destino. Para volumes grandes, usa transações por lotes (default 1000 linhas) para limitar memória.

### Fallback se uma tabela falha mid-pump

Para extrair só a parte boa de uma tabela parcialmente corrupta:

```sql
-- Tente em janelas — se quebrar na linha N, isole.
SELECT FIRST 10000 SKIP 0 * FROM TABELA_PROBLEMA;
SELECT FIRST 10000 SKIP 10000 * FROM TABELA_PROBLEMA;
-- ... continue até descobrir a janela ruim
```

Quando achar a janela ruim (ex.: SKIP 50000 trava), você sabe:
- Linhas 0..49999 salváveis.
- Linhas 50000..50N estão em página(s) ruim(s) — descartar ou tentar `FIRST 1 SKIP 50000`, `SKIP 50001`, ... para enxotar uma a uma.

Use `Salvage-TableByTable.ps1 -Table TABELA_PROBLEMA -Window 10000` para automatizar isso.

## 4. Tabelas com BLOB

BLOBs ficam em páginas separadas, podem estar íntegros mesmo se a página da tabela quebrou (ou vice-versa). isql lida nativamente:

```sql
SELECT ID, CAMPO_BLOB FROM TABELA WHERE ID = 42;
```

Se um BLOB específico estoura, identifique pelo ID e exclua aquele registro do pump, ou substitua o BLOB por NULL temporariamente:

```sql
INSERT INTO destino.TABELA (ID, NOME, CAMPO_BLOB)
SELECT ID, NOME,
  CASE WHEN ID NOT IN (42, 187, 999) THEN CAMPO_BLOB ELSE NULL END
FROM origem.TABELA;
```

## 5. Generators (sequences) e triggers

Generators **não** são copiados por INSERT — guardam estado que precisa ser migrado separadamente:

```sql
-- No origem: lista valores atuais
SELECT RDB$GENERATOR_NAME, GEN_ID(EVAL(RDB$GENERATOR_NAME), 0) AS VAL
FROM RDB$GENERATORS WHERE RDB$SYSTEM_FLAG = 0;
```

(Truque: `GEN_ID(gen, 0)` retorna o valor atual sem incrementar.)

```sql
-- No destino: ajustar cada um
ALTER SEQUENCE <NOME> RESTART WITH <valor>;
-- (ou: SET GENERATOR <NOME> TO <valor>; em sintaxe antiga)
```

Triggers já vieram com o schema (gbak -mo). Se algum `BEFORE INSERT` está mexendo nos dados durante o pump (atribuindo timestamps, IDs), desative durante o pump:

```sql
ALTER TRIGGER NOME_TRIGGER INACTIVE;
-- ... pump ...
ALTER TRIGGER NOME_TRIGGER ACTIVE;
```

## 6. Constraints

Após o pump, ative FK/check constraints — pode haver órfãs:

```sql
-- gbak -mo já criou as constraints. Para revalidar:
ALTER TABLE TABELA_FILHO DROP CONSTRAINT FK_X;
ALTER TABLE TABELA_FILHO ADD CONSTRAINT FK_X FOREIGN KEY (CAMPO) REFERENCES TABELA_PAI(ID);
-- se falhar, tem órfã — limpe (ver procedure 05) e refaça
```

## 7. Verificação de completude

```sql
-- Compare contagens lado a lado (rode em cada banco)
SELECT 'TABELA1' AS T, COUNT(*) FROM TABELA1
UNION ALL SELECT 'TABELA2', COUNT(*) FROM TABELA2;
-- ...
```

Quanto "perdeu" em cada tabela? Documente. Acima de 0,1% de perda, traga ao usuário antes de declarar sucesso.

## 8. Casos especiais

### Schema corrompido (metadata-only também quebra)

Se nem `gbak -mo` nem `isql -x` extraem metadata, recupere de um backup antigo do schema (DDL versionado em git, por exemplo). Última escolha: reconstruir manualmente lendo `RDB$RELATIONS`, `RDB$RELATION_FIELDS`, `RDB$FIELDS` no banco corrompido (gstat lê, gfix lê, então as tabelas de sistema provavelmente estão íntegras).

### Procedures, views, exceptions, UDFs

Faça parte do schema dump. Se faltam no destino, leia do origem via `RDB$PROCEDURES`, `RDB$RELATIONS WHERE RDB$VIEW_BLR IS NOT NULL`, etc. — ou use `isql -x` que já cobre.

## 9. Fechamento

Quando os pumps terminam:

1. Rode `Salvage-Backup.ps1` no DESTINO — se backup limpo passa, o banco está consistente.
2. Procedure 08 para verificação final.

A perda eventual de registros que ficaram em páginas irrecuperáveis é o preço dessa estratégia. Documente, reporte, e ofereça ao usuário a comparação com um backup anterior (se houver) para que ele decida se aceita.
