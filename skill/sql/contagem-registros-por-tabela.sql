/*
  contagem-registros-por-tabela.sql

  Roda COUNT(*) em cada tabela de usuario e emite uma linha por tabela no formato:
      NOMETABELA|QTD
  Uma tabela que der erro na leitura (corrupcao, permissao, etc.) sai com QTD = -1
  em vez de abortar o script. Isso permite:

    - Rodar em banco degradado sem que uma tabela ruim mate o inventario.
    - Comparar 2 bancos (original x recuperado) com diff simples de duas listas.
    - Somar para conferir se houve perda: SUM(QTD onde QTD >= 0) em ambos.

  Limite: um erro que derruba a conexao (bugcheck) interrompe o script inteiro.
  Nesse caso use sql/sondar-tabelas.sql com o driver descrito nele.

  USO
  ---
  isql -q -user SYSDBA -password <senha> -i contagem-registros-por-tabela.sql -o counts.txt <banco>
  Atencao: -o ANEXA ao arquivo existente - apague o counts.txt antes (ou use nome novo).

  Depois compare com o outro banco:
    Compare-Object (Get-Content counts-original.txt) (Get-Content counts-recuperado.txt)   # PowerShell (sem saida = iguais)
    diff counts-original.txt counts-recuperado.txt                                          # bash
*/
SET LIST OFF;
SET HEADING OFF;

SET TERM ^ ;
EXECUTE BLOCK RETURNS (LINHA VARCHAR(200)) AS
DECLARE VARIABLE R VARCHAR(31);
DECLARE VARIABLE N BIGINT;
BEGIN
  FOR SELECT TRIM(RDB$RELATION_NAME) FROM RDB$RELATIONS
      WHERE COALESCE(RDB$SYSTEM_FLAG, 0) = 0 AND RDB$VIEW_BLR IS NULL
      ORDER BY RDB$RELATION_NAME
      INTO :R DO BEGIN
    BEGIN
      EXECUTE STATEMENT 'SELECT COUNT(*) FROM "' || :R || '"' INTO :N;
    WHEN ANY DO
      N = -1;
    END
    LINHA = :R || '|' || CAST(:N AS VARCHAR(20));
    SUSPEND;
  END
END^
SET TERM ; ^
