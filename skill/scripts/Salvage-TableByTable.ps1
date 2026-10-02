<#
.SYNOPSIS
  Salvamento tabela-a-tabela quando o gbak para numa tabela especifica.

.DESCRIPTION
  Modos (-Action):

  list            Inventario: COUNT(*) de todas as tabelas de usuario numa unica execucao
                  do isql (sql/contagem-registros-por-tabela.sql). Tabela ilegivel sai com -1.
                  Gera "<Database>.inventario.csv".

  pump            Copia UMA janela de linhas de -Table da origem (-Database) para o destino
                  (-TargetDatabase) via EXECUTE STATEMENT ... ON EXTERNAL, lendo PELA CHAVE
                  PRIMARIA (keyset): WHERE pk > <ultima chave> ORDER BY pk ROWS <Window>.
                  Mostra quantas linhas copiou e a ultima chave; rode de novo com -StartKey
                  para a proxima janela. Se a janela falhar, diminua -Window a partir da mesma
                  chave (procedure 06 secao 3.a). O destino precisa ter o mesmo schema
                  (gbak -c -meta_data -inactive). Nunca usa FIRST/SKIP: o SKIP rele as linhas
                  puladas e bate sempre na mesma pagina ruim.

  skip-bad-table  gbak -b com -skip_data. SO Firebird 3.0+ (no 2.5 o switch nao existe:
                  use a procedure 06).

  Exit codes: 0 ok; 1 parametro invalido; 2 isql/gbak falhou (janela ruim, por exemplo).

.EXAMPLE
  .\Salvage-TableByTable.ps1 -Action list -Database C:\path\COPIA.FDB

  .\Salvage-TableByTable.ps1 -Action pump -Database C:\path\COPIA.FDB `
    -TargetDatabase C:\path\RESGATE.FDB -Table PEDIDO -Window 5000

  .\Salvage-TableByTable.ps1 -Action pump -Database C:\path\COPIA.FDB `
    -TargetDatabase C:\path\RESGATE.FDB -Table PEDIDO -Window 500 -StartKey 120000
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateSet('list','skip-bad-table','pump')][string]$Action,
  [Parameter(Mandatory=$true)][string]$Database,
  [string[]]$SkipTables = @(),
  [string]$Table,
  [int]$Window = 5000,
  [string[]]$StartKey = @(),
  [string]$BackupFile,
  [string]$TargetDatabase,
  [string]$GbakPath = 'C:\Program Files\Firebird\Firebird_2_5\bin\gbak.exe',
  [string]$IsqlPath = 'C:\Program Files\Firebird\Firebird_2_5\bin\isql.exe',
  [string]$User     = 'SYSDBA',
  [string]$Password = 'masterkey'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_FirebirdCommon.ps1')

if(-not (Test-Path -LiteralPath $Database)){ Exit-FbError "Banco nao encontrado: $Database" 1 }
function Quote-Sql([string]$s){ return "'" + $s.Replace("'", "''") + "'" }
function Quote-Id([string]$s){ return '"' + $s.Replace('"', '""') + '"' }

switch($Action){

  'list' {
    $sqlFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'sql\contagem-registros-por-tabela.sql'
    if(-not (Test-Path -LiteralPath $sqlFile)){ Exit-FbError "Nao achei $sqlFile" 1 }
    Write-Host ("==== Inventario  |  {0}" -f $Database) -ForegroundColor Cyan
    $r = Invoke-FbNative -Exe $IsqlPath -Arguments @('-q','-user',$User,'-password',$Password,'-i',$sqlFile,$Database)
    $rows = foreach($l in $r.Lines){
      if($l -match '^\s*(\S+)\|(-?\d+)\s*$'){ [pscustomobject]@{ Tabela = $Matches[1]; Registros = [int64]$Matches[2] } }
    }
    $rows = @($rows)
    if($rows.Count -eq 0){ Write-Host $r.Text; Exit-FbError "isql nao retornou contagens (exit $($r.Exit))." 2 }
    $rows | Format-Table -AutoSize | Out-Host
    $ruins = @($rows | Where-Object { $_.Registros -lt 0 })
    Write-Host ("  Tabelas: {0}  |  registros: {1:N0}  |  ilegiveis (-1): {2}" -f $rows.Count, (($rows | Where-Object Registros -ge 0 | Measure-Object Registros -Sum).Sum), $ruins.Count)
    if($ruins.Count -gt 0){ Write-Host ("  Ilegiveis: {0}" -f (($ruins | ForEach-Object Tabela) -join ', ')) -ForegroundColor Red }
    $csv = "$Database.inventario.csv"
    $rows | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
    Write-Host ("  Inventario salvo: {0}" -f $csv) -ForegroundColor DarkGray
    exit 0
  }

  'skip-bad-table' {
    if(-not $BackupFile){ Exit-FbError "-BackupFile e obrigatorio." 1 }
    if($SkipTables.Count -eq 0){ Exit-FbError "-SkipTables e obrigatorio (pelo menos uma tabela)." 1 }
    # gbak -skip_data so existe a partir do Firebird 3.0. No 2.5 nao existe.
    $ver = Invoke-FbNative -Exe $GbakPath -Arguments @('-z')
    if($ver.Text -match 'V(\d+)\.(\d+)\.' -and [int]$Matches[1] -lt 3){
      Write-Host "  Para Firebird 2.5: siga a procedure 06 (salvar a tabela por chave e dropar numa copia, ou copiar tudo por EDS)." -ForegroundColor Yellow
      Exit-FbError ("-Action skip-bad-table usa '-skip_data', que so existe no Firebird 3.0+. Seu gbak e {0}.{1}." -f $Matches[1], $Matches[2]) 1
    }
    $log = "$BackupFile.log"
    foreach($f in @($BackupFile, $log)){ if(Test-Path -LiteralPath $f){ Remove-Item -LiteralPath $f -Force } }
    $gbakArgs = @('-b','-v','-ignore','-g','-user',$User,'-password',$Password,'-skip_data',($SkipTables -join '|'),'-y',$log,$Database,$BackupFile)
    Write-Host ("==== Salvage com -skip_data: {0}" -f ($SkipTables -join '|')) -ForegroundColor Cyan
    $run = Invoke-FbNative -Exe $GbakPath -Arguments $gbakArgs
    $finishOk = (Test-Path -LiteralPath $log) -and ($null -ne (Select-String -LiteralPath $log -Pattern 'closing file, committing, and finishing'))
    Write-Host ("  gbak exit: {0}  finishing: {1}" -f $run.Exit, $finishOk)
    if($run.Exit -eq 0 -and $finishOk){
      Write-Host ">> Backup parcial OK. Restaure com Restore-Clean.ps1. As tabelas puladas precisam ser repopuladas (-Action pump)." -ForegroundColor Green
      exit 0
    }
    Write-Host ">> Backup falhou. Log: $log" -ForegroundColor Red
    exit 2
  }

  'pump' {
    if(-not $Table){ Exit-FbError "-Table e obrigatorio para pump." 1 }
    if(-not $TargetDatabase -or -not (Test-Path -LiteralPath $TargetDatabase)){ Exit-FbError "-TargetDatabase (destino com o mesmo schema) e obrigatorio e precisa existir." 1 }
    if($Window -lt 1){ Exit-FbError "-Window precisa ser >= 1." 1 }
    $T = $Table.ToUpper()

    # Introspeccao no DESTINO (saudavel, mesmo schema): colunas copiaveis e chave primaria
    $qCols = "SET HEADING OFF;`nSELECT TRIM(RF.RDB`$FIELD_NAME) FROM RDB`$RELATION_FIELDS RF JOIN RDB`$FIELDS F ON F.RDB`$FIELD_NAME = RF.RDB`$FIELD_SOURCE WHERE RF.RDB`$RELATION_NAME = $(Quote-Sql $T) AND F.RDB`$COMPUTED_BLR IS NULL AND F.RDB`$DIMENSIONS IS NULL ORDER BY RF.RDB`$FIELD_POSITION;`n"
    $qPk   = "SET HEADING OFF;`nSELECT TRIM(S.RDB`$FIELD_NAME) FROM RDB`$RELATION_CONSTRAINTS RC JOIN RDB`$INDEX_SEGMENTS S ON S.RDB`$INDEX_NAME = RC.RDB`$INDEX_NAME WHERE RC.RDB`$RELATION_NAME = $(Quote-Sql $T) AND RC.RDB`$CONSTRAINT_TYPE = 'PRIMARY KEY' ORDER BY S.RDB`$FIELD_POSITION;`n"
    $cols = @((Invoke-FbIsql -IsqlPath $IsqlPath -Database $TargetDatabase -Sql $qCols -User $User -Password $Password).Lines | Where-Object { $_ -match '^\s*[A-Za-z0-9_$]+\s*$' } | ForEach-Object { $_.Trim() })
    $pk   = @((Invoke-FbIsql -IsqlPath $IsqlPath -Database $TargetDatabase -Sql $qPk   -User $User -Password $Password).Lines | Where-Object { $_ -match '^\s*[A-Za-z0-9_$]+\s*$' } | ForEach-Object { $_.Trim() })
    if($cols.Count -eq 0){ Exit-FbError "Tabela $T nao encontrada no destino (ou sem colunas copiaveis)." 1 }
    if($pk.Count -eq 0){ Exit-FbError "Tabela $T nao tem chave primaria: use a procedure 06 secao 3.c (RDB`$DB_KEY)." 1 }
    if($StartKey.Count -gt 0 -and $StartKey.Count -ne $pk.Count){ Exit-FbError ("-StartKey precisa de {0} valor(es): {1}" -f $pk.Count, ($pk -join ', ')) 1 }

    # Condicao keyset lexicografica: A >= ? AND (A > ? OR (A = ? AND (B > ? ...)))
    $where = ''; $params = @()
    if($StartKey.Count -gt 0){
      $cond = ''; $pp = @()
      for($i = $pk.Count - 1; $i -ge 0; $i--){
        $c = Quote-Id $pk[$i]
        if($cond -eq ''){ $cond = "$c > ?"; $pp = @($StartKey[$i]) }
        else { $cond = "($c > ? OR ($c = ? AND $cond))"; $pp = @($StartKey[$i], $StartKey[$i]) + $pp }
      }
      $where = " WHERE $(Quote-Id $pk[0]) >= ? AND $cond"
      $params = @($StartKey[0]) + $pp
    }
    $orderBy = ($pk | ForEach-Object { Quote-Id $_ }) -join ', '
    $selList = ($cols | ForEach-Object { Quote-Id $_ }) -join ', '
    $inner = "SELECT $selList FROM $(Quote-Id $T)$where ORDER BY $orderBy ROWS $Window"
    $paramSql = if($params.Count -gt 0){ ' (' + (($params | ForEach-Object { Quote-Sql $_ }) -join ', ') + ')' } else { '' }

    $decl = for($i = 0; $i -lt $cols.Count; $i++){ "  DECLARE V$($i+1) TYPE OF COLUMN $(Quote-Id $T).$(Quote-Id $cols[$i]);" }
    $outs = for($i = 0; $i -lt $pk.Count; $i++){ "ULTIMA_$($i+1) TYPE OF COLUMN $(Quote-Id $T).$(Quote-Id $pk[$i])" }
    $sets = for($i = 0; $i -lt $pk.Count; $i++){ "ULTIMA_$($i+1) = V$([array]::IndexOf($cols, $pk[$i]) + 1);" }
    $into = (1..$cols.Count | ForEach-Object { ":V$_" }) -join ', '
    $sql = @"
SET LIST ON;
SET TERM ^ ;
EXECUTE BLOCK RETURNS (COPIADOS INTEGER, $($outs -join ', ')) AS
$($decl -join "`n")
BEGIN
  COPIADOS = 0;
  FOR EXECUTE STATEMENT ($(Quote-Sql $inner))$paramSql
      ON EXTERNAL $(Quote-Sql $Database) AS USER $(Quote-Sql $User) PASSWORD $(Quote-Sql $Password)
      INTO $into
  DO BEGIN
    INSERT INTO $(Quote-Id $T) ($selList) VALUES ($into);
    COPIADOS = COPIADOS + 1;
    $($sets -join ' ')
  END
  SUSPEND;
END^
SET TERM ; ^
COMMIT;
"@
    Write-Host ("==== Pump por chave  |  {0}  ->  {1}  |  tabela {2}" -f $Database, $TargetDatabase, $T) -ForegroundColor Cyan
    Write-Host ("  chave: {0}  |  inicio: {1}  |  janela: {2}" -f ($pk -join ', '), $(if($StartKey.Count){ $StartKey -join ', ' } else { '(comeco)' }), $Window)
    $r = Invoke-FbIsql -IsqlPath $IsqlPath -Database $TargetDatabase -Sql $sql -User $User -Password $Password -Bail
    $copiados = ($r.Lines | Select-String -Pattern '^\s*COPIADOS\s+(\d+)' | Select-Object -First 1)
    if($r.Exit -ne 0 -or -not $copiados){
      Write-Host $r.Text -ForegroundColor Red
      Write-Host ">> Janela FALHOU (nada desta janela foi gravado). Repita a partir da MESMA chave com -Window menor (5000 -> 500 -> 50 -> 5 -> 1)." -ForegroundColor Yellow
      Write-Host ">> Se ate -Window 1 falhar, a proxima linha esta na regiao ruim: pule a chave (procedure 06 secao 3.a)." -ForegroundColor Yellow
      exit 2
    }
    $n = [int]$copiados.Matches[0].Groups[1].Value
    $ult = for($i = 1; $i -le $pk.Count; $i++){
      $m = $r.Lines | Select-String -Pattern ("^\s*ULTIMA_{0}\s+(.*?)\s*$" -f $i) | Select-Object -First 1
      if($m){ $m.Matches[0].Groups[1].Value }
    }
    Write-Host ("  copiados nesta janela: {0}" -f $n) -ForegroundColor Green
    if($n -eq 0){
      Write-Host ">> Nada mais a copiar a partir desta chave. Tabela concluida (confira contagens)." -ForegroundColor Green
    } else {
      Write-Host ("  ultima chave copiada : {0}" -f ($ult -join ', ')) -ForegroundColor Green
      $next = ($ult | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
      Write-Host ("  proxima janela: -StartKey {0}" -f $next) -ForegroundColor Yellow
    }
    exit 0
  }
}
