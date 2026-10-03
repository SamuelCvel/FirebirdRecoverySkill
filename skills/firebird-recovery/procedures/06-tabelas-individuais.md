# 06 — Salvamento tabela-a-tabela (gbak não passa numa tabela específica)

**Sintoma característico:** `gbak -b` (mesmo com `-ignore -g`) **para** numa tabela com erro do tipo `wrong page type`, `page N is of wrong type (expected 5, found 0)`, `I/O error ... ReadFile` ou `database file appears corrupt`. A tabela que quebrou é a da **última** linha `writing table X` / `writing data for table X` do log antes do primeiro `ERROR`.

**Estratégia:** tirar o `gbak` do caminho crítico. Os dados legíveis são copiados **para outro banco** por `EXECUTE STATEMENT ... ON EXTERNAL` (EDS, disponível no FB 2.5), lendo pela chave primária para pular a região danificada.

> **Firebird 2.5 NÃO tem `-skip_data`** (é 3.0+; `-include_data` é 4.0+). No 2.5 não há como pular uma tabela no backup: ou se **dropa** a tabela numa cópia (Caminho A) ou se copia tudo por fora do gbak (Caminho B).

> **Armadilhas do isql:** `-b` (parar no erro) só funciona com `-i arquivo`, não com script por pipe; `-o`/`OUTPUT` **anexam** ao arquivo existente; e `SET TERM` tem que ser escrito `SET TERM ^ ;` (entrar) / `SET TERM ; ^` (sair) — `SET TERM ;^` usado para entrar faz o isql engolir os comandos seguintes **sem erro**. Foi isso que, num caso real, deixou um `CREATE` falhar em silêncio e o `DROP` seguinte rodar.

> `<SKILL>` = pasta da skill (informada no SKILL.md). Tudo aqui roda numa **cópia** do banco corrompido (procedure 02); o original não é tocado.

## Sumário

0. [Escolher o caminho](#0-escolher-o-caminho)
1. [Caminho A — salvar, dropar, gbak, recriar](#1-caminho-a--fb-25-salvar--dropar--gbak--recriar)
2. [Caminho B — copiar tudo para um banco novo](#2-caminho-b--copiar-tudo-para-um-banco-novo)
3. [Extrair o que dá de uma tabela danificada](#3-extrair-o-que-dá-de-uma-tabela-danificada)
4. [BLOBs](#4-blobs)
5. [Generators e triggers](#5-generators-e-triggers)
6. [Constraints](#6-constraints)
7. [Verificação de completude](#7-verificação-de-completude)
8. [Casos especiais](#8-casos-especiais)
9. [Fechamento](#9-fechamento)

## Pré-requisitos

- Procedures 02 e (04 ou 03) executadas.
- O `gstat -h` funciona no banco corrompido (header íntegro).
- Servidor no ar (EDS e isql conectam via servidor).

## 0. Escolher o caminho

Antes de escolher, **liste todas as tabelas ruins de uma vez** — o gbak só mostra a primeira:

```powershell
& "C:\Program Files\Firebird\Firebird_2_5\bin\isql.exe" -q -user SYSDBA -password <senha> -i "<SKILL>\sql\sondar-tabelas.sql" -o "<cópia>.sonda.txt" "<cópia>"
```

(ou a validação online: `fbsvcmgr service_mgr user SYSDBA password <senha> action_validate dbname "<cópia>"`).

| Situação | Caminho |
|---|---|
| 1–2 tabelas ruins, banco grande, o resto passa no gbak | **A** — salvar → dropar → gbak → recriar (seção 1) |
| várias tabelas ruins, ou o gbak não serve | **B** — copiar tudo para um banco novo (seção 2) |
| a PK da tabela ruim também está danificada, ou não há PK | seção 3.c (leitura por `RDB$DB_KEY`) |
| **3+ sítios independentes** de corrupção | **pare** — procedure 04 seção 5b (provável hardware; backup é mais barato) |

## 1. Caminho A — FB 2.5: salvar → dropar → gbak → recriar

Use quando poucas tabelas impedem o backup. `T` = tabela problemática.

1. **DDL completa** (vai precisar para recriar `T`, suas FKs e o que depende dela):
   ```powershell
   Remove-Item "<cópia>.schema.sql" -ErrorAction SilentlyContinue      # -o anexa
   & "C:\Program Files\Firebird\Firebird_2_5\bin\isql.exe" -x -user SYSDBA -password <senha> -o "<cópia>.schema.sql" "<cópia>"
   ```
2. **Banco de resgate** com o mesmo schema, vazio e com índices inativos:
   ```powershell
   $gbak = "C:\Program Files\Firebird\Firebird_2_5\bin\gbak.exe"
   & $gbak -b -v -meta_data -ignore -g -user SYSDBA -password <senha> "<cópia>" "<cópia>.meta.fbk"
   & $gbak -c -v -meta_data -inactive  -user SYSDBA -password <senha> "<cópia>.meta.fbk" "<RESGATE>.fdb"
   ```
3. **Salvar as linhas legíveis de `T` no RESGATE**, pela chave (seção 3.a). Nunca grave dentro do arquivo corrompido — escrever nele pode usar páginas que a PIP danificada acha livres.
4. **Conferir**: `SELECT COUNT(*) FROM T` no RESGATE e as faixas de chave perdidas (anote).
5. **Na `<cópia>`**, tirar `T` do caminho:
   ```sql
   -- FKs de outras tabelas que apontam para T
   SELECT TRIM(RC.RDB$CONSTRAINT_NAME) AS FK, TRIM(RC.RDB$RELATION_NAME) AS FILHA
   FROM RDB$RELATION_CONSTRAINTS RC
   JOIN RDB$REF_CONSTRAINTS RF ON RF.RDB$CONSTRAINT_NAME = RC.RDB$CONSTRAINT_NAME
   JOIN RDB$RELATION_CONSTRAINTS PK ON PK.RDB$CONSTRAINT_NAME = RF.RDB$CONST_NAME_UQ
   WHERE PK.RDB$RELATION_NAME = 'T';
   ```
   `ALTER TABLE <filha> DROP CONSTRAINT <fk>;` para cada uma, `COMMIT;`, depois `DROP TABLE T; COMMIT;`. Se o `DROP` reclamar de dependência (view, procedure, trigger), anote e drope temporariamente também — a DDL está no `schema.sql`. Rode cada passo em arquivo com `isql -b -e -i` e **confira o resultado antes do próximo**.
6. **Backup e restore sem `T`**:
   ```powershell
   & "<SKILL>\scripts\Salvage-Backup.ps1" -Database "<cópia>" -BackupFile "<cópia>.sem-T.fbk"
   & "<SKILL>\scripts\Restore-Clean.ps1" -BackupFile "<cópia>.sem-T.fbk" -TargetDatabase "<RECUPERADO>.fdb" -InactiveIndexes -OneAtATime
   ```
   Se o gbak parar em **outra** tabela, repita 3–6 para ela (e reavalie o "3+ sítios").
7. **No RECUPERADO**: recriar `T` (trecho `CREATE TABLE`, índices, triggers e grants do `schema.sql`), carregar `T` a partir do RESGATE (seção 3.a com origem = RESGATE; o RESGATE é saudável, então pode copiar a tabela inteira), recriar as FKs que apontavam para `T` e o que mais foi dropado no passo 5.
8. **Ativar índices e tratar órfãs** (procedure 05 seções 3 e 4c) e **4 lentes** (procedure 08).

## 2. Caminho B — copiar tudo para um banco novo

1. **Destino** com o schema vazio e índices inativos (igual ao passo 2 do Caminho A).
2. **Gerar o script de cópia** conectado no DESTINO e rodar (testado no 2.5.9: copia todas as tabelas, inclusive BLOBs; trata CHECKs, triggers e generators):
   ```powershell
   $isql = "C:\Program Files\Firebird\Firebird_2_5\bin\isql.exe"
   Remove-Item "copiar.sql" -ErrorAction SilentlyContinue      # -o anexa
   & $isql -q -user SYSDBA -password <senha> -i "<SKILL>\sql\gerar-script-salvage.sql" -o "copiar.sql" "<DESTINO>.fdb"
   (Get-Content copiar.sql) -replace '<ORIGEM>','<cópia>' -replace '<USUARIO>','SYSDBA' -replace '<SENHA>','<senha>' | Set-Content copiar-pronto.sql
   & $isql -q -b -nod -user SYSDBA -password <senha> -i "copiar-pronto.sql" -o "copiar.log" "<DESTINO>.fdb"
   Remove-Item "copiar-pronto.sql"                              # contém a senha
   ```
3. **Tabela que falhar** (o `-b` para nela): apague o bloco dela do `copiar-pronto.sql`, rode o restante e extraia essa tabela pela chave (seção 3.a).
4. **Ativar índices e tratar órfãs/duplicatas** (procedure 05 seções 3 e 4c).
5. **Contagens**: `sql/contagem-registros-por-tabela.sql` na origem e no destino (`-1` na origem = tabela ilegível por inteiro) e **4 lentes** (procedure 08).

## 3. Extrair o que dá de uma tabela danificada

### 3.a Pela chave primária (keyset) — padrão

**Automatizado** (testado no 2.5.9 com páginas de dados zeradas de propósito: as linhas perdidas foram **exatamente** as das páginas ruins):

```powershell
& "<SKILL>\scripts\Salvage-TableByTable.ps1" -Action pump -Database "<cópia>" -TargetDatabase "<RESGATE ou DESTINO>.fdb" -Table PEDIDO -Auto
```

- Copia janelas de 5000 linhas pela PK; janela que falha encolhe (500 → 50 → 5 → 1); quando nem 1 linha sai, **pula** a região ruim (busca exponencial + bissecção na última coluna da PK, direto na origem) e segue.
- PK composta: decompõe `(A,B) > (a,b)` em faixas que o índice posiciona (`A=a AND B>b`, depois `A>a`); com 2 colunas numéricas, atravessa também o começo ilegível do próximo prefixo.
- Faixas perdidas vão para `<destino>.pump.<TABELA>.csv` (vão para o relatório). A faixa é o **intervalo** pulado (`de 3028 até 3033`), não a lista de registros: muitas chaves dele podem nem existir. Para dizer exatamente **quais** registros se perderam, sonde cada chave do intervalo pelo índice — `SELECT PK FROM T WHERE PK = k`: sem linha = a chave não existe; erro de página = registro perdido. Num caso real, uma faixa de 5 chaves tinha **1** registro perdido.
- **Só pula** erro de página danificada. Erro de SQL, login, permissão ou constraint no destino **para tudo** (não descarta dado bom).
- **Limite:** se a última coluna da PK não é numérica (ex.: código texto), o `-Auto` para na região ruim e diz a última chave copiada. Retome com `-StartKey` depois da região (ex.: `-StartKey 'C000250'`) e `-Auto` de novo. Sem PK: seção 3.c.

Modelo manual equivalente — rode no banco **de destino** (RESGATE ou DESTINO). Copia uma janela de linhas da origem por vez, começando depois da última chave copiada (testado no FB 2.5.9, com BLOB):

```sql
SET TERM ^ ;
EXECUTE BLOCK RETURNS (COPIADOS INTEGER, ULTIMA_CHAVE BIGINT) AS
  DECLARE V_ID   TYPE OF COLUMN PEDIDO.ID;
  DECLARE V_NOME TYPE OF COLUMN PEDIDO.NOME;
  DECLARE V_OBS  TYPE OF COLUMN PEDIDO.OBS;          -- BLOB funciona via EDS
BEGIN
  COPIADOS = 0;
  ULTIMA_CHAVE = NULL;
  FOR EXECUTE STATEMENT ('SELECT ID, NOME, OBS FROM PEDIDO WHERE ID > ? ORDER BY ID ROWS 5000') (0)  -- troque o 0 pela última chave copiada
      ON EXTERNAL '<ORIGEM>' AS USER 'SYSDBA' PASSWORD '<senha>'
      INTO :V_ID, :V_NOME, :V_OBS
  DO BEGIN
    INSERT INTO PEDIDO (ID, NOME, OBS) VALUES (:V_ID, :V_NOME, :V_OBS);
    COPIADOS = COPIADOS + 1;
    ULTIMA_CHAVE = V_ID;
  END
  SUSPEND;
END^
SET TERM ; ^
COMMIT;
```

Cada execução é atômica: se a janela bate numa página ruim, **nada** dela é gravado. Roteiro:

1. Rode com `0` (ou o menor valor da chave). Anote `ULTIMA_CHAVE` e repita a partir dela até `COPIADOS = 0`.
2. Se uma janela falhar, repita **a partir da mesma chave** com `ROWS` menor (5000 → 500 → 50 → 5 → 1) até achar a última chave legível.
3. Quando até `ROWS 1` falha, o próximo registro está na região ruim. **Pule** com a chave: tente `WHERE ID > <última> + 1000 ... ROWS 1`, depois reduza o salto pela metade até achar a primeira chave legível depois do buraco.
4. Anote cada faixa perdida (`> última` e `< primeira legível`) — vai para o relatório.

**Chave composta** `(A, B)`: faça em duas consultas — primeiro `WHERE A = a AND B > b ORDER BY A, B ROWS n` (resto do prefixo atual), depois `WHERE A >= a+1 ORDER BY A, B ROWS n` (prefixos seguintes). Verificado no 2.5.9: um `A > a` sobre só parte do índice composto ainda lê os registros de `A = a` (e bate na página ruim do prefixo); `A >= a+1` (coluna inteira) posiciona certo. Um `A >= a AND (A > a OR B > b)` numa consulta só relê o prefixo inteiro desde o começo.

**Confira o plano antes** (na origem, com `SET PLANONLY ON;` no isql): tem que aparecer `ORDER <índice da PK>` (ex.: `PLAN (PEDIDO ORDER PK_PEDIDO INDEX (PK_PEDIDO))`). Se aparecer `NATURAL`, a consulta varre a tabela inteira e bate na página ruim de qualquer jeito.

O charset da conexão EDS é o mesmo da sua sessão isql: use `-ch <charset do banco>` para não estragar acentos.

### 3.b Por que não `FIRST/SKIP`

`SELECT FIRST n SKIP m` **relê** os `m` registros pulados. Depois de uma página ruim, **toda** janela seguinte passa por ela e falha — foi exatamente o que aconteceu num caso real de 11 GB (todas as janelas depois de um certo ponto falharam) — e cada janela fica mais lenta que a anterior. Pela chave, a leitura começa direto no ponto certo do índice.

### 3.c Último recurso: leitura direta por `RDB$DB_KEY`

Quando o índice da PK também está danificado, ou a tabela não tem PK. No 2.5, `WHERE RDB$DB_KEY = X'...'` busca **um** registro direto (via pointer page → data page), sem varrer a tabela; uma página de dados ruim só derruba os registros que estão nela. Verificado no 2.5.9:

- O DB_KEY tem 8 bytes: bytes 0–1 = id da relação (little-endian), byte 2 = 0, byte 3 = bits 32–39 do nº do registro, bytes 4–7 = bits 0–31 (little-endian). O valor gravado é **nº do registro + 1**. Ex.: `8000000001000000` = relação 128, primeiro registro.
- Slot vazio devolve 0 linhas, sem erro.
- Registros por página `R = (page_size − 28) / 17` (239 / 480 / 962 para 4K / 8K / 16K); páginas de dados por pointer page `P = (page_size − 32) × 8 / 34` (956 / 1920 / 3847). Nº do registro `n = (pp × P + slot) × R + linha`.

Enumerar `n` e buscar um a um é lento e trabalhoso — use só para tabela crítica que não sai de outro jeito, e documente.

## 4. BLOBs

BLOBs ficam em páginas separadas; o EDS copia BLOBs normalmente. Se um BLOB específico quebra a janela, isole pela chave e copie `NULL` para ele:

```sql
FOR EXECUTE STATEMENT ('SELECT ID, NOME, CASE WHEN ID IN (42, 187) THEN NULL ELSE OBS END FROM PEDIDO WHERE ID > ? ORDER BY ID ROWS 5000') (0)
```

## 5. Generators e triggers

O script do `gerar-script-salvage.sql` já desliga os triggers de tabela durante a carga, religa no fim e acerta os generators com os valores da origem. Manualmente (não existe `EVAL` no Firebird — use `EXECUTE STATEMENT`):

```sql
-- na ORIGEM: valor atual de cada generator
SET TERM ^ ;
EXECUTE BLOCK RETURNS (GERADOR VARCHAR(31), VALOR BIGINT) AS
BEGIN
  FOR SELECT TRIM(RDB$GENERATOR_NAME) FROM RDB$GENERATORS WHERE COALESCE(RDB$SYSTEM_FLAG, 0) = 0 INTO :GERADOR DO
  BEGIN
    EXECUTE STATEMENT 'SELECT GEN_ID("' || GERADOR || '", 0) FROM RDB$DATABASE' INTO :VALOR;
    SUSPEND;
  END
END^
SET TERM ; ^
-- no DESTINO, para cada um:  SET GENERATOR <NOME> TO <valor>;
```

Triggers `BEFORE INSERT` que mexem nos dados (IDs, datas) precisam estar desligados durante a carga: `ALTER TRIGGER <nome> INACTIVE;` … `ALTER TRIGGER <nome> ACTIVE;`.

## 6. Constraints

- Destino criado com `-inactive`: PK, FK e UNIQUE ficam **sem efeito** até a ativação (procedure 05 seção 3) — é aí que aparecem órfãs e duplicatas.
- **CHECK de tabela** continua ativa e é conferida em cada INSERT. Dado antigo que viola uma CHECK criada depois trava a carga (`Operation violates CHECK constraint`). No 2.5 não dá para desligar o trigger da CHECK (`Triggers created automatically cannot be modified`); o caminho é remover a constraint e recriar depois (o Firebird **não** revalida linhas antigas ao recriar). O `gerar-script-salvage.sql` faz isso sozinho.
- CHECK de **domínio** e NOT NULL são conferidos na carga, como no restore do gbak. Se travarem, decida com o usuário (corrigir o dado ou carregar sem a restrição).

## 7. Verificação de completude

```powershell
Remove-Item "cont-origem.txt","cont-destino.txt" -ErrorAction SilentlyContinue
& $isql -q -user SYSDBA -password <senha> -i "<SKILL>\sql\contagem-registros-por-tabela.sql" -o "cont-origem.txt"  "<cópia>"
& $isql -q -user SYSDBA -password <senha> -i "<SKILL>\sql\contagem-registros-por-tabela.sql" -o "cont-destino.txt" "<DESTINO>.fdb"
Compare-Object (Get-Content cont-origem.txt) (Get-Content cont-destino.txt)
```

Quanto "perdeu" em cada tabela? Documente com as faixas de chave da seção 3.a. Acima de 0,1% de perda, traga ao usuário antes de declarar sucesso.

## 8. Casos especiais

### Schema corrompido (metadata-only também quebra)

Se nem `gbak -b -meta_data` nem `isql -x` extraem a metadata, recupere de um backup antigo do schema (DDL versionado, por exemplo). Última escolha: reconstruir lendo `RDB$RELATIONS`, `RDB$RELATION_FIELDS`, `RDB$FIELDS` no banco corrompido (o gstat lê, então as tabelas de sistema podem estar íntegras).

### Colunas ARRAY

O gerador pula colunas ARRAY (raras). Se a tabela tiver, trate a coluna à parte.

### Procedures, views, exceptions, UDFs

Vêm com a metadata do gbak (ou no `isql -x`). Confira as contagens com `sql/contagem-objetos.sql` em origem e destino.

## 9. Fechamento

1. Rode `Salvage-Backup.ps1` no DESTINO — se o backup passa limpo, o banco está consistente.
2. Procedure 08 para a verificação final.

A perda de registros que estavam em páginas irrecuperáveis é o preço desta estratégia. Documente as faixas, reporte e ofereça ao usuário a comparação com um backup anterior (se houver) para ele decidir se aceita.
