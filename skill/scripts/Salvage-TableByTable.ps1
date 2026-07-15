<#
.SYNOPSIS
  Salvamento tabela-a-tabela quando gbak para numa tabela especifica.

.DESCRIPTION
  Dois modos principais:

  1) Modo SKIP (-Action skip-bad-table): chama 'gbak -b -ignore -g -skip_data <T>'
     para fazer backup ignorando a(s) tabela(s) ruim(s). E o caminho mais barato
     quando voce ja sabe quais sao as tabelas problemas.

  2) Modo LIST (-Action list): lista tabelas com contagens, util para inventario
     antes de decidir.

  Modo PUMP (-Action pump) e mais complexo (extrair dados linha-a-linha via
  isql/UNLOAD) e por enquanto e um stub que apenas gera o script SQL que voce
  pode executar manualmente. Veja procedure 06 para o caminho manual.

  Exit codes: 0 ok, 1 erro de parametros, 2 gbak/isql falhou.

.EXAMPLE
  .\Salvage-TableByTable.ps1 -Action list -Database C:\path\BANCO.FDB

  .\Salvage-TableByTable.ps1 -Action skip-bad-table `
    -Database C:\path\BANCO.FDB `
    -SkipTables TABELA_RUIM, OUTRA_RUIM `
    -BackupFile C:\path\BANCO.parcial.fbk

  .\Salvage-TableByTable.ps1 -Action pump `
    -Database C:\path\BANCO.FDB -Table TABELA_RUIM -Window 1000
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateSet('list','skip-bad-table','pump')][string]$Action,
  [Parameter(Mandatory=$true)][string]$Database,
  [string[]]$SkipTables = @(),
  [string]$Table,
  [int]$Window = 1000,
  [string]$BackupFile,
  [string]$TargetDatabase,
  [string]$GbakPath = 'C:\Program Files\Firebird\Firebird_2_5\bin\gbak.exe',
  [string]$IsqlPath = 'C:\Program Files\Firebird\Firebird_2_5\bin\isql.exe',
  [string]$User     = 'SYSDBA',
  [string]$Password = 'masterkey'
)
$ErrorActionPreference = 'Stop'
if(-not (Test-Path -LiteralPath $Database)){ Write-Error "Banco nao encontrado: $Database"; exit 1 }

function Get-UserTables([string]$db){
  $sql = @"
SET LIST OFF;
SET HEADING OFF;
SELECT TRIM(RDB`$RELATION_NAME)
FROM RDB`$RELATIONS
WHERE RDB`$SYSTEM_FLAG=0 AND RDB`$VIEW_BLR IS NULL
ORDER BY RDB`$RELATION_NAME;
"@
  $out = $sql | & $IsqlPath -q -user $User -password $Password $db 2>&1
  return $out | Where-Object { $_ -match '^\s*\S' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^SQL>' }
}
function Get-RowCount([string]$db,[string]$tbl){
  $sql = "SELECT COUNT(*) FROM `"$tbl`";"
  $out = $sql | & $IsqlPath -q -user $User -password $Password $db 2>&1
  $n = ($out | Select-String -Pattern '^\s*\d+\s*$' | Select-Object -First 1)
  if($n){ return [int64]($n.Line.Trim()) } else { return -1 }
}

switch($Action){

  'list' {
    Write-Host ("==== Inventario  |  {0}" -f $Database) -ForegroundColor Cyan
    $tables = Get-UserTables $Database
    Write-Host ("  Tabelas de usuario: {0}" -f $tables.Count)
    $rows = foreach($t in $tables){
      $c = Get-RowCount $Database $t
      [pscustomobject]@{ Tabela = $t; Registros = $c }
    }
    $rows | Format-Table -AutoSize | Out-Host
    $rows | Export-Csv -Path "$Database.inventario.csv" -NoTypeInformation -Encoding UTF8
    Write-Host ("  Inventario salvo: {0}.inventario.csv" -f $Database) -ForegroundColor DarkGray
    exit 0
  }

  'skip-bad-table' {
    if(-not $BackupFile){ Write-Error "-BackupFile e obrigatorio."; exit 1 }
    if($SkipTables.Count -eq 0){ Write-Error "-SkipTables e obrigatorio (pelo menos uma tabela)."; exit 1 }
    # IMPORTANTE: gbak -skip_data so existe a partir do Firebird 3.0. No 2.5 nao existe.
    $verOut = (& $GbakPath -z 2>&1) -join ' '
    if($verOut -match 'V(\d+)\.(\d+)\.'){
      $major=[int]$Matches[1]; $minor=[int]$Matches[2]
      if($major -lt 3){
        Write-Error ("-Action skip-bad-table usa '-skip_data', introduzido no Firebird 3.0. Sua versao do gbak e {0}.{1}." -f $major,$minor)
        Write-Host  "  Para Firebird 2.5: siga a procedure 06 (drop+recreate manual da tabela com FKs)." -ForegroundColor Yellow
        exit 1
      }
    }
    if(Test-Path -LiteralPath $BackupFile){ Remove-Item -LiteralPath $BackupFile -Force }
    $args = @('-b','-v','-ignore','-g','-user',$User,'-password',$Password)
    foreach($t in $SkipTables){ $args += @('-skip_data',$t) }
    $args += @($Database, $BackupFile)
    $log = "$BackupFile.log"
    Write-Host ("==== Salvage com -skip_data: {0}" -f ($SkipTables -join ',')) -ForegroundColor Cyan
    & $GbakPath @args *> $log
    $exit = $LASTEXITCODE
    $finishOk = $null -ne (Select-String -LiteralPath $log -Pattern 'closing file, committing, and finishing')
    Write-Host ("  gbak exit: {0}  finishing: {1}" -f $exit, $finishOk)
    if($exit -eq 0 -and $finishOk){
      Write-Host ">> Backup parcial OK. Restaure com Restore-Clean.ps1. Tabelas puladas precisam ser repopuladas (modo pump ou restauracao manual)." -ForegroundColor Green
      exit 0
    } else {
      Write-Host ">> Backup falhou. Log: $log" -ForegroundColor Red
      exit 2
    }
  }

  'pump' {
    if(-not $Table){ Write-Error "-Table e obrigatorio para pump."; exit 1 }
    Write-Host ("==== Pump da tabela {0} (gera script SQL)" -f $Table) -ForegroundColor Cyan
    $total = Get-RowCount $Database $Table
    if($total -lt 0){ Write-Warning "Nao consegui contar a tabela (pode estar corrompida). Vou tentar mesmo assim em janelas." }
    else { Write-Host ("  Total estimado: {0} registros" -f $total) }

    $sqlOut = "$Database.pump.$Table.sql"
    $skips = if($total -gt 0){ 0..([math]::Ceiling($total/$Window)-1) | ForEach-Object { $_ * $Window } } else { 0,$Window,(2*$Window),(3*$Window) }
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine("/* Script de extracao tabela-a-tabela em janelas de $Window. */")
    [void]$sb.AppendLine("/* Rode cada bloco; se um falhar, pule e siga. */")
    foreach($s in $skips){
      [void]$sb.AppendLine("")
      [void]$sb.AppendLine("/* Janela SKIP $s LIMIT $Window */")
      [void]$sb.AppendLine("SELECT FIRST $Window SKIP $s * FROM `"$Table`";")
    }
    Set-Content -LiteralPath $sqlOut -Value $sb.ToString() -Encoding UTF8
    Write-Host ("  Script gerado: {0}" -f $sqlOut) -ForegroundColor Yellow
    Write-Host  "  Pump linha-a-linha automatizado (com INSERTs) e manual: veja procedure 06 secao 3." -ForegroundColor Yellow
    Write-Host  "  Este script serve para voce identificar quais janelas funcionam." -ForegroundColor Yellow
    exit 0
  }
}
