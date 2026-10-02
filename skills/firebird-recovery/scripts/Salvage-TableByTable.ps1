<#
.SYNOPSIS
  Salvamento tabela-a-tabela quando o gbak para numa tabela especifica.

.DESCRIPTION
  Modos (-Action):

  list            Inventario: COUNT(*) de todas as tabelas de usuario numa unica execucao
                  do isql (sql/contagem-registros-por-tabela.sql). Tabela ilegivel sai com -1.
                  Gera "<Database>.inventario.csv".

  pump            Copia linhas de -Table da origem (-Database) para o destino (-TargetDatabase)
                  via EXECUTE STATEMENT ... ON EXTERNAL, lendo PELA CHAVE PRIMARIA (keyset):
                  WHERE pk > <ultima chave> ORDER BY pk ROWS <Window>. Nunca usa FIRST/SKIP (o SKIP
                  rele as linhas puladas e bate sempre na mesma pagina ruim). O destino precisa ter o
                  mesmo schema (gbak -c -meta_data -inactive).
                    Sem -Auto: copia UMA janela e mostra a ultima chave (rode de novo com -StartKey).
                    Com -Auto: repete ate o fim da tabela. Janela que falha encolhe (5000 -> 500 -> 50
                    -> 5 -> 1); quando ate 1 linha falha, pula a regiao ruim procurando a proxima chave
                    legivel na ULTIMA coluna da PK (precisa ser numerica): busca exponencial + bisseccao
                    direto na origem. Em PK composta, se o resto do prefixo for ilegivel, salta para o
                    proximo prefixo. Faixas perdidas vao para "<TargetDatabase>.pump.<TABELA>.csv".
                    Se a chave nao for numerica (ou o salto nao achar nada em -MaxGap), para e diz onde.

  skip-bad-table  gbak -b com -skip_data. SO Firebird 3.0+ (no 2.5 o switch nao existe:
                  use a procedure 06).

  Exit codes: 0 ok (no -Auto: tabela concluida, mesmo com faixas perdidas); 1 parametro invalido;
  2 isql/gbak falhou ou o -Auto parou sem conseguir pular.

.EXAMPLE
  .\Salvage-TableByTable.ps1 -Action list -Database C:\path\COPIA.FDB

  .\Salvage-TableByTable.ps1 -Action pump -Database C:\path\COPIA.FDB `
    -TargetDatabase C:\path\RESGATE.FDB -Table PEDIDO -Auto

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
  [switch]$Auto,
  [decimal]$MaxGap = 1000000,
  [string]$ReportFile,
  [string]$BackupFile,
  [string]$TargetDatabase,
  [string]$GbakPath = 'C:\Program Files\Firebird\Firebird_2_5\bin\gbak.exe',
  [string]$IsqlPath = 'C:\Program Files\Firebird\Firebird_2_5\bin\isql.exe',
  [string]$User     = $(if($env:ISC_USER){ $env:ISC_USER } else { 'SYSDBA' }),
  [string]$Password = $(if($env:ISC_PASSWORD){ $env:ISC_PASSWORD } else { 'masterkey' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_FirebirdCommon.ps1')
$GbakPath = Resolve-FbToolPath 'gbak' $GbakPath
$IsqlPath = Resolve-FbToolPath 'isql' $IsqlPath

if(-not (Test-Path -LiteralPath $Database)){ Exit-FbError "Banco nao encontrado: $Database" 1 }
$inv = [Globalization.CultureInfo]::InvariantCulture
function Quote-Sql([string]$s){ return "'" + $s.Replace("'", "''") + "'" }
function Quote-Id([string]$s){ return '"' + $s.Replace('"', '""') + '"' }

switch($Action){

  'list' {
    $sqlFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'sql\contagem-registros-por-tabela.sql'
    if(-not (Test-Path -LiteralPath $sqlFile)){ Exit-FbError "Nao achei $sqlFile" 1 }
    Write-Host ("==== Inventario  |  {0}" -f $Database) -ForegroundColor Cyan
    $r = Invoke-FbNative -Exe $IsqlPath -Arguments @('-q','-i',$sqlFile,$Database) -User $User -Password $Password
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
    $gbakArgs = @('-b','-v','-ignore','-g','-skip_data',($SkipTables -join '|'),'-y',$log,$Database,$BackupFile)
    Write-Host ("==== Salvage com -skip_data: {0}" -f ($SkipTables -join '|')) -ForegroundColor Cyan
    $run = Invoke-FbNative -Exe $GbakPath -Arguments $gbakArgs -User $User -Password $Password
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

    # ---- introspeccao no DESTINO (saudavel, mesmo schema) ----
    $qCols = "SET HEADING OFF;`nSELECT TRIM(RF.RDB`$FIELD_NAME) FROM RDB`$RELATION_FIELDS RF JOIN RDB`$FIELDS F ON F.RDB`$FIELD_NAME = RF.RDB`$FIELD_SOURCE WHERE RF.RDB`$RELATION_NAME = $(Quote-Sql $T) AND F.RDB`$COMPUTED_BLR IS NULL AND F.RDB`$DIMENSIONS IS NULL ORDER BY RF.RDB`$FIELD_POSITION;`n"
    $qPk   = "SET HEADING OFF;`nSELECT TRIM(S.RDB`$FIELD_NAME) FROM RDB`$RELATION_CONSTRAINTS RC JOIN RDB`$INDEX_SEGMENTS S ON S.RDB`$INDEX_NAME = RC.RDB`$INDEX_NAME WHERE RC.RDB`$RELATION_NAME = $(Quote-Sql $T) AND RC.RDB`$CONSTRAINT_TYPE = 'PRIMARY KEY' ORDER BY S.RDB`$FIELD_POSITION;`n"
    $cols = @((Invoke-FbIsql -IsqlPath $IsqlPath -Database $TargetDatabase -Sql $qCols -User $User -Password $Password).Lines | Where-Object { $_ -match '^\s*[A-Za-z0-9_$]+\s*$' } | ForEach-Object { $_.Trim() })
    $pk   = @((Invoke-FbIsql -IsqlPath $IsqlPath -Database $TargetDatabase -Sql $qPk   -User $User -Password $Password).Lines | Where-Object { $_ -match '^\s*[A-Za-z0-9_$]+\s*$' } | ForEach-Object { $_.Trim() })
    if($cols.Count -eq 0){ Exit-FbError "Tabela $T nao encontrada no destino (ou sem colunas copiaveis)." 1 }
    if($pk.Count -eq 0){ Exit-FbError "Tabela $T nao tem chave primaria: use a procedure 06 secao 3.c (RDB`$DB_KEY)." 1 }
    if($StartKey.Count -gt 0 -and $StartKey.Count -ne $pk.Count){ Exit-FbError ("-StartKey precisa de {0} valor(es): {1}" -f $pk.Count, ($pk -join ', ')) 1 }
    $lastCol = $pk[$pk.Count - 1]
    # tipo de cada coluna da PK: numerica (7 smallint, 8 integer, 16 bigint/numeric, 10 float, 27 double)
    # e inteira (7/8/16 com escala 0)
    $qTipos = "SET HEADING OFF;`nSELECT 'TIPO|' || TRIM(RF.RDB`$FIELD_NAME) || '|' || F.RDB`$FIELD_TYPE || '|' || COALESCE(F.RDB`$FIELD_SCALE, 0) FROM RDB`$RELATION_FIELDS RF JOIN RDB`$FIELDS F ON F.RDB`$FIELD_NAME = RF.RDB`$FIELD_SOURCE WHERE RF.RDB`$RELATION_NAME = $(Quote-Sql $T);`n"
    $pkNum = @{}; $pkInt = @{}
    foreach($l in (Invoke-FbIsql -IsqlPath $IsqlPath -Database $TargetDatabase -Sql $qTipos -User $User -Password $Password).Lines){
      if($l -match '^\s*TIPO\|([^|]+)\|(\d+)\|(-?\d+)'){
        $pkNum[$Matches[1]] = @('7','8','16','10','27') -contains $Matches[2]
        $pkInt[$Matches[1]] = (@('7','8','16') -contains $Matches[2]) -and ($Matches[3] -eq '0')
      }
    }
    $lastNumeric  = [bool]$pkNum[$lastCol]
    $firstNumeric = [bool]$pkNum[$pk[0]]

    $orderBy = ($pk | ForEach-Object { Quote-Id $_ }) -join ', '
    $selList = ($cols | ForEach-Object { Quote-Id $_ }) -join ', '
    $decl = for($i = 0; $i -lt $cols.Count; $i++){ "  DECLARE V$($i+1) TYPE OF COLUMN $(Quote-Id $T).$(Quote-Id $cols[$i]);" }
    $outs = for($i = 0; $i -lt $pk.Count; $i++){ "ULTIMA_$($i+1) TYPE OF COLUMN $(Quote-Id $T).$(Quote-Id $pk[$i])" }
    $sets = for($i = 0; $i -lt $pk.Count; $i++){ "ULTIMA_$($i+1) = V$([array]::IndexOf($cols, $pk[$i]) + 1);" }
    $into = (1..$cols.Count | ForEach-Object { ":V$_" }) -join ', '

    # condicao "coluna depois de v". Em coluna INTEIRA vira '>= v+1': no FB 2.5 um '>' sobre so parte de
    # um indice composto (ex.: EMP > 2 no indice EMP,COD) ainda le os registros de EMP = 2 - verificado no
    # 2.5.9 - e bate na pagina ruim que acabou de ser pulada; '>= 3' posiciona certo.
    function Get-AfterCond([string]$col, [string]$v, [bool]$asParam){
      if($pkInt[$col]){
        $nv = ([decimal]::Parse($v, $inv) + 1).ToString($inv)
        if($asParam){ return [pscustomobject]@{ Sql = "$(Quote-Id $col) >= ?"; Param = $nv } }
        return [pscustomobject]@{ Sql = "$(Quote-Id $col) >= $(Quote-Sql $nv)"; Param = $nv }
      }
      if($asParam){ return [pscustomobject]@{ Sql = "$(Quote-Id $col) > ?"; Param = $v } }
      return [pscustomobject]@{ Sql = "$(Quote-Id $col) > $(Quote-Sql $v)"; Param = $v }
    }

    # (chave) > (valores) decomposto em faixas que o INDICE consegue posicionar, da mais fina para a
    # mais grossa:  A=a AND B=b AND C>c  |  A=a AND B>b  |  A>a
    # No FB 2.5 nao ha comparacao de linha: um 'A>=a AND (A>a OR (A=a AND B>b))' so posiciona em A=a e
    # rele o prefixo desde o comeco - batendo de novo na pagina ruim. Cada faixa aqui comeca no ponto certo.
    function Get-KeysetLevels([string[]]$kc, [string[]]$kv){
      $levels = @()
      for($j = $kc.Count - 1; $j -ge 0; $j--){
        $partsP = @(); $partsL = @(); $params = @()
        for($i = 0; $i -lt $j; $i++){
          $partsP += "$(Quote-Id $kc[$i]) = ?"; $partsL += "$(Quote-Id $kc[$i]) = $(Quote-Sql $kv[$i])"; $params += $kv[$i]
        }
        $cp = Get-AfterCond $kc[$j] $kv[$j] $true
        $cl = Get-AfterCond $kc[$j] $kv[$j] $false
        $partsP += $cp.Sql; $partsL += $cl.Sql; $params += $cp.Param
        $levels += [pscustomobject]@{ SqlParams = ($partsP -join ' AND '); SqlLiteral = ($partsL -join ' AND '); Params = $params }
      }
      return ,$levels
    }

    function Invoke-PumpWindow([string[]]$start, [int]$rows){
      $passos = @()
      if($start -and $start.Count -gt 0){
        foreach($lv in (Get-KeysetLevels $pk $start)){
          $p = ' (' + (($lv.Params | ForEach-Object { Quote-Sql $_ }) -join ', ') + ')'
          $passos += [pscustomobject]@{ Where = " WHERE $($lv.SqlParams)"; Params = $p }
        }
      } else {
        $passos += [pscustomobject]@{ Where = ''; Params = '' }
      }
      $loops = foreach($ps in $passos){
        $inner = "SELECT $selList FROM $(Quote-Id $T)$($ps.Where) ORDER BY $orderBy ROWS "
@"
  IF (RESTANTE > 0) THEN
  FOR EXECUTE STATEMENT ($(Quote-Sql $inner) || RESTANTE)$($ps.Params)
      ON EXTERNAL $(Quote-Sql $Database) AS USER $(Quote-Sql $User) PASSWORD $(Quote-Sql $Password)
      INTO $into
  DO BEGIN
    INSERT INTO $(Quote-Id $T) ($selList) VALUES ($into);
    COPIADOS = COPIADOS + 1;
    RESTANTE = RESTANTE - 1;
    $($sets -join ' ')
  END
"@
      }
      $sql = @"
SET LIST ON;
SET TERM ^ ;
EXECUTE BLOCK RETURNS (COPIADOS INTEGER, $($outs -join ', ')) AS
$($decl -join "`n")
  DECLARE RESTANTE INTEGER;
BEGIN
  COPIADOS = 0;
  RESTANTE = $rows;
$($loops -join "`n")
  SUSPEND;
END^
SET TERM ; ^
COMMIT;
"@
      $r = Invoke-FbIsql -IsqlPath $IsqlPath -Database $TargetDatabase -Sql $sql -User $User -Password $Password -Bail
      $cop = $r.Lines | Select-String -Pattern '^\s*COPIADOS\s+(\d+)' | Select-Object -First 1
      if($r.Exit -ne 0 -or -not $cop){
        return [pscustomobject]@{ Ok = $false; Copied = 0; Last = $null; Error = (Get-FbErrorSummary $r.Lines); Corrupcao = (Test-FbCorruptionError $r.Text) }
      }
      $n = [int]$cop.Matches[0].Groups[1].Value
      $ult = $null
      if($n -gt 0){
        $ult = @(for($i = 1; $i -le $pk.Count; $i++){
          $m = $r.Lines | Select-String -Pattern ("^\s*ULTIMA_{0}\s+(.*?)\s*$" -f $i) | Select-Object -First 1
          if($m){ $m.Matches[0].Groups[1].Value }
        })
      }
      return [pscustomobject]@{ Ok = $true; Copied = $n; Last = $ult; Error = $null }
    }

    # le, direto na ORIGEM, a primeira chave que satisfaz $whereSql (sem copiar nada)
    function Invoke-Probe([string]$whereSql){
      $sql = "SET LIST ON;`nSELECT FIRST 1 $orderBy FROM $(Quote-Id $T) WHERE $whereSql ORDER BY $orderBy;`n"
      $r = Invoke-FbIsql -IsqlPath $IsqlPath -Database $Database -Sql $sql -User $User -Password $Password -Bail
      Write-Verbose ("sonda [{0}] -> exit {1}" -f $whereSql, $r.Exit)
      if($r.Exit -ne 0){
        if(Test-FbCorruptionError $r.Text){ return [pscustomobject]@{ Ok = $false; Key = $null } }
        # erro que nao e de corrupcao (SQL, login, permissao): pular registros aqui perderia dado bom
        Exit-FbError ("Sonda falhou com erro que NAO e de pagina danificada - parei para nao descartar dados: {0}" -f (Get-FbErrorSummary $r.Lines)) 2
      }
      $vals = @()
      foreach($c in $pk){
        $m = $r.Lines | Select-String -Pattern ("^\s*{0}\s+(.*?)\s*$" -f [regex]::Escape($c)) | Select-Object -First 1
        if($m){ $vals += $m.Matches[0].Groups[1].Value }
      }
      if($vals.Count -eq $pk.Count){ return [pscustomobject]@{ Ok = $true; Key = $vals } }
      return [pscustomobject]@{ Ok = $true; Key = $null }
    }

    # primeira chave legivel depois de (kc) = (kv), faixa por faixa (mais fina primeiro)
    function Invoke-ProbeAfter([string[]]$kc, [string[]]$kv){
      foreach($lv in (Get-KeysetLevels $kc $kv)){
        $p = Invoke-Probe $lv.SqlLiteral
        if(-not $p.Ok){ return $p }           # o primeiro registro desta faixa e ilegivel
        if($p.Key){ return $p }
      }
      return [pscustomobject]@{ Ok = $true; Key = $null }   # nada depois: fim da tabela
    }

    # Dentro do prefixo $pv (valores das colunas da PK menos a ultima), procura a primeira chave
    # legivel depois de $b na ultima coluna: busca exponencial + bisseccao (probe(lo) falha, probe(hi) funciona).
    # Estado: 'achou' (Hi = recomecar depois de Hi), 'vazio' (o prefixo nao tem mais linhas), 'nada' (nada legivel ate MaxGap).
    function Search-InPrefix([string[]]$pv, [decimal]$b){
      [string[]]$pc = @(if($pk.Count -gt 1){ $pk[0..($pk.Count - 2)] })
      $eq = (@(for($i = 0; $i -lt $pc.Count; $i++){ "$(Quote-Id $pc[$i]) = $(Quote-Sql $pv[$i])" }) -join ' AND ')
      $probeLast = {
        param([decimal]$x)
        $w = "$(Quote-Id $lastCol) > $(Quote-Sql $x.ToString($inv))"
        if($eq){ $w = "$eq AND $w" }
        Invoke-Probe $w
      }
      $d = [decimal]1; $hi = $null
      while($d -le $MaxGap){
        $p = & $probeLast ($b + $d)
        if($p.Ok){ if($p.Key){ $hi = $b + $d; break } else { return [pscustomobject]@{ Estado = 'vazio'; Hi = $null } } }
        $d = $d * 2
      }
      if($null -eq $hi){ return [pscustomobject]@{ Estado = 'nada'; Hi = $null } }
      $lo = $b
      while(($hi - $lo) -gt 1){
        $mid = [decimal]::Floor(($lo + $hi) / 2)
        $p = & $probeLast $mid
        if($p.Ok){ $hi = $mid } else { $lo = $mid }
      }
      return [pscustomobject]@{ Estado = 'achou'; Hi = $hi }
    }

    # janela de 1 linha falhou a partir de $cur: acha onde recomecar
    function Find-NextStart([string[]]$cur){
      if(-not $lastNumeric){ return $null }
      $n = $pk.Count
      if((-not $cur -or $cur.Count -eq 0) -and $n -gt 1){ return $null }
      [string[]]$prefCols = @(if($n -gt 1){ $pk[0..($n - 2)] })
      [string[]]$prefVals = @(if($n -gt 1){ $cur[0..($n - 2)] })
      $b = if($cur -and $cur.Count -gt 0){ [decimal]::Parse($cur[$n - 1], $inv) } else { [decimal]-1 }   # sem inicio: supoe chaves >= 0
      $de = if($cur -and $cur.Count){ $cur -join ', ' } else { '(comeco)' }
      $fim = [pscustomobject]@{ Fim = $true; Next = $null; De = $de; Ate = '(fim da tabela)'; Motivo = 'registros ilegiveis ate o fim' }

      # 1) no mesmo prefixo
      $r = Search-InPrefix $prefVals $b
      if($r.Estado -eq 'achou'){
        $nx = @($prefVals + @($r.Hi.ToString($inv)))
        return [pscustomobject]@{ Fim = $false; Next = $nx; De = $de; Ate = ($nx -join ', '); Motivo = 'registros ilegiveis' }
      }
      if($n -eq 1){ if($r.Estado -eq 'vazio'){ return $fim }; return $null }

      # 2) resto do prefixo ilegivel ou acabou: proximo prefixo
      $p = Invoke-ProbeAfter $prefCols $prefVals
      if($p.Ok -and $p.Key){
        $k2 = $p.Key
        $antes = ([decimal]::Parse($k2[$n - 1], $inv) - 1).ToString($inv)
        return [pscustomobject]@{ Fim = $false; Next = @(@($k2[0..($n - 2)]) + @($antes)); De = $de; Ate = ('antes de ' + ($k2 -join ', ')); Motivo = 'resto do prefixo ilegivel' }
      }
      if($p.Ok){ return $fim }

      # 3) o comeco do proximo prefixo tambem e ilegivel: PK de 2 colunas numericas -> tenta a+1, a+2, ...
      if($n -eq 2 -and $firstNumeric){
        $a = [decimal]::Parse($prefVals[0], $inv)
        for($da = 1; $da -le 200; $da++){   # prefixos (ex.: empresa) costumam ser numeros pequenos
          $a2 = ($a + $da).ToString($inv)
          $r2 = Search-InPrefix @($a2) ([decimal]-1)
          if($r2.Estado -eq 'achou'){
            $nx = @($a2, $r2.Hi.ToString($inv))
            return [pscustomobject]@{ Fim = $false; Next = $nx; De = $de; Ate = ($nx -join ', '); Motivo = 'registros ilegiveis (atravessando prefixos)' }
          }
          if($r2.Estado -eq 'vazio'){
            $p3 = Invoke-Probe (Get-AfterCond $pk[0] $a2 $false).Sql
            if($p3.Ok -and -not $p3.Key){ return $fim }
            if($p3.Ok -and $p3.Key){
              $antes = ([decimal]::Parse($p3.Key[1], $inv) - 1).ToString($inv)
              return [pscustomobject]@{ Fim = $false; Next = @($p3.Key[0], $antes); De = $de; Ate = ('antes de ' + ($p3.Key -join ', ')); Motivo = 'registros ilegiveis (atravessando prefixos)' }
            }
          }
        }
      }
      return $null
    }

    Write-Host ("==== Pump por chave  |  {0}  ->  {1}  |  tabela {2}" -f $Database, $TargetDatabase, $T) -ForegroundColor Cyan
    Write-Host ("  chave: {0} (ultima coluna {1})  |  inicio: {2}  |  janela: {3}{4}" -f ($pk -join ', '), $(if($lastNumeric){'numerica'}else{'nao numerica'}), $(if($StartKey.Count){ $StartKey -join ', ' } else { '(comeco)' }), $Window, $(if($Auto){'  |  modo automatico'}else{''}))

    if(-not $Auto){
      $r = Invoke-PumpWindow $StartKey $Window
      if(-not $r.Ok){
        Write-Host $r.Error -ForegroundColor Red
        if(-not $r.Corrupcao){
          Write-Host ">> A janela falhou por um erro que NAO e de pagina danificada (SQL, login, constraint no destino...). Corrija a causa antes de continuar." -ForegroundColor Yellow
          exit 2
        }
        Write-Host ">> Janela FALHOU (nada desta janela foi gravado). Repita a partir da MESMA chave com -Window menor (5000 -> 500 -> 50 -> 5 -> 1), ou use -Auto." -ForegroundColor Yellow
        Write-Host ">> Se ate -Window 1 falhar, a proxima linha esta na regiao ruim: pule a chave (procedure 06 secao 3.a) ou use -Auto." -ForegroundColor Yellow
        exit 2
      }
      Write-Host ("  copiados nesta janela: {0}" -f $r.Copied) -ForegroundColor Green
      if($r.Copied -eq 0){ Write-Host ">> Nada mais a copiar a partir desta chave. Tabela concluida (confira contagens)." -ForegroundColor Green }
      else {
        Write-Host ("  ultima chave copiada : {0}" -f ($r.Last -join ', ')) -ForegroundColor Green
        Write-Host ("  proxima janela: -StartKey {0}" -f (($r.Last | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ',')) -ForegroundColor Yellow
      }
      exit 0
    }

    # ---- modo automatico ----
    if(-not $ReportFile){ $ReportFile = "$TargetDatabase.pump.$T.csv" }
    $rel = New-Object System.Collections.Generic.List[object]
    $cur = @($StartKey); $w = $Window; $total = 0; $janelas = 0; $parou = $null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while($true){
      $janelas++
      $r = Invoke-PumpWindow $cur $w
      if($r.Ok){
        if($r.Copied -eq 0){ break }
        $total += $r.Copied
        $rel.Add([pscustomobject]@{ Tipo = 'copiado'; De = ($cur -join ', '); Ate = ($r.Last -join ', '); Linhas = $r.Copied; Detalhe = "janela $w" })
        Write-Host ("  janela {0,4}: +{1} (total {2:N0})  ate {3}" -f $janelas, $r.Copied, $total, ($r.Last -join ', ')) -ForegroundColor DarkGray
        $cur = @($r.Last)
        if($w -lt $Window){ $w = [Math]::Min($Window, $w * 10) }
        continue
      }
      if(-not $r.Corrupcao){
        # so dano fisico justifica encolher/pular; qualquer outro erro para tudo (nao descarta dado bom)
        $parou = "parou em {0}: erro que NAO e de pagina danificada: {1}" -f $(if($cur.Count){ $cur -join ', ' }else{'(comeco)'}), $r.Error
        $rel.Add([pscustomobject]@{ Tipo = 'parou'; De = ($cur -join ', '); Ate = ''; Linhas = 0; Detalhe = $parou })
        break
      }
      if($w -gt 1){
        $w = [Math]::Max(1, [int][Math]::Floor($w / 10))
        Write-Host ("  janela falhou a partir de {0}: tentando com {1} linha(s)" -f $(if($cur.Count){ $cur -join ', ' }else{'(comeco)'}), $w) -ForegroundColor Yellow
        continue
      }
      # nem 1 linha sai: pular a regiao ruim
      $s = Find-NextStart $cur
      if(-not $s){
        $parou = "parou em {0}: a proxima linha e ilegivel e nao consegui pular ({1}). Erro: {2}" -f $(if($cur.Count){ $cur -join ', ' }else{'(comeco)'}), $(if($lastNumeric){"nada legivel ate +$MaxGap"}else{'ultima coluna da PK nao e numerica'}), $r.Error
        $rel.Add([pscustomobject]@{ Tipo = 'parou'; De = ($cur -join ', '); Ate = ''; Linhas = 0; Detalhe = $parou })
        break
      }
      $rel.Add([pscustomobject]@{ Tipo = 'perdido'; De = $s.De; Ate = $s.Ate; Linhas = ''; Detalhe = $s.Motivo })
      Write-Host ("  PULO: chaves de {0} ate {1} ({2})" -f $s.De, $s.Ate, $s.Motivo) -ForegroundColor Red
      if($s.Fim){ break }
      if((@($s.Next) -join '|') -eq (@($cur) -join '|')){ $parou = "sem progresso em $($cur -join ', ')"; break }
      $cur = @($s.Next); $w = 1
    }
    $sw.Stop()
    $rel | Export-Csv -Path $ReportFile -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    $perdidas = @($rel | Where-Object Tipo -eq 'perdido')
    Write-Host ""
    Write-Host ("  copiados: {0:N0} linha(s) em {1} janela(s), {2:N0}s  |  faixas perdidas: {3}" -f $total, $janelas, $sw.Elapsed.TotalSeconds, $perdidas.Count) -ForegroundColor $(if($perdidas.Count){'Yellow'}else{'Green'})
    foreach($p in $perdidas){ Write-Host ("    - de {0} ate {1}: {2}" -f $p.De, $p.Ate, $p.Detalhe) -ForegroundColor Yellow }
    Write-Host ("  relatorio: {0}" -f $ReportFile) -ForegroundColor DarkGray
    if($parou){ Write-Host (">> " + $parou) -ForegroundColor Red; Write-Host ">> Continue manualmente com -StartKey depois da regiao ruim, ou leia por RDB`$DB_KEY (procedure 06 secao 3.c)." -ForegroundColor Yellow; exit 2 }
    Write-Host ">> Tabela concluida. Confira as contagens (procedure 06 secao 7)." -ForegroundColor Green
    exit 0
  }
}
