# 05 — Índices e restrições quebrando o restore

**Sintoma característico:** o `gbak -b` (backup) completou bem, mas o `gbak -c` (restore) **para** ao recriar um índice unique, uma primary key, uma foreign key, ou um check constraint. Mensagens típicas:

- `attempt to store duplicate value (visible to active transactions) in unique index "PK_FOO"`
- `violation of FOREIGN KEY constraint "FK_PEDIDO_CLIENTE"`
- `violation of CHECK constraint "CHK_VALOR_POSITIVO"`
- `gbak: ERROR: cannot commit ... operation cannot complete because ...`

A mensagem do erro indica qual constraint quebrou — anote sempre.

**Diagnóstico subjacente:** existem dados inconsistentes no banco corrompido que só viram problema na reconstrução das constraints. Pode ser:
- Duplicatas em campo que era pra ser unique (transação parcial, crash entre INSERT e CHECK).
- FK órfãs (registro pai apagado mas filho permaneceu).
- Valor que viola check (corrupção parcial do dado em página, sobreviveu ao backup com `-ignore`).

## Pré-requisitos

- `.fbk` válido produzido por `Salvage-Backup.ps1` (procedure 04, ou direto se o gbak passou na 1ª).
- Banco destino **não existe ainda** (ou apague antes — `gbak -c` recusa sobrescrever sem `-r`).

## 1. Restore em 2 fases (estratégia padrão)

A ideia: restaurar o dado **sem** ativar constraints/índices, depois ativar e tratar as quebras.

```powershell
$gbak = "C:\Program Files\Firebird\Firebird_2_5\bin\gbak.exe"
$fbk = "<...>.fbk"
$dst = "<RECUPERADO>.fdb"

# Fase 1: restore com índices inativos e commit por tabela
& $gbak -c -v -i -o -user SYSDBA -password masterkey $fbk $dst 2>&1 | Tee-Object "<dst>.restore.log"
```

Flags:
- `-i` (`-inactive`) — recria índices em estado **inactive** (não tenta validar/build).
- `-o` (`-one_at_a_time`) — commit por tabela. Se uma tabela quebra, as anteriores ficam salvas.

Resultado esperado: o `.fdb` foi criado, **todo o dado está dentro**, mas índices estão inactive e constraints (FK/Check) ficam desabilitadas até segunda chamada.

### Fallback se mesmo com -i -o falha

| Falha | Ação |
|---|---|
| Para em tabela X com mensagem genérica | é dado corrupto na tabela, não constraint → **procedure 06** para essa tabela |
| Para com `unsuccessful metadata update` | metadata divergiu; tente `-mo` (metadata only) primeiro: ver seção 4 |
| Para com `out of memory` | aumentar `-bu` (page buffer); ex.: `-bu 10000` |

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
- **Não dá pra decidir?** Documente, marque com prefixo no nome (ex: `DUPLICADO_<id>`) ou move para tabela `LIXEIRA_CLIENTES`, e siga.

Para FK órfãs:

```sql
-- Acha pedidos sem cliente
SELECT P.ID FROM PEDIDO P
LEFT JOIN CLIENTES C ON C.ID = P.ID_CLIENTE
WHERE C.ID IS NULL;
```

Decisão:
- Apagar os órfãos (se aceitável).
- Inserir cliente "stub" (ex.: ID=0, NOME='CLIENTE NAO IDENTIFICADO') e re-apontar os órfãos.

Use `sql/validar-fk-orfas.sql` (gerador automático que percorre `RDB$RELATION_CONSTRAINTS`) para listar tudo de uma vez.

## 3. Ativar índices e constraints

Depois de limpar, ative tudo:

```sql
-- Ativar todos os índices que ficaram inactive
SET TERM ^;
EXECUTE BLOCK AS
DECLARE VARIABLE IX VARCHAR(31);
BEGIN
  FOR SELECT RDB$INDEX_NAME FROM RDB$INDICES
      WHERE RDB$INDEX_INACTIVE = 1 AND RDB$SYSTEM_FLAG = 0
      INTO :IX DO
    EXECUTE STATEMENT 'ALTER INDEX ' || :IX || ' ACTIVE';
END^
SET TERM ;^
COMMIT;
```

Se algum `ALTER INDEX ... ACTIVE` falhar, é porque ainda tem duplicata. Volte ao passo 2 para aquela tabela específica.

### Fallback se um índice não ativa nem após limpeza

- Confira se a tabela tem **trigger BEFORE INSERT** que mexe nos dados — pode estar gerando duplicatas internas.
- Considere recriar o índice com nome novo (DROP + CREATE) — às vezes a metadata do índice inactive carrega lixo.

## 4. Caso especial: metadata-only e merge de dado

Quando a corrupção pegou metadata (drop ainda mais frequente em FB 2.0), tente:

```powershell
# Restore só dos objetos (sem dados)
& $gbak -c -mo -user SYSDBA -password masterkey $fbk $dst
```

`-mo` (`-metadata`) recria estrutura sem inserir registros. Depois, pump os dados via `Salvage-TableByTable.ps1` ou via `INSERT ... SELECT` apontando para o `.fbk` montado em outro banco via `EXECUTE STATEMENT ... ON EXTERNAL` (FB 2.5+ suporta external data sources).

## 5. Verificação final

Ao terminar:

```sql
-- Nenhum índice inactive
SELECT COUNT(*) FROM RDB$INDICES WHERE RDB$INDEX_INACTIVE = 1 AND RDB$SYSTEM_FLAG = 0;
-- esperado: 0

-- Constraints desabilitadas?
SELECT COUNT(*) FROM RDB$TRIGGERS WHERE RDB$TRIGGER_INACTIVE = 1 AND RDB$SYSTEM_FLAG = 0;
-- esperado: 0 (gbak não desabilita triggers, mas se um -mo + -i misturou, pode aparecer)
```

E rode o `gbak -b` de novo (round-trip) no banco resultante — se passa limpo, está consistente. Siga para procedure 08.

## 6. Observações

- `gbak -c -i` é seguro para usar como padrão em qualquer restore de banco recuperado — ativar índices depois é trivial e o relatório de violations sai limpo.
- Documente o que foi alterado/descartado durante a limpeza (importante para conversar com o usuário sobre integridade de negócio).
- Se houver muitas FKs órfãs (>5% das linhas), volte ao usuário antes de "limpar" — pode ser que ele prefira reverter para backup mais antigo.
