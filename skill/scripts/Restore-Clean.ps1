<#
.SYNOPSIS
  Restore de .fbk para banco novo (gbak -c) com log e verificacao automatica.

.DESCRIPTION
  Roda 'gbak -c -v' para restaurar um .fbk em um arquivo .fdb novo. O gbak grava a
  saida completa no log ('-y <log>'); ao final o script roda gstat -h e contagens
  basicas via isql (tabelas, views, procedures, generators, indices nao ativos) no
  destino para confirmar consistencia.

  Opcoes para situacoes mais dificeis:
    -InactiveIndexes  passa '-inactive' (todos os indices inativos, inclusive PK/FK; ative depois).
    -OneAtATime       passa '-one_at_a_time' (commit por tabela; se quebra em uma, salva o resto).
    -MetadataOnly     passa '-meta_data' (so estrutura, sem dados). Atencao: '-mo' e outro
                      switch (-mode read_only|read_write) e faz o gbak falhar.

  Exit codes:
    0  Restore + verificacao ok.
    1  Parametro/arquivo invalido.
    2  gbak falhou ou verificacao acusou problema.
    4  Destino ja existe e -Replace nao foi passado (nada foi feito).

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
. (Join-Path $PSScriptRoot '_FirebirdCommon.ps1')

if(-not (Test-Path -LiteralPath $BackupFile)){ Exit-FbError ".fbk nao encontrado: $BackupFile" 1 }
$log = "$TargetDatabase.restore.log"
foreach($f in @($TargetDatabase, $log)){
  if(Test-Path -LiteralPath $f){
    if(-not $Replace){
      Write-Warning "Ja existe: $f  (use -Replace para sobrescrever). Nada foi feito."
      exit 4
    }
    Remove-Item -LiteralPath $f -Force
  }
}

$flags = @('-c','-v')
if($InactiveIndexes){ $flags += '-inactive' }
if($OneAtATime)     { $flags += '-one_at_a_time' }
if($MetadataOnly)   { $flags += '-meta_data' }
$gbakArgs = $flags + @('-user',$User,'-password',$Password) + $ExtraArgs + @('-y', $log, $BackupFile, $TargetDatabase)
$shown    = ($gbakArgs -join ' ') -replace [regex]::Escape("-password $Password"), '-password ***'

Write-Host ("==== Restore-Clean  |  {0}" -f $TargetDatabase) -ForegroundColor Cyan
Write-Host ("  origem : {0}" -f $BackupFile)
Write-Host ("  log    : {0}" -f $log)
Write-Host ("  args   : gbak {0}" -f $shown) -ForegroundColor DarkGray
Write-Host  "  Executando..." -ForegroundColor DarkGray

$sw = [Diagnostics.Stopwatch]::StartNew()
$run = Invoke-FbNative -Exe $GbakPath -Arguments $gbakArgs
$exit = $run.Exit
$sw.Stop()
if($run.Lines.Count -gt 0){ $run.Lines | ForEach-Object { Write-Host ("  " + $_) -ForegroundColor DarkYellow } }

$errLines = if(Test-Path -LiteralPath $log){ @(Select-String -LiteralPath $log -Pattern 'gbak:\s*ERROR|violation of|cannot commit|Exiting before completion' -CaseSensitive:$false) } else { @() }
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

# Estado do banco destino (um restore que falha costuma deixa-lo em manutencao)
$gstat = if($dbExists){ Invoke-FbNative -Exe $GstatPath -Arguments @('-h', $TargetDatabase) } else { $null }
$attrLine = if($gstat){ ($gstat.Lines | Where-Object { $_ -match 'Attributes' } | Select-Object -First 1) } else { $null }
$emManutencao = $attrLine -match 'maintenance|shutdown'

if($exit -ne 0 -or -not $dbExists){
  Write-Host ">> Restore FALHOU. Log: $log" -ForegroundColor Red
  if($errLines.Count -gt 0){
    Write-Host ">>   Quebra em constraint/indice? Use -InactiveIndexes -OneAtATime (procedure 05)." -ForegroundColor Yellow
  }
  if($emManutencao){
    Write-Host (">>   O destino ficou em modo de manutencao ({0})." -f ($attrLine.Trim() -replace '\s+',' ')) -ForegroundColor Yellow
    Write-Host  ">>   So cabe 1 conexao: rode 'gfix -online' antes de investigar (procedure 08 secao 0; orfas: procedure 05 secao 4c)." -ForegroundColor Yellow
  }
  exit 2
}

# Verificacao pos-restore (resumida)
Write-Host ""
Write-Host "  --- Verificacao pos-restore ---" -ForegroundColor DarkGray
$gstatOk = $gstat -and ($gstat.Exit -eq 0) -and ($gstat.Text -match 'Page size')

$sql = @"
SET LIST ON;
SELECT COUNT(*) AS TABELAS  FROM RDB`$RELATIONS WHERE COALESCE(RDB`$SYSTEM_FLAG,0)=0 AND RDB`$VIEW_BLR IS NULL;
SELECT COUNT(*) AS VIEWS    FROM RDB`$RELATIONS WHERE COALESCE(RDB`$SYSTEM_FLAG,0)=0 AND RDB`$VIEW_BLR IS NOT NULL;
SELECT COUNT(*) AS PROCS    FROM RDB`$PROCEDURES WHERE COALESCE(RDB`$SYSTEM_FLAG,0)=0;
SELECT COUNT(*) AS GERADORES FROM RDB`$GENERATORS WHERE COALESCE(RDB`$SYSTEM_FLAG,0)=0;
SELECT COUNT(*) AS INDICES_NAO_ATIVOS FROM RDB`$INDICES WHERE COALESCE(RDB`$INDEX_INACTIVE,0)<>0 AND COALESCE(RDB`$SYSTEM_FLAG,0)=0;
"@
$counts = Invoke-FbIsql -IsqlPath $IsqlPath -Database $TargetDatabase -Sql $sql -User $User -Password $Password

Write-Host ("  gstat lendo header: {0}" -f $(if($gstatOk){'SIM'}else{'NAO'}))
if($attrLine){ Write-Host ("  {0}" -f ($attrLine.Trim() -replace '\s+',' ')) }
Write-Host "  Contagens:"
$counts.Lines | Where-Object { $_ -match '\S' } | ForEach-Object { Write-Host ("    " + $_.Trim()) }
$naoAtivos = 0
$m = $counts.Lines | Select-String -Pattern 'INDICES_NAO_ATIVOS\s+(\d+)' | Select-Object -First 1
if($m){ $naoAtivos = [int]$m.Matches[0].Groups[1].Value }

if($gstatOk -and $errLines.Count -eq 0){
  if($naoAtivos -gt 0){
    Write-Host (">> Restore OK, com {0} indice(s) nao ativo(s): ative-os (procedure 05 secao 3) antes da procedure 08." -f $naoAtivos) -ForegroundColor Yellow
  } else {
    Write-Host ">> Restore OK. Siga para procedure 08 (verificacao completa + reintegracao)." -ForegroundColor Green
  }
  exit 0
} else {
  Write-Host ">> Restore concluido mas com problemas; revise antes de produzir." -ForegroundColor Red
  exit 2
}
