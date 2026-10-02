/*
  gerar-script-salvage.sql  (v2 - Firebird 2.5 via EXECUTE STATEMENT ... ON EXTERNAL)

  Gera o script que COPIA OS DADOS da ORIGEM (banco corrompido, ou a copia dele)
  para um DESTINO novo com o mesmo schema. Firebird nao tem INSERT entre bancos;
  o script gerado roda no DESTINO e puxa as linhas da ORIGEM por EDS.

  PREPARAR O DESTINO (schema vazio, indices inativos para aceitar qualquer ordem):
    gbak -b -v -m -ignore -g -user SYSDBA -password <senha> <origem> meta.fbk
    gbak -c -v -m -inactive  -user SYSDBA -password <senha> meta.fbk <destino>

  USO
    1) Rode ESTE gerador conectado no DESTINO:
         isql -q -user SYSDBA -password <senha> -i gerar-script-salvage.sql -o copiar.sql <destino>
       (-o ANEXA ao arquivo existente: apague o copiar.sql antes de gerar de novo)
    2) Troque os marcadores (a senha nao fica gravada no gerador):
         (Get-Content copiar.sql) -replace '<ORIGEM>','C:\caminho\origem.fdb' `
           -replace '<USUARIO>','SYSDBA' -replace '<SENHA>',$senha | Set-Content copiar-pronto.sql
    3) Rode no DESTINO, parando no primeiro erro (-b so funciona com -i):
         isql -q -b -e -nod -user SYSDBA -password <senha> -i copiar-pronto.sql -o copiar.log <destino>
    4) Apague o copiar-pronto.sql (contem a senha).
    5) Ative indices e constraints: procedure 05 secao 3 (e trate orfas/duplicatas).

  O SCRIPT GERADO
    - guarda e remove as CHECK de tabela durante a carga e recria no fim, como o gbak
      faz (dado antigo que viola uma CHECK criada depois nao trava o resgate);
      no 2.5 nao da para desativar trigger de CHECK, so remover a constraint;
    - desativa os triggers de tabela ativos (e reativa no fim);
    - copia cada tabela num EXECUTE BLOCK proprio, com COMMIT depois de cada uma;
    - sincroniza os generators com os valores da ORIGEM;
    - pula colunas COMPUTED BY (sao recalculadas) e colunas ARRAY (raras; trate a parte).

  TABELA QUE FALHA (pagina ruim na origem): o -b para nela. Apague o bloco daquela
  tabela do copiar-pronto.sql, rode de novo a partir dela e trate a tabela com o modelo
  por chave (keyset) da procedure 06 secao 3.
*/
SET LIST OFF;
SET HEADING OFF;
SET TERM ^ ;
EXECUTE BLOCK RETURNS (LINHA VARCHAR(250) CHARACTER SET NONE) AS
  DECLARE VARIABLE T   VARCHAR(31);
  DECLARE VARIABLE C   VARCHAR(31);
  DECLARE VARIABLE G   VARCHAR(31);
  DECLARE VARIABLE I   INTEGER;
  DECLARE VARIABLE QTD INTEGER;
BEGIN
  LINHA = '/* Gerado por gerar-script-salvage.sql - rodar no DESTINO com isql -b -i */'; SUSPEND;
  LINHA = 'SET TERM ^ ;'; SUSPEND;

  /* 0) CHECK de tabela: guardar a definicao e remover durante a carga.
        O gbak tambem so cria as CHECK depois dos dados - dado antigo que viola
        uma CHECK criada depois nao pode travar o resgate. */
  LINHA = 'CREATE TABLE ZZ_SALVAGE_CHECKS (TABELA VARCHAR(31), NOME VARCHAR(31), FONTE BLOB SUB_TYPE TEXT)^'; SUSPEND;
  LINHA = 'COMMIT^'; SUSPEND;
  LINHA = 'INSERT INTO ZZ_SALVAGE_CHECKS (TABELA, NOME, FONTE)'; SUSPEND;
  LINHA = '  SELECT TRIM(RC.RDB$RELATION_NAME), TRIM(RC.RDB$CONSTRAINT_NAME), T.RDB$TRIGGER_SOURCE'; SUSPEND;
  LINHA = '  FROM RDB$RELATION_CONSTRAINTS RC'; SUSPEND;
  LINHA = '  JOIN RDB$CHECK_CONSTRAINTS CC ON CC.RDB$CONSTRAINT_NAME = RC.RDB$CONSTRAINT_NAME'; SUSPEND;
  LINHA = '  JOIN RDB$TRIGGERS T ON T.RDB$TRIGGER_NAME = CC.RDB$TRIGGER_NAME AND T.RDB$TRIGGER_TYPE = 1'; SUSPEND;
  LINHA = '  WHERE RC.RDB$CONSTRAINT_TYPE = ''CHECK''^'; SUSPEND;
  LINHA = 'COMMIT^'; SUSPEND;
  LINHA = 'EXECUTE BLOCK AS'; SUSPEND;
  LINHA = '  DECLARE VARIABLE TB VARCHAR(31);'; SUSPEND;
  LINHA = '  DECLARE VARIABLE NM VARCHAR(31);'; SUSPEND;
  LINHA = 'BEGIN'; SUSPEND;
  LINHA = '  FOR SELECT TABELA, NOME FROM ZZ_SALVAGE_CHECKS INTO :TB, :NM DO'; SUSPEND;
  LINHA = '    EXECUTE STATEMENT ''ALTER TABLE "'' || TB || ''" DROP CONSTRAINT "'' || NM || ''"'';'; SUSPEND;
  LINHA = 'END^'; SUSPEND;
  LINHA = 'COMMIT^'; SUSPEND;

  /* 1) triggers de tabela ativos ficam desligados durante a carga */
  FOR SELECT TRIM(RDB$TRIGGER_NAME) FROM RDB$TRIGGERS
      WHERE COALESCE(RDB$SYSTEM_FLAG, 0) = 0 AND RDB$RELATION_NAME IS NOT NULL
        AND COALESCE(RDB$TRIGGER_INACTIVE, 0) = 0
      ORDER BY 1 INTO :G DO
  BEGIN
    LINHA = 'ALTER TRIGGER "' || G || '" INACTIVE^'; SUSPEND;
  END
  LINHA = 'COMMIT^'; SUSPEND;

  /* 2) um bloco de copia por tabela */
  FOR SELECT TRIM(R.RDB$RELATION_NAME) FROM RDB$RELATIONS R
      WHERE COALESCE(R.RDB$SYSTEM_FLAG, 0) = 0 AND R.RDB$VIEW_BLR IS NULL AND R.RDB$EXTERNAL_FILE IS NULL
      ORDER BY 1 INTO :T DO
  BEGIN
    SELECT COUNT(*) FROM RDB$RELATION_FIELDS RF JOIN RDB$FIELDS F ON F.RDB$FIELD_NAME = RF.RDB$FIELD_SOURCE
     WHERE RF.RDB$RELATION_NAME = :T AND F.RDB$COMPUTED_BLR IS NULL AND F.RDB$DIMENSIONS IS NULL
      INTO :QTD;
    IF (QTD > 0) THEN
    BEGIN
      LINHA = ''; SUSPEND;
      LINHA = '/* ' || T || ' */'; SUSPEND;
      LINHA = 'EXECUTE BLOCK RETURNS (TABELA VARCHAR(31), COPIADOS BIGINT) AS'; SUSPEND;
      I = 0;
      FOR SELECT TRIM(RF.RDB$FIELD_NAME) FROM RDB$RELATION_FIELDS RF JOIN RDB$FIELDS F ON F.RDB$FIELD_NAME = RF.RDB$FIELD_SOURCE
          WHERE RF.RDB$RELATION_NAME = :T AND F.RDB$COMPUTED_BLR IS NULL AND F.RDB$DIMENSIONS IS NULL
          ORDER BY RF.RDB$FIELD_POSITION INTO :C DO
      BEGIN
        I = I + 1;
        LINHA = '  DECLARE V' || I || ' TYPE OF COLUMN "' || T || '"."' || C || '";'; SUSPEND;
      END
      LINHA = 'BEGIN'; SUSPEND;
      LINHA = '  TABELA = ''' || T || '''; COPIADOS = 0;'; SUSPEND;
      LINHA = '  FOR EXECUTE STATEMENT (''SELECT '''; SUSPEND;
      I = 0;
      FOR SELECT TRIM(RF.RDB$FIELD_NAME) FROM RDB$RELATION_FIELDS RF JOIN RDB$FIELDS F ON F.RDB$FIELD_NAME = RF.RDB$FIELD_SOURCE
          WHERE RF.RDB$RELATION_NAME = :T AND F.RDB$COMPUTED_BLR IS NULL AND F.RDB$DIMENSIONS IS NULL
          ORDER BY RF.RDB$FIELD_POSITION INTO :C DO
      BEGIN
        I = I + 1;
        IF (I = 1) THEN LINHA = '      || ''"' || C || '"'''; ELSE LINHA = '      || '', "' || C || '"''';
        SUSPEND;
      END
      LINHA = '      || '' FROM "' || T || '"'')'; SUSPEND;
      LINHA = '      ON EXTERNAL ''<ORIGEM>'' AS USER ''<USUARIO>'' PASSWORD ''<SENHA>'''; SUSPEND;
      I = 0;
      WHILE (I < QTD) DO
      BEGIN
        I = I + 1;
        IF (I = 1) THEN LINHA = '      INTO :V1'; ELSE LINHA = '         , :V' || I;
        SUSPEND;
      END
      LINHA = '  DO BEGIN'; SUSPEND;
      LINHA = '    INSERT INTO "' || T || '" ('; SUSPEND;
      I = 0;
      FOR SELECT TRIM(RF.RDB$FIELD_NAME) FROM RDB$RELATION_FIELDS RF JOIN RDB$FIELDS F ON F.RDB$FIELD_NAME = RF.RDB$FIELD_SOURCE
          WHERE RF.RDB$RELATION_NAME = :T AND F.RDB$COMPUTED_BLR IS NULL AND F.RDB$DIMENSIONS IS NULL
          ORDER BY RF.RDB$FIELD_POSITION INTO :C DO
      BEGIN
        I = I + 1;
        IF (I = 1) THEN LINHA = '        "' || C || '"'; ELSE LINHA = '      , "' || C || '"';
        SUSPEND;
      END
      LINHA = '    ) VALUES ('; SUSPEND;
      I = 0;
      WHILE (I < QTD) DO
      BEGIN
        I = I + 1;
        IF (I = 1) THEN LINHA = '        :V1'; ELSE LINHA = '      , :V' || I;
        SUSPEND;
      END
      LINHA = '    );'; SUSPEND;
      LINHA = '    COPIADOS = COPIADOS + 1;'; SUSPEND;
      LINHA = '  END'; SUSPEND;
      LINHA = '  SUSPEND;'; SUSPEND;
      LINHA = 'END^'; SUSPEND;
      LINHA = 'COMMIT^'; SUSPEND;
    END
  END

  /* 3) generators: mesmo valor da ORIGEM */
  LINHA = ''; SUSPEND;
  LINHA = '/* generators */'; SUSPEND;
  LINHA = 'EXECUTE BLOCK RETURNS (GERADOR VARCHAR(31), VALOR BIGINT) AS'; SUSPEND;
  LINHA = '  DECLARE VARIABLE ATUAL BIGINT;'; SUSPEND;
  LINHA = 'BEGIN'; SUSPEND;
  LINHA = '  FOR SELECT TRIM(RDB$GENERATOR_NAME) FROM RDB$GENERATORS'; SUSPEND;
  LINHA = '      WHERE COALESCE(RDB$SYSTEM_FLAG, 0) = 0 INTO :GERADOR DO'; SUSPEND;
  LINHA = '  BEGIN'; SUSPEND;
  LINHA = '    EXECUTE STATEMENT ''SELECT GEN_ID("'' || GERADOR || ''", 0) FROM RDB$DATABASE'''; SUSPEND;
  LINHA = '      ON EXTERNAL ''<ORIGEM>'' AS USER ''<USUARIO>'' PASSWORD ''<SENHA>'' INTO :VALOR;'; SUSPEND;
  LINHA = '    EXECUTE STATEMENT ''SELECT GEN_ID("'' || GERADOR || ''", 0) FROM RDB$DATABASE'' INTO :ATUAL;'; SUSPEND;
  LINHA = '    EXECUTE STATEMENT ''SELECT GEN_ID("'' || GERADOR || ''", '' || (VALOR - ATUAL) || '') FROM RDB$DATABASE'' INTO :ATUAL;'; SUSPEND;
  LINHA = '    SUSPEND;'; SUSPEND;
  LINHA = '  END'; SUSPEND;
  LINHA = 'END^'; SUSPEND;
  LINHA = 'COMMIT^'; SUSPEND;

  /* 4) recriar as CHECK de tabela removidas no passo 0 (o Firebird nao revalida linhas antigas) */
  LINHA = ''; SUSPEND;
  LINHA = '/* CHECK de tabela */'; SUSPEND;
  LINHA = 'EXECUTE BLOCK RETURNS (CONSTRAINT_RECRIADA VARCHAR(31)) AS'; SUSPEND;
  LINHA = '  DECLARE VARIABLE TB VARCHAR(31);'; SUSPEND;
  LINHA = '  DECLARE VARIABLE FT VARCHAR(8000);'; SUSPEND;
  LINHA = 'BEGIN'; SUSPEND;
  LINHA = '  FOR SELECT TABELA, NOME, CAST(FONTE AS VARCHAR(8000)) FROM ZZ_SALVAGE_CHECKS'; SUSPEND;
  LINHA = '      INTO :TB, :CONSTRAINT_RECRIADA, :FT DO'; SUSPEND;
  LINHA = '  BEGIN'; SUSPEND;
  LINHA = '    EXECUTE STATEMENT ''ALTER TABLE "'' || TB || ''" ADD CONSTRAINT "'' || CONSTRAINT_RECRIADA || ''" '' || FT;'; SUSPEND;
  LINHA = '    SUSPEND;'; SUSPEND;
  LINHA = '  END'; SUSPEND;
  LINHA = 'END^'; SUSPEND;
  LINHA = 'COMMIT^'; SUSPEND;
  LINHA = 'DROP TABLE ZZ_SALVAGE_CHECKS^'; SUSPEND;
  LINHA = 'COMMIT^'; SUSPEND;

  /* 5) religar os triggers desligados no passo 1 */
  LINHA = ''; SUSPEND;
  FOR SELECT TRIM(RDB$TRIGGER_NAME) FROM RDB$TRIGGERS
      WHERE COALESCE(RDB$SYSTEM_FLAG, 0) = 0 AND RDB$RELATION_NAME IS NOT NULL
        AND COALESCE(RDB$TRIGGER_INACTIVE, 0) = 0
      ORDER BY 1 INTO :G DO
  BEGIN
    LINHA = 'ALTER TRIGGER "' || G || '" ACTIVE^'; SUSPEND;
  END
  LINHA = 'COMMIT^'; SUSPEND;
  LINHA = 'SET TERM ; ^'; SUSPEND;
END^
SET TERM ; ^
