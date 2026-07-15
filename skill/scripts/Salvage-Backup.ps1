<#
.SYNOPSIS
  Backup de salvamento (gbak -b -ignore -g) com log detalhado e analise de erros.

.DESCRIPTION
  Roda 'gbak -b -v -ignore -g' (ignora checksums e desliga garbage collection,
  combinacao recomendada para bancos suspeitos de corrupcao). Captura saida
  completa para um log e ao final analisa o log procurando linhas de erro,
  contando tabelas processadas e validando a linha "closing file, committing,
  and finishing".

  Exit codes:
    0  Backup limpo (gbak ok e nenhuma linha de erro no log).
    2  gbak falhou ou log tem mensagens de erro.

.PARAMETER Database
  Caminho do banco origem.

.PARAMETER BackupFile
  Caminho do .fbk a gerar.

.PARAMETER ExtraArgs
  Argumentos adicionais para gbak (ex.: '-skip_data', 'TABELA_RUIM').

.EXAMPLE
  .\Salvage-Backup.ps1 -Database C:\path\BANCO.FDB -BackupFile C:\path\BANCO.salvage.fbk
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Database,
  [Parameter(Mandatory=$true)][string]$BackupFile,
  [string]$GbakPath = 'C:\Program Files\Firebird\Firebird_2_5\bin\gbak.exe',
  [string]$User     = 'SYSDBA',
  [string]$Password = 'masterkey',
  [string[]]$ExtraArgs = @()
)

$ErrorActionPreference = 'Stop'

if(-not (Test-Path -LiteralPath $Database)){ Write-Error "Banco nao encontrado: $Database"; exit 1 }
if(-not (Test-Path -LiteralPath $GbakPath)){ Write-Error "gbak.exe nao encontrado em: $GbakPath"; exit 1 }
if(Test-Path -LiteralPath $BackupFile){
  Write-Warning "Arquivo destino ja existe: $BackupFile"
  $r = Read-Host "Sobrescrever? (digite SIM)"
  if($r -ne 'SIM'){ Write-Host "Cancelado."; exit 0 }
  Remove-Item -LiteralPath $BackupFile -Force
}

$log = "$BackupFile.log"
$args = @('-b','-v','-ignore','-g','-user',$User,'-password',$Password) + $ExtraArgs + @($Database, $BackupFile)

Write-Host ("==== Salvage-Backup  |  {0}" -f $Database) -ForegroundColor Cyan
Write-Host ("  destino: {0}" -f $BackupFile)
Write-Host ("  log    : {0}" -f $log)
Write-Host ("  args   : gbak {0}" -f ($args -join ' ')) -ForegroundColor DarkGray
Write-Host "  Executando (pode levar varios minutos)..." -ForegroundColor DarkGray

$sw = [Diagnostics.Stopwatch]::StartNew()
& $GbakPath @args *> $log
$exit = $LASTEXITCODE
$sw.Stop()

# Analise do log
$logExists = Test-Path -LiteralPath $log
if($logExists){
  $errLines = Select-String -LiteralPath $log -Pattern 'gbak:\s*ERROR|cannot|fail|Exiting before completion' -SimpleMatch:$false -CaseSensitive:$false
  $warnLines = Select-String -LiteralPath $log -Pattern 'gbak:\s*warning' -CaseSensitive:$false
  $tablesProcessed = (Select-String -LiteralPath $log -Pattern 'writing data for table').Count
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
} else {
  Write-Host ">> Backup TEM problemas. Analise o log: $log" -ForegroundColor Red
  if($errLines.Count -gt 0){
    $firstErr = $errLines[0].Line
    if($firstErr -match 'table\s+(\w+)'){ Write-Host (">>   Tabela afetada (parece): {0}" -f $Matches[1]) -ForegroundColor Yellow }
    Write-Host  ">>   Considere: -ExtraArgs '-skip_data','NOME_TABELA' OU procedure 06 (tabela-a-tabela)." -ForegroundColor Yellow
  }
  exit 2
}
