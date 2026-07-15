<#
.SYNOPSIS
  Conserta o campo page_size do cabecalho de um banco Firebird 2.5 corrompido.
  Reversivel via sidecar (.hdrbak) ou heuristica de varredura.

.DESCRIPTION
  Restaura o page_size correto no offset 0x10 (USHORT little-endian) da pagina 0.
  Fonte do valor correto (nesta ordem de preferencia):
    1) Sidecar '<Database>.hdrbak' contendo 'PAGESIZE=NNNN'.
    2) Varredura: procura a pagina 1 (PIP) nos offsets candidatos (1024..16384)
       identificando-a por checksum 12345 e pag_type valido.

  Recusa operar se o header LIDO ja parece valido (evita "consertar" o que esta bom).
  Cria seu proprio sidecar antes de gravar, para permitir reverter.

  Opcoes de isolamento para evitar conflito com o servidor:
    -Isolate     : usa gfix -shut/-online (so esse banco offline, servico segue).
    -StopService : para/reinicia o servico Firebird inteiro (precisa Admin).
    (nenhuma)    : tenta abrir em modo exclusivo; aborta se o servidor mantem.

.PARAMETER Database
  Caminho completo do banco a corrigir.

.PARAMETER Isolate
  Usa gfix -shut/-online para isolar o banco.

.PARAMETER StopService
  Para/reinicia o servico Firebird (precisa Administrador).

.PARAMETER Force
  Pula confirmacao interativa.

.EXAMPLE
  .\Repair-FirebirdHeader.ps1 -Database C:\path\BANCO.FDB -Isolate
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Database,
  [string]$GstatPath = 'C:\Program Files\Firebird\Firebird_2_5\bin\gstat.exe',
  [string]$GfixPath  = 'C:\Program Files\Firebird\Firebird_2_5\bin\gfix.exe',
  [string]$User      = 'SYSDBA',
  [string]$Password  = 'masterkey',
  [switch]$Isolate,
  [switch]$StopService,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$VALID     = 1024,2048,4096,8192,16384
$GuardSvc  = 'FirebirdGuardianDefaultInstance'
$ServerSvc = 'FirebirdServerDefaultInstance'
$bakFile   = "$Database.hdrbak"

function Read-Bytes([string]$path,[long]$off,[int]$len){
  $fs = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
  try { [void]$fs.Seek($off,'Begin'); $b = New-Object byte[] $len; [void]$fs.Read($b,0,$len); return $b }
  finally { $fs.Dispose() }
}
function Get-ClaimedPageSize([string]$path){ return [BitConverter]::ToUInt16((Read-Bytes $path 16 2),0) }
function Find-RealPageSize([string]$path){
  foreach($sz in $VALID){
    try { $b = Read-Bytes $path $sz 4 } catch { continue }
    if($b.Length -ge 4 -and $b[2] -eq 0x39 -and $b[3] -eq 0x30 -and $b[0] -ge 1 -and $b[0] -le 12){ return [int]$sz }
  }
  return 0
}
function Write-ByteExclusive([string]$path,[long]$off,[byte]$val){
  try { $fs = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
  catch { throw "Nao consegui abrir o arquivo em modo EXCLUSIVO. Use -Isolate ou -StopService. Detalhe: $($_.Exception.Message)" }
  try { [void]$fs.Seek($off,'Begin'); $fs.WriteByte($val) }
  finally { $fs.Dispose() }
}
function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

$script:SvcStopped = $false
function Service-StopIfRequested {
  if(-not $StopService){ return }
  if(-not (Test-Admin)){ throw "-StopService exige console como Administrador." }
  Write-Host "  Parando servico Firebird..." -ForegroundColor DarkGray
  Stop-Service $GuardSvc -Force -ErrorAction SilentlyContinue
  Stop-Service $ServerSvc -Force -ErrorAction SilentlyContinue
  $script:SvcStopped = $true
  Start-Sleep -Seconds 1
}
function Service-StartIfStopped {
  if($script:SvcStopped){
    Write-Host "  Reiniciando servico Firebird..." -ForegroundColor DarkGray
    Start-Service $ServerSvc -ErrorAction SilentlyContinue
    Start-Service $GuardSvc  -ErrorAction SilentlyContinue
  }
}
function Db-Shutdown([string]$path){
  Write-Host "  gfix -shut -force 0 ..." -ForegroundColor DarkGray
  & $GfixPath -shut -force 0 -user $User -password $Password $path 2>&1 | Out-Host
  if($LASTEXITCODE -ne 0){ throw "Falha no gfix -shut (Exit=$LASTEXITCODE)." }
}
function Db-Online([string]$path){
  Write-Host "  gfix -online ..." -ForegroundColor DarkGray
  & $GfixPath -online -user $User -password $Password $path 2>&1 | Out-Host
  if($LASTEXITCODE -ne 0){ Write-Warning "gfix -online retornou Exit=$LASTEXITCODE." }
}

if(-not (Test-Path -LiteralPath $Database)){ Write-Error "Banco nao encontrado: $Database"; exit 3 }
Write-Host ("==== Repair-FirebirdHeader  |  {0} ====" -f $Database) -ForegroundColor Cyan

$claim = Get-ClaimedPageSize $Database
$claimedValid = $VALID -contains [int]$claim
Write-Host ("  page_size lido atual: {0}  ({1})" -f $claim, $(if($claimedValid){'VALIDO'}else{'INVALIDO'}))

if($claimedValid){
  Write-Warning "O header lido parece VALIDO. Este script recusa operar sobre header bom para evitar piorar."
  Write-Host  "  Se voce esta CERTO que precisa forcar, use a chave -Force." -ForegroundColor Yellow
  if(-not $Force){ exit 1 }
}

# Determinar valor alvo
$target = 0
$source = ''
if(Test-Path -LiteralPath $bakFile){
  $line = Get-Content -LiteralPath $bakFile | Select-Object -First 1
  if($line -match 'PAGESIZE=(\d+)'){ $target = [int]$Matches[1]; $source = "sidecar $bakFile" }
}
if($target -le 0){
  $target = Find-RealPageSize $Database
  if($target -gt 0){ $source = 'varredura da pagina 1 (PIP)' }
}
if(-not ($VALID -contains $target)){
  Write-Error "Nao consegui determinar um page_size valido para corrigir (obtido: $target). Verifique a procedure 03 secao 5."
  exit 2
}
Write-Host ("  page_size alvo : {0}  (fonte: {1})" -f $target,$source) -ForegroundColor Yellow

# Confirmacao
if(-not $Force){
  $r = Read-Host "Aplicar correcao? (digite SIM)"
  if($r -ne 'SIM'){ Write-Host "Cancelado."; exit 0 }
}

# Salvar sidecar do estado atual (para reverter o reparo, se preciso)
$preBak = "$Database.pre-repair.hdrbak"
Set-Content -LiteralPath $preBak -Value "PAGESIZE=$claim" -Encoding ASCII
Write-Host "  Estado pre-reparo salvo em: $preBak" -ForegroundColor DarkGray

try{
  Service-StopIfRequested
  if($Isolate){ Db-Shutdown $Database }
  $lo = [byte]($target -band 0xFF); $hi = [byte](($target -shr 8) -band 0xFF)
  Write-ByteExclusive $Database 16 $lo
  Write-ByteExclusive $Database 17 $hi
  Write-Host ("  page_size regravado: {0} (bytes 0x{1:X2} 0x{2:X2})" -f $target,$lo,$hi) -ForegroundColor Green
  if($Isolate){ Db-Online $Database }
} finally { Service-StartIfStopped }

# Verificar com gstat -h
Write-Host "  --- gstat -h ---" -ForegroundColor DarkGray
$gout = & $GstatPath -h $Database 2>&1
$gtext = ($gout -join "`n")
Write-Host $gtext
if($LASTEXITCODE -eq 0 -and $gtext -match 'Page size'){
  Write-Host ">> CORRIGIDO com sucesso." -ForegroundColor Green
  exit 0
} else {
  Write-Host ">> Ainda com problema. Outro campo do header pode estar corrompido (ver procedure 03 secao 5)." -ForegroundColor Red
  exit 2
}
