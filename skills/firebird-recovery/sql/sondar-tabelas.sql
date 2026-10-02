/*
  sondar-tabelas.sql
  Le TODAS as tabelas de usuario por inteiro (todas as colunas, todos os BLOBs)
  e diz quais estao legiveis. Nao para na primeira tabela ruim, ao contrario do
  gbak, entao mostra de uma vez QUANTOS sitios de corrupcao existem
  (criterio "3+ sitios -> parar cedo" da procedure 04 secao 5b).

  Saida: uma linha por tabela
      TABELA|REGISTROS|STATUS
  STATUS = OK, ou ERRO gdscode=<codigo> (REGISTROS = -1).
  Codigos comuns: 335544335 (banco corrompido), 335544344 (I/O),
  335544336 (deadlock/lock). Detalhes do erro ficam no firebird.log.

  Uso (somente leitura; rode numa COPIA do banco suspeito):
    isql -q -user SYSDBA -password <senha> -i sondar-tabelas.sql -o sonda.txt <banco>
  Atencao: -o ANEXA ao arquivo existente - apague o sonda.txt antes.

  Retomar depois de queda: um erro grave (bugcheck) derruba a conexao e o
  script inteiro para. Veja a ultima tabela no sonda.txt, troque o valor de
  A_PARTIR_DE abaixo por ela e rode de novo (a tabela que derrubou fica de fora).

  Alternativa sem janela de manutencao: validacao online (FB 2.5.4+), por tabela:
    fbsvcmgr service_mgr user SYSDBA password <senha> action_validate dbname <banco>
*/
SET LIST OFF;
SET HEADING OFF;
SET TERM ^ ;
EXECUTE BLOCK RETURNS (LINHA VARCHAR(300)) AS
  DECLARE VARIABLE A_PARTIR_DE VARCHAR(31) = '';   /* retomar: nome da ultima tabela processada */
  DECLARE VARIABLE R    VARCHAR(31);
  DECLARE VARIABLE C    VARCHAR(31);
  DECLARE VARIABLE TIPO SMALLINT;
  DECLARE VARIABLE EXPR VARCHAR(30000) CHARACTER SET NONE;
  DECLARE VARIABLE N    BIGINT;
  DECLARE VARIABLE X    BIGINT;
  DECLARE VARIABLE ST   VARCHAR(60);
BEGIN
  FOR SELECT TRIM(RDB$RELATION_NAME) FROM RDB$RELATIONS
      WHERE COALESCE(RDB$SYSTEM_FLAG, 0) = 0 AND RDB$VIEW_BLR IS NULL AND RDB$EXTERNAL_FILE IS NULL
        AND RDB$RELATION_NAME > :A_PARTIR_DE
      ORDER BY RDB$RELATION_NAME
      INTO :R DO
  BEGIN
    /* COUNT(coluna) obriga a ler o registro inteiro (inclusive fragmentos);
       OCTET_LENGTH(blob) obriga a ler o BLOB. Colunas COMPUTED BY ficam de fora. */
    EXPR = '0';
    FOR SELECT TRIM(RF.RDB$FIELD_NAME), F.RDB$FIELD_TYPE
        FROM RDB$RELATION_FIELDS RF
        JOIN RDB$FIELDS F ON F.RDB$FIELD_NAME = RF.RDB$FIELD_SOURCE
        WHERE RF.RDB$RELATION_NAME = :R AND F.RDB$COMPUTED_BLR IS NULL
        ORDER BY RF.RDB$FIELD_POSITION
        INTO :C, :TIPO DO
    BEGIN
      IF (TIPO = 261) THEN
        EXPR = EXPR || ' + COALESCE(SUM(OCTET_LENGTH("' || C || '")), 0)';
      ELSE
        EXPR = EXPR || ' + COUNT("' || C || '")';
    END

    N = -1;
    ST = 'OK';
    BEGIN
      EXECUTE STATEMENT 'SELECT COUNT(*), ' || EXPR || ' FROM "' || R || '"' INTO :N, :X;
      WHEN ANY DO
      BEGIN
        N = -1;
        ST = 'ERRO gdscode=' || GDSCODE;
      END
    END

    LINHA = R || '|' || CAST(N AS VARCHAR(20)) || '|' || ST;
    SUSPEND;
  END
END^
SET TERM ; ^
