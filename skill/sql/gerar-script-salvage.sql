/*
  gerar-script-salvage.sql
  Gera comandos 'INSERT INTO destino.TABELA SELECT * FROM origem.TABELA;'
  para todas as tabelas de usuario. Use quando recriar metadata em banco
  novo e bombear dados da origem corrompida (procedure 06).

  Para usar:
    1) Conecte na ORIGEM (banco corrompido) com isql.
    2) Rode este script. Ele cospe comandos INSERT em ordem topologica
       aproximada (tabelas sem FKs primeiro).
    3) Edite a saida se preciso (excluir tabelas problematicas, ajustar nomes).
    4) Aplique no DESTINO via isql ou via cliente que aceita duas conexoes.

  ATENCAO: Firebird nao tem 'INSERT FROM <outro banco>' nativo.
  Voce precisara executar SELECT na origem, capturar resultados, e INSERT no destino.
  Em volumes grandes, considere Salvage-TableByTable.ps1 com Window=N.
*/

/* Lista tabelas sem FK saindo (provaveis raizes) primeiro */
SELECT
  '/* ' || TRIM(R.RDB$RELATION_NAME) || ' (sem FK saindo) */' AS COMENTARIO,
  'INSERT INTO DEST."' || TRIM(R.RDB$RELATION_NAME) || '" SELECT * FROM "' ||
  TRIM(R.RDB$RELATION_NAME) || '";' AS COMANDO
FROM RDB$RELATIONS R
WHERE R.RDB$SYSTEM_FLAG = 0
  AND R.RDB$VIEW_BLR IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM RDB$RELATION_CONSTRAINTS RC
    WHERE RC.RDB$RELATION_NAME = R.RDB$RELATION_NAME
      AND RC.RDB$CONSTRAINT_TYPE = 'FOREIGN KEY'
  )
ORDER BY R.RDB$RELATION_NAME;

/* Demais tabelas (tem FK saindo - dependem das raizes) */
SELECT
  '/* ' || TRIM(R.RDB$RELATION_NAME) || ' (depende de outras) */' AS COMENTARIO,
  'INSERT INTO DEST."' || TRIM(R.RDB$RELATION_NAME) || '" SELECT * FROM "' ||
  TRIM(R.RDB$RELATION_NAME) || '";' AS COMANDO
FROM RDB$RELATIONS R
WHERE R.RDB$SYSTEM_FLAG = 0
  AND R.RDB$VIEW_BLR IS NULL
  AND EXISTS (
    SELECT 1 FROM RDB$RELATION_CONSTRAINTS RC
    WHERE RC.RDB$RELATION_NAME = R.RDB$RELATION_NAME
      AND RC.RDB$CONSTRAINT_TYPE = 'FOREIGN KEY'
  )
ORDER BY R.RDB$RELATION_NAME;

/* Generators - capturar valores atuais para reaplicar no destino */
SELECT
  'ALTER SEQUENCE ' || TRIM(G.RDB$GENERATOR_NAME) ||
  ' RESTART WITH ' || CAST(GEN_ID(EVAL(G.RDB$GENERATOR_NAME), 0) AS VARCHAR(20)) || ';' AS GERADOR
FROM RDB$GENERATORS G
WHERE G.RDB$SYSTEM_FLAG = 0
ORDER BY G.RDB$GENERATOR_NAME;
