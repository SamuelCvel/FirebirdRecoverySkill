<#
.SYNOPSIS
  Wrapper para gerenciar o servico Firebird OU isolar um unico banco
  (gfix -shut/-online) sem afetar producao.

.DESCRIPTION
  Acoes (-Action):
    status     : mostra estado do servico (Guardian + Server) e processos.
    start      : sobe o servico (Server + Guardian). Idempotente.
    stop       : para o servico (Guardian primeiro, senao reinicia o Server).
                 Precisa de console como Administrador.
    shutdown   : tira UM banco especifico de linha via 'gfix -shut'.
                 Precisa de -Database. Nao afeta outros bancos.
    online     : devolve UM banco para producao via 'gfix -online'.
                 Precisa de -Database.

  Preferencia em recuperacao: 'shutdown'/'online' sao menos disruptivos que
  'stop'/'start' porque so afetam o banco-alvo.

.EXAMPLE
  .\Firebird-Service.ps1 -Action status
  .\Firebird-Service.ps1 -Action shutdown -Database C:\path\BANCO.FDB
  .\Firebird-Service.ps1 -Action online   -Database C:\path\BANCO.FDB
  .\Firebird-Service.ps1 -Action stop     # precisa Administrador
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateSet('status','start','stop','shutdown','online')][string]$Action,
  [string]$Database,
  [string]$GfixPath = 'C:\Program Files\Firebird\Firebird_2_5\bin\gfix.exe',
  [string]$User     = 'SYSDBA',
  [string]$Password = 'masterkey'
)

$ErrorActionPreference = 'Stop'
$GuardSvc  = 'FirebirdGuardianDefaultInstance'
$ServerSvc = 'FirebirdServerDefaultInstance'

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}
function Show-Status {
  Write-Host "Servicos:" -ForegroundColor Cyan
  Get-Service | Where-Object Name -like 'Firebird*' | Format-Table Name,Status,StartType -AutoSize | Out-Host
  Write-Host "Processos:" -ForegroundColor Cyan
  $procs = Get-Process | Where-Object { $_.Name -in 'fbserver','fbguard','fb_inet_server' }
  if($procs){ $procs | Format-Table Name,Id,CPU -AutoSize | Out-Host }
  else { Write-Host "  (nenhum processo Firebird ativo)" -ForegroundColor DarkGray }
}

switch($Action){
  'status' { Show-Status }
  'start' {
    Write-Host "Iniciando Firebird (Server + Guardian)..." -ForegroundColor Cyan
    Start-Service $ServerSvc -ErrorAction SilentlyContinue
    Start-Service $GuardSvc  -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Show-Status
  }
  'stop' {
    if(-not (Test-Admin)){ Write-Error "Precisa de console como Administrador para parar o servico."; exit 3 }
    Write-Warning "Parar o servico afeta TODOS os bancos. Para isolar 1, use -Action shutdown."
    Write-Host "Parando Guardian (impede auto-restart) e depois Server..." -ForegroundColor Cyan
    Stop-Service $GuardSvc  -Force -ErrorAction SilentlyContinue
    Stop-Service $ServerSvc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Show-Status
  }
  'shutdown' {
    if(-not $Database){ Write-Error "-Database e obrigatorio para 'shutdown'."; exit 1 }
    if(-not (Test-Path -LiteralPath $Database)){ Write-Error "Banco nao encontrado: $Database"; exit 1 }
    Write-Host ("Tirando o banco {0} de linha (gfix -shut -force 0)..." -f $Database) -ForegroundColor Cyan
    & $GfixPath -shut -force 0 -user $User -password $Password $Database 2>&1 | Out-Host
    if($LASTEXITCODE -ne 0){ Write-Error "gfix -shut falhou (Exit=$LASTEXITCODE)."; exit 2 }
    Write-Host "OK. Outros bancos do servidor seguem atendendo." -ForegroundColor Green
  }
  'online' {
    if(-not $Database){ Write-Error "-Database e obrigatorio para 'online'."; exit 1 }
    if(-not (Test-Path -LiteralPath $Database)){ Write-Error "Banco nao encontrado: $Database"; exit 1 }
    Write-Host ("Devolvendo o banco {0} para producao (gfix -online)..." -f $Database) -ForegroundColor Cyan
    & $GfixPath -online -user $User -password $Password $Database 2>&1 | Out-Host
    if($LASTEXITCODE -ne 0){ Write-Warning "gfix -online retornou Exit=$LASTEXITCODE."; exit 2 }
    Write-Host "OK." -ForegroundColor Green
  }
}
exit 0
