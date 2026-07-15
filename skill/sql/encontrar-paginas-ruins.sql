/*
  encontrar-paginas-ruins.sql
  Usa MON$ tables (FB 2.5+) para identificar tabelas suspeitas:
  - Tabelas com I/O recente alto que podem estar problematicas
  - Tabelas com MUITAS leituras vs writes (possivel sweep tentando ler pagina ruim)
  - Tabelas com inserts ou updates falhando
  Rode com o banco em uso normal por alguns minutos antes para ter dados acumulados.
*/
SET LIST ON;

/* 1) Tabelas com mais leituras de pagina (reads vs fetches) */
SELECT FIRST 10
  TRIM(R.MON$RELATION_NAME) AS TABELA,
  S.MON$PAGE_READS         AS PAGES_LIDAS,
  S.MON$PAGE_FETCHES       AS PAGES_FETCH,
  S.MON$RECORD_SEQ_READS   AS REGS_SEQ_LIDOS,
  S.MON$RECORD_IDX_READS   AS REGS_IDX_LIDOS
FROM MON$RECORD_STATS S
JOIN MON$TABLE_STATS T ON T.MON$STAT_ID = S.MON$STAT_ID
JOIN RDB$RELATIONS R   ON R.RDB$RELATION_ID = T.MON$TABLE_ID
WHERE R.RDB$SYSTEM_FLAG = 0
ORDER BY S.MON$PAGE_READS DESC;

/* 2) Operacoes que falharam (record updates/inserts conflitados) */
SELECT FIRST 10
  TRIM(R.MON$RELATION_NAME)      AS TABELA,
  S.MON$RECORD_UPDATES           AS UPDATES,
  S.MON$RECORD_INSERTS           AS INSERTS,
  S.MON$RECORD_DELETES           AS DELETES,
  S.MON$RECORD_CONFLICTS         AS CONFLITOS,
  S.MON$BACKVERSION_READS        AS BACKVERSION_READS
FROM MON$RECORD_STATS S
JOIN MON$TABLE_STATS T ON T.MON$STAT_ID = S.MON$STAT_ID
JOIN RDB$RELATIONS R   ON R.RDB$RELATION_ID = T.MON$TABLE_ID
WHERE R.RDB$SYSTEM_FLAG = 0 AND S.MON$RECORD_CONFLICTS > 0
ORDER BY S.MON$RECORD_CONFLICTS DESC;
