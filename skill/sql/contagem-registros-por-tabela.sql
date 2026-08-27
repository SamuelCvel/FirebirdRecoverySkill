/*
  contagem-registros-por-tabela.sql

  Roda COUNT(*) em cada tabela de usuario e emite uma linha por tabela no formato:
      NOMETABELA|QTD
  Uma tabela que der erro na leitura (corrupcao, permissao, etc.) sai com QTD = -1
  em vez de abortar o script. Isso permite:

    - Rodar em banco degradado sem que uma tabela ruim mate o inventario.
    - Comparar 2 bancos (original x recuperado) via diff simples de duas listas.
    - Somar para conferir se houve perda: SUM(QTD onde QTD >= 0) em ambos.

  USO
  ---
  isql -q -user SYSDBA -password <senha> -i contagem-registros-por-tabela.sql -o counts.txt <banco>

  Depois compare com o outro banco:
    (Get-Content counts-original.txt) -eq (Get-Content counts-recuperado.txt)   # PowerShell
    diff counts-original.txt counts-recuperado.txt                              # bash
*/
SET LIST OFF;
SET HEADING OFF;

SET TERM ^;
EXECUTE BLOCK RETURNS (LINHA VARCHAR(200)) AS
DECLARE VARIABLE R VARCHAR(31);
DECLARE VARIABLE N BIGINT;
BEGIN
  FOR SELECT RDB$RELATION_NAME FROM RDB$RELATIONS
      WHERE RDB$SYSTEM_FLAG = 0 AND RDB$VIEW_BLR IS NULL
      ORDER BY RDB$RELATION_NAME
      INTO :R DO BEGIN
    BEGIN
      EXECUTE STATEMENT 'SELECT COUNT(*) FROM "' || :R || '"' INTO :N;
    WHEN ANY DO
      N = -1;
    END
    LINHA = TRIM(:R) || '|' || CAST(:N AS VARCHAR(20));
    SUSPEND;
  END
END^
SET TERM ;^
