<#
.SYNOPSIS
  Restore de .fbk para banco novo (gbak -c) com log e verificacao automatica.

.DESCRIPTION
  Roda 'gbak -c -v' para restaurar um .fbk em um arquivo .fdb novo. Captura
  log completo, e ao final corre gstat -h e contagens basicas via isql (tabelas,
  views, procedures, generators) no destino para confirmar consistencia.

  Opcoes para situacoes mais dificeis:
    -InactiveIndexes  passa '-i' (indices ficam inactive; ative manualmente depois).
    -OneAtATime       passa '-o' (commit por tabela; se quebra em uma, salva o resto).
    -MetadataOnly     passa '-mo' (so estrutura, sem dados).

  Exit codes:
    0  Restore + verificacao ok.
    2  gbak falhou ou verificacao acusou problema.

.PARAMETER BackupFile
  Caminho do .fbk de origem.

.PARAMETER TargetDatabase
  Caminho do .fdb destino (precisa nao existir, ou use -Replace).
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$BackupFile,
  [Parameter(Mandatory=$true)][string]$TargetDatabase,
  [string]$GbakPath  = 'C:\Program Files\Firebird\Firebird_2_5\bin\gbak.exe',
  [string]$GstatPath = 'C:\Program Files\Firebird\Firebird_2_5\bin\gstat.exe',
  [string]$IsqlPath  = 'C:\Program Files\Firebird\Firebird_2_5\bin\isql.exe',
  [string]$User      = 'SYSDBA',
  [string]$Password  = 'masterkey',
  [switch]$InactiveIndexes,
  [switch]$OneAtATime,
  [switch]$MetadataOnly,
  [switch]$Replace,
  [string[]]$ExtraArgs = @()
)

$ErrorActionPreference = 'Stop'

if(-not (Test-Path -LiteralPath $BackupFile)){ Write-Error ".fbk nao encontrado: $BackupFile"; exit 1 }
if(Test-Path -LiteralPath $TargetDatabase){
  if($Replace){ Remove-Item -LiteralPath $TargetDatabase -Force }
  else {
    Write-Warning "Destino ja existe: $TargetDatabase. Use -Replace para sobrescrever."
    exit 1
  }
}

$log = "$TargetDatabase.restore.log"
$flags = @('-c','-v')
if($InactiveIndexes){ $flags += '-i' }
if($OneAtATime)     { $flags += '-o' }
if($MetadataOnly)   { $flags += '-mo' }
$args = $flags + @('-user',$User,'-password',$Password) + $ExtraArgs + @($BackupFile, $TargetDatabase)

Write-Host ("==== Restore-Clean  |  {0}" -f $TargetDatabase) -ForegroundColor Cyan
Write-Host ("  origem : {0}" -f $BackupFile)
Write-Host ("  args   : gbak {0}" -f ($args -join ' ')) -ForegroundColor DarkGray
Write-Host  "  Executando..." -ForegroundColor DarkGray

$sw = [Diagnostics.Stopwatch]::StartNew()
& $GbakPath @args *> $log
$exit = $LASTEXITCODE
$sw.Stop()

$errLines = if(Test-Path -LiteralPath $log){ Select-String -LiteralPath $log -Pattern 'gbak:\s*ERROR|violation of|cannot' -CaseSensitive:$false } else { @() }
$dbExists = Test-Path -LiteralPath $TargetDatabase

Write-Host ""
Write-Host ("  gbak exit       : {0}" -f $exit)
Write-Host ("  duracao         : {0:N1}s" -f $sw.Elapsed.TotalSeconds)
Write-Host ("  destino criado  : {0}" -f $dbExists)
if($dbExists){ Write-Host ("  tamanho destino : {0:N0} bytes" -f (Get-Item -LiteralPath $TargetDatabase).Length) }
Write-Host ("  linhas de erro  : {0}" -f $errLines.Count)
if($errLines.Count -gt 0){
  Write-Host "  --- primeiras 10 linhas de erro ---" -ForegroundColor Red
  $errLines | Select-Object -First 10 | ForEach-Object { Write-Host ("    " + $_.Line) -ForegroundColor Red }
}

if($exit -ne 0 -or -not $dbExists){
  Write-Host ">> Restore FALHOU. Log: $log" -ForegroundColor Red
  if($errLines.Count -gt 0){
    Write-Host ">>   Quebra em constraint/indice? Use -InactiveIndexes -OneAtATime (procedure 05)." -ForegroundColor Yellow
  }
  exit 2
}

# Verificacao pos-restore (4 lentes resumidas)
Write-Host ""
Write-Host "  --- Verificacao pos-restore ---" -ForegroundColor DarkGray

# 1) gstat -h
$gout = & $GstatPath -h $TargetDatabase 2>&1
$gtext = ($gout -join "`n")
$gstatOk = ($LASTEXITCODE -eq 0) -and ($gtext -match 'Page size')

# 2) Contagens via isql
$sql = @"
SET LIST ON;
SELECT COUNT(*) AS TABELAS  FROM RDB`$RELATIONS WHERE RDB`$SYSTEM_FLAG=0 AND RDB`$VIEW_BLR IS NULL;
SELECT COUNT(*) AS VIEWS    FROM RDB`$RELATIONS WHERE RDB`$SYSTEM_FLAG=0 AND RDB`$VIEW_BLR IS NOT NULL;
SELECT COUNT(*) AS PROCS    FROM RDB`$PROCEDURES;
SELECT COUNT(*) AS GERADORES FROM RDB`$GENERATORS WHERE RDB`$SYSTEM_FLAG=0;
SELECT COUNT(*) AS INDICES_INACTIVE FROM RDB`$INDICES WHERE RDB`$INDEX_INACTIVE=1 AND RDB`$SYSTEM_FLAG=0;
"@
$iout = $sql | & $IsqlPath -q -user $User -password $Password $TargetDatabase 2>&1

Write-Host ("  gstat lendo header: {0}" -f $(if($gstatOk){'SIM'}else{'NAO'}))
Write-Host "  Contagens:"
$iout | ForEach-Object { Write-Host ("    " + $_) }

if($gstatOk -and $errLines.Count -eq 0){
  Write-Host ">> Restore OK. Siga para procedure 08 (verificacao completa + reintegracao)." -ForegroundColor Green
  exit 0
} else {
  Write-Host ">> Restore concluido mas com problemas; revise antes de produzir." -ForegroundColor Red
  exit 2
}
