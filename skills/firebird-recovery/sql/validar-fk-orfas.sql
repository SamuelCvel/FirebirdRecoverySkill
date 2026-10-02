/*
  validar-fk-orfas.sql  (v2)
  Conta os registros orfaos de TODAS as FKs do banco, inclusive FK composta.

  Saida: uma linha por FK
      NOME_FK|TABELA_FILHA|TABELA_PAI|ORFAS
  ORFAS = -1 quando a contagem deu erro (tabela ilegivel, por exemplo).

  Regra igual a do engine (MATCH SIMPLE): linha com QUALQUER coluna da FK
  nula nao e orfa. Todas as colunas da FK sao comparadas juntas - validar
  coluna por coluna deixa passar orfaos de FK composta.

  Uso (no banco RESTAURADO e online - ver procedure 08 secao 0):
    isql -q -user SYSDBA -password <senha> -i validar-fk-orfas.sql -o orfas.txt <banco>
  Atencao: -o ANEXA ao arquivo existente - apague o orfas.txt antes.

  Desempenho: depois de um restore com -inactive, ative antes os indices de
  PK/UNIQUE (procedure 05 secao 3); sem eles cada NOT EXISTS varre a tabela pai.
*/
SET LIST OFF;
SET HEADING OFF;
SET TERM ^ ;
EXECUTE BLOCK RETURNS (LINHA VARCHAR(300)) AS
  DECLARE VARIABLE FK     VARCHAR(31);
  DECLARE VARIABLE FILHA  VARCHAR(31);
  DECLARE VARIABLE PAI    VARCHAR(31);
  DECLARE VARIABLE IX_F   VARCHAR(31);
  DECLARE VARIABLE IX_P   VARCHAR(31);
  DECLARE VARIABLE COL_F  VARCHAR(31);
  DECLARE VARIABLE COL_P  VARCHAR(31);
  DECLARE VARIABLE NN     VARCHAR(4000);
  DECLARE VARIABLE CHAVE  VARCHAR(4000);
  DECLARE VARIABLE N      BIGINT;
BEGIN
  FOR SELECT TRIM(RC.RDB$CONSTRAINT_NAME), TRIM(RC.RDB$RELATION_NAME), TRIM(RC.RDB$INDEX_NAME),
             TRIM(RC2.RDB$RELATION_NAME), TRIM(RC2.RDB$INDEX_NAME)
      FROM RDB$RELATION_CONSTRAINTS RC
      JOIN RDB$REF_CONSTRAINTS RF ON RF.RDB$CONSTRAINT_NAME = RC.RDB$CONSTRAINT_NAME
      JOIN RDB$RELATION_CONSTRAINTS RC2 ON RC2.RDB$CONSTRAINT_NAME = RF.RDB$CONST_NAME_UQ
      WHERE RC.RDB$CONSTRAINT_TYPE = 'FOREIGN KEY'
      ORDER BY 2, 1
      INTO :FK, :FILHA, :IX_F, :PAI, :IX_P DO
  BEGIN
    NN = '';
    CHAVE = '';
    FOR SELECT TRIM(SF.RDB$FIELD_NAME), TRIM(SP.RDB$FIELD_NAME)
        FROM RDB$INDEX_SEGMENTS SF
        JOIN RDB$INDEX_SEGMENTS SP
          ON SP.RDB$INDEX_NAME = :IX_P AND SP.RDB$FIELD_POSITION = SF.RDB$FIELD_POSITION
        WHERE SF.RDB$INDEX_NAME = :IX_F
        ORDER BY SF.RDB$FIELD_POSITION
        INTO :COL_F, :COL_P DO
    BEGIN
      IF (NN <> '') THEN
      BEGIN
        NN = NN || ' AND ';
        CHAVE = CHAVE || ' AND ';
      END
      NN = NN || 'F."' || COL_F || '" IS NOT NULL';
      CHAVE = CHAVE || 'P."' || COL_P || '" = F."' || COL_F || '"';
    END

    BEGIN
      EXECUTE STATEMENT 'SELECT COUNT(*) FROM "' || FILHA || '" F WHERE ' || NN ||
                        ' AND NOT EXISTS (SELECT 1 FROM "' || PAI || '" P WHERE ' || CHAVE || ')'
        INTO :N;
      WHEN ANY DO
        N = -1;
    END

    LINHA = FK || '|' || FILHA || '|' || PAI || '|' || CAST(N AS VARCHAR(20));
    SUSPEND;
  END
END^
SET TERM ; ^
