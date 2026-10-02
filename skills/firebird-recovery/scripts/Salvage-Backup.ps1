<#
.SYNOPSIS
  Backup de salvamento (gbak -b -ignore -g) com log detalhado e analise de erros.

.DESCRIPTION
  Roda 'gbak -b -v -ignore -g' (ignora checksums e desliga garbage collection,
  combinacao recomendada para bancos suspeitos de corrupcao). O gbak grava a saida
  completa no log ('-y <log>') e ao final o script analisa o log: linhas de erro,
  tabelas processadas, linha "closing file, committing, and finishing" e - se falhou -
  qual tabela quebrou.

  Exit codes:
    0  Backup limpo (gbak ok e nenhuma linha de erro no log).
    1  Parametro/arquivo invalido.
    2  gbak falhou ou log tem mensagens de erro.
    4  Destino ja existe e -Force nao foi passado (nada foi feito).

.PARAMETER Database
  Caminho do banco origem.

.PARAMETER BackupFile
  Caminho do .fbk a gerar. O log vai para "<BackupFile>.log".

.PARAMETER Force
  Sobrescreve o .fbk (e o log) se ja existirem.

.PARAMETER ExtraArgs
  Argumentos adicionais para gbak (ex.: '-limbo' para ignorar transacoes em limbo).
  '-skip_data' so existe no Firebird 3.0+; no 2.5 veja a procedure 06.

.EXAMPLE
  .\Salvage-Backup.ps1 -Database C:\path\BANCO.FDB -BackupFile C:\path\BANCO.salvage.fbk
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Database,
  [Parameter(Mandatory=$true)][string]$BackupFile,
  [string]$GbakPath = 'C:\Program Files\Firebird\Firebird_2_5\bin\gbak.exe',
  [string]$IsqlPath = 'C:\Program Files\Firebird\Firebird_2_5\bin\isql.exe',
  [string]$User     = $(if($env:ISC_USER){ $env:ISC_USER } else { 'SYSDBA' }),
  [string]$Password = $(if($env:ISC_PASSWORD){ $env:ISC_PASSWORD } else { 'masterkey' }),
  [switch]$Force,
  [string[]]$ExtraArgs = @()
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_FirebirdCommon.ps1')
$GbakPath = Resolve-FbToolPath 'gbak' $GbakPath
$IsqlPath = Resolve-FbToolPath 'isql' $IsqlPath

if(-not (Test-Path -LiteralPath $Database)){ Exit-FbError "Banco nao encontrado: $Database" 1 }
if(-not (Test-Path -LiteralPath $GbakPath)){ Exit-FbError "gbak.exe nao encontrado em: $GbakPath" 1 }

$log = "$BackupFile.log"
foreach($f in @($BackupFile, $log)){
  if(Test-Path -LiteralPath $f){
    if(-not $Force){
      Write-Warning "Ja existe: $f  (use -Force para sobrescrever). Nada foi feito."
      exit 4
    }
    Remove-Item -LiteralPath $f -Force
  }
}

$gbakArgs = @('-b','-v','-ignore','-g') + $ExtraArgs + @('-y', $log, $Database, $BackupFile)
$shown    = $gbakArgs -join ' '

Write-Host ("==== Salvage-Backup  |  {0}" -f $Database) -ForegroundColor Cyan
Write-Host ("  destino: {0}" -f $BackupFile)
Write-Host ("  log    : {0}" -f $log)
Write-Host ("  args   : gbak {0}" -f $shown) -ForegroundColor DarkGray
Write-Host "  Executando (pode levar varios minutos)..." -ForegroundColor DarkGray

$sw = [Diagnostics.Stopwatch]::StartNew()
$run = Invoke-FbNative -Exe $GbakPath -Arguments $gbakArgs -User $User -Password $Password
$exit = $run.Exit
$sw.Stop()
if($run.Lines.Count -gt 0){ $run.Lines | ForEach-Object { Write-Host ("  " + $_) -ForegroundColor DarkYellow } }   # so aparece se o gbak nem abriu o log

# Analise do log
$logExists = Test-Path -LiteralPath $log
if($logExists){
  $errLines = @(Select-String -LiteralPath $log -Pattern 'gbak:\s*ERROR|Exiting before completion' -CaseSensitive:$false)
  $warnLines = @(Select-String -LiteralPath $log -Pattern 'gbak:\s*warning' -CaseSensitive:$false)
  $tablesProcessed = @(Select-String -LiteralPath $log -Pattern 'writing data for table').Count
  $finishOk = $null -ne (Select-String -LiteralPath $log -Pattern 'closing file, committing, and finishing')
} else {
  $errLines = @(); $warnLines = @(); $tablesProcessed = 0; $finishOk = $false
}

$fbkSize = if(Test-Path -LiteralPath $BackupFile){ (Get-Item -LiteralPath $BackupFile).Length } else { 0 }

Write-Host ""
Write-Host ("  gbak exit code     : {0}" -f $exit)
Write-Host ("  duracao            : {0:N1}s" -f $sw.Elapsed.TotalSeconds)
Write-Host ("  tabelas processadas: {0}" -f $tablesProcessed)
Write-Host ("  .fbk tamanho       : {0:N0} bytes" -f $fbkSize)
Write-Host ("  linha 'finishing'  : {0}" -f $finishOk)
Write-Host ("  linhas de erro     : {0}" -f $errLines.Count)
Write-Host ("  linhas de warning  : {0}" -f $warnLines.Count)

if($errLines.Count -gt 0){
  Write-Host "  --- primeiras 10 linhas de erro ---" -ForegroundColor Red
  $errLines | Select-Object -First 10 | ForEach-Object { Write-Host ("    " + $_.Line) -ForegroundColor Red }
}

if($exit -eq 0 -and $finishOk -and $errLines.Count -eq 0){
  Write-Host ">> Backup limpo. Pronto para Restore-Clean." -ForegroundColor Green
  exit 0
}

Write-Host ">> Backup TEM problemas. Analise o log: $log" -ForegroundColor Red
if($errLines.Count -gt 0 -and $logExists){
  # Na fase de dados o gbak escreve, por tabela: os indices dela, "writing data for table X"
  # e "N records written". O erro pode vir ANTES do "writing data", entao a tabela que quebrou
  # e a dona dos indices escritos depois do ultimo "records written".
  $firstErrLine = $errLines[0].LineNumber
  $lastRec = Select-String -LiteralPath $log -Pattern 'records written' |
             Where-Object { $_.LineNumber -lt $firstErrLine } | Select-Object -Last 1
  $fromLine = if($lastRec){ $lastRec.LineNumber } else { 0 }
  $idx = @(Select-String -LiteralPath $log -Pattern 'writing index (\S+)' |
           Where-Object { $_.LineNumber -gt $fromLine -and $_.LineNumber -lt $firstErrLine } |
           ForEach-Object { $_.Matches[0].Groups[1].Value })
  $tabela = $null
  if($idx.Count -gt 0 -and (Test-Path -LiteralPath $IsqlPath)){
    $inList = ($idx | ForEach-Object { "'" + $_.Replace("'","''") + "'" }) -join ','
    $q = "SET HEADING OFF;`nSELECT DISTINCT TRIM(RDB`$RELATION_NAME) FROM RDB`$INDICES WHERE RDB`$INDEX_NAME IN ($inList);`n"
    $r = Invoke-FbIsql -IsqlPath $IsqlPath -Database $Database -Sql $q -User $User -Password $Password
    $tabela = $r.Lines | Where-Object { $_ -match '^\s*[A-Za-z0-9_$]+\s*$' } | Select-Object -First 1
    if($tabela){ $tabela = $tabela.Trim() }
  }
  if(-not $tabela -and $lastRec){
    # Reserva: a fase de dados segue a ordem INVERSA da fase de metadados ("writing table X"),
    # pulando views. Sem consultar o banco nao da para separar view de tabela.
    $meta = @(Select-String -LiteralPath $log -Pattern 'writing table (\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
    [array]::Reverse($meta)
    $ultima = (Select-String -LiteralPath $log -Pattern 'writing data for table (\S+)' |
               Where-Object { $_.LineNumber -lt $firstErrLine } | Select-Object -Last 1).Matches[0].Groups[1].Value
    $pos = [array]::IndexOf($meta, $ultima)
    if($pos -ge 0 -and $pos + 1 -lt $meta.Count){ $tabela = "{0} (provavel; confira se nao e uma view)" -f $meta[$pos + 1] }
  }
  if($tabela){ Write-Host (">>   Tabela afetada: {0}" -f $tabela) -ForegroundColor Yellow }

  $ver = Invoke-FbNative -Exe $GbakPath -Arguments @('-z')
  if($ver.Text -match 'V(\d+)\.' -and [int]$Matches[1] -ge 3){
    Write-Host  ">>   Firebird 3.0+: considere -ExtraArgs '-skip_data','NOME_TABELA' OU procedure 06." -ForegroundColor Yellow
  } else {
    Write-Host  ">>   Firebird 2.5 nao tem -skip_data: siga a procedure 06 (salvar a tabela por chave e dropar numa copia, ou copiar tudo por EDS)." -ForegroundColor Yellow
  }
}
exit 2
