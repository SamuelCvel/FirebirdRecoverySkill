# 05 — Índices e restrições quebrando o restore

**Sintoma característico:** o `gbak -b` (backup) completou bem, mas o `gbak -c` (restore) **para** ao recriar um índice unique, uma primary key, uma foreign key, ou um check constraint. Mensagens típicas:

- `attempt to store duplicate value (visible to active transactions) in unique index "PK_FOO"`
- `violation of FOREIGN KEY constraint "FK_PEDIDO_CLIENTE" on table "PEDIDO"` + `Problematic key value is ("CLIENTE_ID" = 42)`
- `cannot commit index FK_X`
- `violation of CHECK constraint "CHK_VALOR_POSITIVO"` / `validation error for column ...`

A mensagem indica qual constraint quebrou — anote sempre. No 2.5 a violação de FK já traz a **chave** da órfã (`Problematic key value`).

**Diagnóstico subjacente:** existem dados inconsistentes no banco corrompido que só viram problema na reconstrução das constraints:
- Duplicatas em campo que era pra ser unique (transação parcial, crash entre INSERT e CHECK).
- FK órfãs (registro pai perdido/corrompido mas filho permaneceu).
- Valor que viola check/NOT NULL (corrupção parcial do dado que sobreviveu ao backup com `-ignore`).

> `<SKILL>` = pasta da skill (informada no SKILL.md).

## Sumário

1. [Restore em 2 fases](#1-restore-em-2-fases-estratégia-padrão)
2. [Tratar as quebras](#2-tratar-as-quebras-antes-de-ativar)
3. [Ativar índices e constraints](#3-ativar-índices-e-constraints)
4. [Metadata-only e merge de dado](#4-caso-especial-metadata-only-e-merge-de-dado)
5. [Estado dos índices FK pós-restore quebrado (4b)](#4b-estado-dos-índices-fk-pós-restore-quebrado)
6. [Workflow completo de órfãs (4c)](#4c-workflow-completo-visto-em-caso-real-de-health-check)
7. [Verificação final](#5-verificação-final)
8. [Observações](#6-observações)

## Pré-requisitos

- `.fbk` válido produzido por `Salvage-Backup.ps1` (procedure 04, ou direto se o gbak passou na 1ª).
- Banco destino **não existe ainda**. O `gbak -c` recusa sobrescrever; `-rep` ou `-r o` substituem — prefira sempre um nome novo.

## 1. Restore em 2 fases (estratégia padrão)

A ideia: restaurar o dado **sem** aplicar constraints/índices, depois ativar e tratar as quebras.

```powershell
$gbak = "C:\Program Files\Firebird\Firebird_2_5\bin\gbak.exe"
$fbk = "<...>.fbk"
$dst = "<RECUPERADO>.fdb"

# Fase 1: restore com índices inativos e commit por tabela
& $gbak -c -v -inactive -one_at_a_time -user SYSDBA -password <senha> $fbk $dst 2>&1 | Tee-Object "<dst>.restore.log"
```

Flags:
- `-inactive` (`-i`) — recria **todos** os índices inativos, inclusive os de PK/FK/UNIQUE: as constraints ficam **sem efeito** até a ativação.
- `-one_at_a_time` (`-o`) — commit por tabela. Se uma tabela quebra, as anteriores ficam salvas.

Resultado esperado: o `.fdb` foi criado, **todo o dado está dentro**, mas índices estão inativos e PK/FK/UNIQUE não são checadas até a fase 3.

> No 2.5 **não dá** para desativar índice de PK/FK/UNIQUE por DDL (`Cannot deactivate index used by an integrity constraint`). O `gbak -c -inactive` é o único jeito de ter essas constraints desligadas.

### Fallback se mesmo com -inactive -one_at_a_time falha

| Falha | Ação |
|---|---|
| Para em tabela X com mensagem genérica | é dado corrupto na tabela, não constraint → **procedure 06** para essa tabela |
| Para com `unsuccessful metadata update` | metadata divergiu; tente só a estrutura primeiro (`-meta_data`): seção 4 |
| Para com `validation error for column ...` (NOT NULL/CHECK de domínio) | `-no_validity` (`-n`) passa, mas **derruba também os NOT NULL** — documente e recrie depois |
| Para com `out of memory` | aumentar `-buffers` (`-bu`); ex.: `-bu 10000` |

## 2. Tratar as quebras antes de ativar

Conecte no banco destino e procure as inconsistências por tabela com índice unique. Exemplo para uma PK que quebrou:

```sql
-- Acha duplicatas em CLIENTES.ID
SELECT ID, COUNT(*) AS QTD
FROM CLIENTES
GROUP BY ID
HAVING COUNT(*) > 1;
```

Decisão por linha duplicada:

- **Pode escolher uma e apagar as outras?** Compare campos não-PK (qual parece mais recente / completo). Apague as obsoletas:
  ```sql
  DELETE FROM CLIENTES WHERE ID = 42 AND <criterio que isola as obsoletas>;
  COMMIT;
  ```
- **Não dá pra decidir?** Documente, marque com prefixo no nome (ex: `DUPLICADO_<id>`) ou mova para uma tabela `LIXEIRA_CLIENTES`, e siga.

Para FK órfãs, rode o detector (todas as FKs de uma vez, **inclusive FK composta**):

```powershell
& "C:\Program Files\Firebird\Firebird_2_5\bin\isql.exe" -q -user SYSDBA -password <senha> -i "<SKILL>\sql\validar-fk-orfas.sql" -o "<dst>.orfas.txt" "<dst>"
```

Saída: uma linha `FK|FILHA|PAI|ORFAS` por FK (`-1` = a contagem deu erro). A regra é a mesma do engine: linha com **qualquer** coluna da FK nula não é órfã.

Para uma FK específica (exemplo com FK composta):

```sql
SELECT COUNT(*) FROM PEDIDO F
WHERE F.EMPRESA IS NOT NULL AND F.CLIENTE IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM CLIENTE P WHERE P.EMPRESA = F.EMPRESA AND P.CODIGO = F.CLIENTE);
```

> Nunca valide FK composta coluna por coluna: um par `(2, 20)` órfão passa despercebido se existir algum pai com EMPRESA=2 e outro com CODIGO=20.

Decisão:
- Apagar os órfãos (se aceitável) — **depois** do dump forense da seção 4c.
- Inserir um pai "stub" (ex.: `CODIGO=0, NOME='NAO IDENTIFICADO'`) e re-apontar os órfãos.

## 3. Ativar índices e constraints

Depois de limpar, gere um `ALTER INDEX` por índice inativo e rode como script — cada um commita sozinho e uma falha não derruba os outros. **Apague o `ativar-indices.sql` antes de gerar**: o `OUTPUT` do isql anexa ao arquivo existente, e uma linha velha de outro banco vira erro `Index not found`.

```sql
SET HEADING OFF;
OUTPUT ativar-indices.sql;
SELECT 'ALTER INDEX "' || TRIM(RDB$INDEX_NAME) || '" ACTIVE;'
FROM RDB$INDICES
WHERE RDB$SYSTEM_FLAG = 0 AND COALESCE(RDB$INDEX_INACTIVE, 0) <> 0
ORDER BY RDB$FOREIGN_KEY NULLS FIRST, RDB$INDEX_NAME;   -- PK/UNIQUE antes das FKs
OUTPUT;
```

```powershell
& "C:\Program Files\Firebird\Firebird_2_5\bin\isql.exe" -q -e -user SYSDBA -password <senha> -i ativar-indices.sql "<dst>" 2>&1 | Tee-Object "<dst>.ativar.log"
```

> `RDB$INDEX_INACTIVE`: **NULL ou 0 = ativo**, 1 = inativo, 3 = pendente (seção 4b). Sempre filtre com `COALESCE(..., 0) <> 0`.

Se algum `ALTER INDEX ... ACTIVE` falhar, ainda há duplicata/órfã naquela tabela — o índice continua inativo. Volte ao passo 2 só para ela.

### Fallback se um índice não ativa nem após limpeza

- Confira se a tabela tem **trigger BEFORE INSERT** que mexe nos dados — pode estar gerando duplicatas internas.
- Para índice comum (não de constraint), considere recriar com nome novo (DROP + CREATE) — às vezes a metadata do índice inativo carrega lixo.

## 4. Caso especial: metadata-only e merge de dado

Quando a corrupção pegou metadata, recrie primeiro só a estrutura:

```powershell
# Só objetos (sem dados), com índices inativos para aceitar a carga em qualquer ordem
& $gbak -c -v -meta_data -inactive -user SYSDBA -password <senha> $fbk $dst
```

`-meta_data` (`-m`) recria a estrutura sem registros. **Atenção:** `-mo` é outro switch (`-mode read_only|read_write`) e faz o comando falhar.

Depois, carregue os dados tabela a tabela puxando da origem via `EXECUTE STATEMENT ... ON EXTERNAL` (FB 2.5 suporta) — modelo pronto e testado na **procedure 06**, seção 3.

## 4b. Estado dos índices FK pós-restore quebrado

Quando `gbak -c` reporta `cannot commit index FK_X` + `violation of FOREIGN KEY constraint`, o índice **é criado no banco destino, mas fica em estado intermediário** com `RDB$INDICES.RDB$INDEX_INACTIVE = 3` ("pending / cannot commit").

Como listar todos os índices que não estão ativos:

```sql
SELECT TRIM(RDB$INDEX_NAME) AS NOME, RDB$INDEX_INACTIVE AS ESTADO, TRIM(RDB$RELATION_NAME) AS TABELA
FROM RDB$INDICES
WHERE COALESCE(RDB$INDEX_INACTIVE, 0) <> 0 AND RDB$SYSTEM_FLAG = 0;
```

Atenção ao filtro: `= 1` perde os que estão em estado 3, e `= 0` perde os ativos (que costumam ter NULL).

Depois de limpar os órfãos (seção 2), reativar com:

```sql
ALTER INDEX <nome_do_indice> ACTIVE;
```

O `ALTER INDEX ... ACTIVE` recria o índice do zero. Se ainda houver órfã, ele reporta a violação e o índice continua inativo — volte à seção 2 e refine a busca.

> Um restore que termina com erro costuma deixar o banco em **`single-user maintenance`** (`gstat -h` → `Attributes`). Nesse estado só cabe **uma** conexão: a segunda (outro isql, gbak) recebe `connection lost to database`. Rode `gfix -online` (procedure 08, seção 0) antes de investigar.

## 4c. Workflow completo (visto em caso real de health check)

Sequência canônica quando o restore para em FK violation. Cada passo é reversível se você mantiver os originais (procedure 02):

1. **Tirar do modo de manutenção**: `gstat -h`; se mostrar `single-user maintenance`, `gfix -online` (uma conexão por vez até lá).
2. **Ler o log** e extrair todas as FKs com problema (`Select-String -Pattern 'cannot commit index|violation of FOREIGN KEY|Problematic key value'`).
3. **Contar órfãs por FK** com `sql/validar-fk-orfas.sql` (seção 2) ou, para uma FK, `SELECT COUNT(*) ... WHERE NOT EXISTS (...)` com **todas** as colunas da FK. Se retornar `0`, a FK só ficou pendente por ordem de commit e reativa limpa.
4. **Backup forense**: `SELECT * FROM filha F WHERE <colunas não nulas> AND NOT EXISTS (...)` com `OUTPUT arquivo.txt` no isql — grave em texto TODOS os campos das órfãs antes de deletar. Fica como evidência.
5. **Apresentar contagens ao usuário** antes de qualquer `DELETE` — decisão de negócio é dele.
6. **DELETE** por FK, em transação única com `COMMIT` no fim.
7. **`ALTER INDEX ... ACTIVE`** para cada FK.
8. **Voltar às 4 lentes** (procedure 08) para confirmar banco limpo.

> **`connection lost to database` (SQLSTATE 08006) no meio desse fluxo:** quase sempre é o estado do banco, não a consulta — em `single-user maintenance` a segunda conexão é recusada com exatamente essa mensagem (reproduzido no 2.5.9). Confira o `gstat -h` e rode `gfix -online`. Se o banco já está online e o erro persiste num JOIN pesado em `RDB$`, use `SHOW TABLE <nome>;` (uma tabela por vez) para ler a definição das FKs.

## 5. Verificação final

Ao terminar:

```sql
-- Nenhum índice de usuário inativo ou pendente (esperado: 0)
SELECT COUNT(*) FROM RDB$INDICES WHERE COALESCE(RDB$INDEX_INACTIVE, 0) <> 0 AND RDB$SYSTEM_FLAG = 0;

-- Nenhum trigger de usuário desativado sem explicação (esperado: 0 ou documentado)
SELECT COUNT(*) FROM RDB$TRIGGERS WHERE RDB$TRIGGER_INACTIVE = 1 AND COALESCE(RDB$SYSTEM_FLAG, 0) = 0;
```

E rode o `gbak -b` de novo (round-trip) no banco resultante — se passa limpo, está consistente. Siga para procedure 08.

## 6. Observações

- `gbak -c -inactive` é seguro como padrão para restore de banco recuperado — ativar índices depois é trivial e as violações aparecem uma a uma, com a chave.
- Documente o que foi alterado/descartado durante a limpeza (importante para conversar com o usuário sobre integridade de negócio).
- Se houver muitas FKs órfãs (>5% das linhas), volte ao usuário antes de "limpar" — pode ser que ele prefira reverter para backup mais antigo.
