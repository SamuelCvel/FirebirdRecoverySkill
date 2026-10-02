<#
.SYNOPSIS
  Wrapper para gerenciar o servico Firebird OU isolar um unico banco
  (gfix -shut/-online) sem afetar producao.

.DESCRIPTION
  Acoes (-Action):
    status     : mostra servicos Firebird (descobertos pelo executavel) e processos.
    start      : sobe os servicos (Server antes do Guardian). Confere se subiram.
    stop       : para os servicos (Guardian antes, senao ele reinicia o Server).
                 Precisa de console como Administrador. Confere se pararam.
    shutdown   : tira UM banco de linha via 'gfix -shut <modo> -force 0'.
                 Precisa de -Database. Nao afeta outros bancos.
    online     : devolve UM banco para producao via 'gfix -online'.
                 Precisa de -Database.

  -Mode (so para shutdown), verificado no Firebird 2.5.9:
    full   (padrao) ninguem conecta, nem SYSDBA - use para mexer no ARQUIVO.
    single uma conexao SYSDBA/dono - use para manutencao com isql/gfix.
    multi  SYSDBA e dono continuam conectando (e o que 'gfix -shut' sem modo faz);
           aplicacao que conecta como SYSDBA continua entrando.

  Exit codes: 0 ok; 1 parametro invalido; 2 gfix falhou; 3 sem permissao/servico nao mudou de estado.

.EXAMPLE
  .\Firebird-Service.ps1 -Action status
  .\Firebird-Service.ps1 -Action shutdown -Database C:\path\BANCO.FDB
  .\Firebird-Service.ps1 -Action shutdown -Database C:\path\BANCO.FDB -Mode single
  .\Firebird-Service.ps1 -Action online   -Database C:\path\BANCO.FDB
  .\Firebird-Service.ps1 -Action stop     # precisa Administrador
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateSet('status','start','stop','shutdown','online')][string]$Action,
  [string]$Database,
  [ValidateSet('full','single','multi')][string]$Mode = 'full',
  [string]$GfixPath = 'C:\Program Files\Firebird\Firebird_2_5\bin\gfix.exe',
  [string]$User     = $(if($env:ISC_USER){ $env:ISC_USER } else { 'SYSDBA' }),
  [string]$Password = $(if($env:ISC_PASSWORD){ $env:ISC_PASSWORD } else { 'masterkey' })
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_FirebirdCommon.ps1')
$GfixPath = Resolve-FbToolPath 'gfix' $GfixPath

function Get-FbServiceNames {
  $svc = @(Get-FbServices)
  $guard  = @($svc | Where-Object { $_.PathName -match '(?i)\\fbguard\.exe' } | ForEach-Object Name)
  $server = @($svc | Where-Object { $_.PathName -notmatch '(?i)\\fbguard\.exe' } | ForEach-Object Name)
  if($guard.Count -eq 0 -and $server.Count -eq 0){
    # instalacao padrao do 2.5
    $guard = @('FirebirdGuardianDefaultInstance'); $server = @('FirebirdServerDefaultInstance')
  }
  [pscustomobject]@{ Guardian = $guard; Server = $server }
}
function Show-Status {
  Write-Host "Servicos:" -ForegroundColor Cyan
  $s = @(Get-FbServices)
  if($s.Count -gt 0){ $s | Format-Table Name, State, StartMode -AutoSize | Out-Host }
  else { Write-Host "  (nenhum servico Firebird encontrado - pode estar rodando como aplicacao)" -ForegroundColor DarkGray }
  Write-Host "Processos:" -ForegroundColor Cyan
  $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in 'fbserver','fbguard','fb_inet_server','fb_smp_server','firebird' }
  if($procs){ $procs | Format-Table Name, Id, CPU -AutoSize | Out-Host }
  else { Write-Host "  (nenhum processo Firebird ativo)" -ForegroundColor DarkGray }
}
function Test-AllInState([string[]]$Names, [string]$Status){
  foreach($n in $Names){
    $s = Get-Service -Name $n -ErrorAction SilentlyContinue
    if($s -and $s.Status -ne $Status){ return $false }
  }
  return $true
}

switch($Action){
  'status' { Show-Status }

  'start' {
    $n = Get-FbServiceNames
    Write-Host "Iniciando Firebird (Server, depois Guardian)..." -ForegroundColor Cyan
    foreach($s in @($n.Server + $n.Guardian)){
      try { Start-Service -Name $s -ErrorAction Stop } catch { Write-Warning ("Nao subiu {0}: {1}" -f $s, $_.Exception.Message) }
    }
    Start-Sleep -Seconds 2
    Show-Status
    if(-not (Test-AllInState -Names $n.Server -Status 'Running')){ Exit-FbError "O servico do servidor nao esta Running." 3 }
  }

  'stop' {
    if(-not (Test-FbAdmin)){ Exit-FbError "Precisa de console como Administrador para parar o servico." 3 }
    $n = Get-FbServiceNames
    Write-Warning "Parar o servico afeta TODOS os bancos. Para isolar 1, use -Action shutdown."
    Write-Host "Parando Guardian (impede auto-restart) e depois Server..." -ForegroundColor Cyan
    foreach($s in @($n.Guardian + $n.Server)){
      try { Stop-Service -Name $s -Force -ErrorAction Stop } catch { Write-Warning ("Nao parou {0}: {1}" -f $s, $_.Exception.Message) }
    }
    Start-Sleep -Seconds 2
    Show-Status
    if(-not (Test-AllInState -Names @($n.Guardian + $n.Server) -Status 'Stopped')){ Exit-FbError "Algum servico Firebird nao parou." 3 }
  }

  'shutdown' {
    if(-not $Database){ Exit-FbError "-Database e obrigatorio para 'shutdown'." 1 }
    if(-not (Test-Path -LiteralPath $Database)){ Exit-FbError "Banco nao encontrado: $Database" 1 }
    Write-Host ("Tirando o banco {0} de linha (gfix -shut {1} -force 0)..." -f $Database, $Mode) -ForegroundColor Cyan
    $r = Invoke-FbNative -Exe $GfixPath -Arguments @('-shut', $Mode, '-force', '0', $Database) -User $User -Password $Password
    $r.Lines | Out-Host
    if($r.Exit -ne 0){ Exit-FbError "gfix -shut falhou (Exit=$($r.Exit))." 2 }
    Write-Host ("OK ({0}). Outros bancos do servidor seguem atendendo." -f $Mode) -ForegroundColor Green
  }

  'online' {
    if(-not $Database){ Exit-FbError "-Database e obrigatorio para 'online'." 1 }
    if(-not (Test-Path -LiteralPath $Database)){ Exit-FbError "Banco nao encontrado: $Database" 1 }
    Write-Host ("Devolvendo o banco {0} para producao (gfix -online)..." -f $Database) -ForegroundColor Cyan
    $r = Invoke-FbNative -Exe $GfixPath -Arguments @('-online', $Database) -User $User -Password $Password
    $r.Lines | Out-Host
    if($r.Exit -ne 0){ Write-Warning "gfix -online retornou Exit=$($r.Exit)."; exit 2 }
    Write-Host "OK." -ForegroundColor Green
  }
}
exit 0
