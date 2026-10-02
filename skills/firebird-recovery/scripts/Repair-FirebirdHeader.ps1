<#
.SYNOPSIS
  Conserta o campo page_size do cabecalho de um banco Firebird 2.5 corrompido.
  Reversivel via sidecar (.hdrbak) ou heuristica de varredura.

.DESCRIPTION
  Restaura o page_size correto no offset 0x10 (USHORT little-endian) da pagina 0.
  Fonte do valor correto (nesta ordem de preferencia):
    1) -PageSize informado explicitamente.
    2) Sidecar '<Database>.hdrbak' contendo 'PAGESIZE=NNNN'.
    3) Varredura: procura a pagina 1 (PIP) ou 2 (TIP) nos offsets candidatos
       (1024..16384), identificando-a por checksum 12345 e pag_type.
  Se sidecar e varredura discordarem, o script PARA (informe -PageSize).

  Recusa operar se o header LIDO ja parece valido (evita "consertar" o que esta bom);
  -AllowValidHeader desliga essa trava. Grava seu proprio sidecar antes de escrever,
  para permitir reverter.

  Confirmacao: o script pede confirmacao antes de gravar. Em execucao nao-interativa
  passe -Confirm:$false (depois de mostrar o plano ao usuario). -WhatIf mostra o que
  faria sem gravar nada.

  Com o header corrompido o servidor NAO consegue abrir o arquivo, entao normalmente
  nao e preciso isolar nada. Se algum processo segurar o arquivo:
    -Isolate     : gfix -shut full -force 0 / gfix -online (so esse banco).
    -StopService : para/reinicia o servico Firebird inteiro (precisa Admin).

  Exit codes: 0 corrigido; 1 recusado (header ja valido) ou parametro invalido;
  2 valor-alvo indeterminado/ambiguo ou gstat ainda falha; 3 arquivo ausente, em uso
  ou sem permissao; 4 nada foi feito (-WhatIf ou confirmacao negada).

.EXAMPLE
  .\Repair-FirebirdHeader.ps1 -Database C:\path\COPIA.FDB
  .\Repair-FirebirdHeader.ps1 -Database C:\path\COPIA.FDB -WhatIf
  .\Repair-FirebirdHeader.ps1 -Database C:\path\COPIA.FDB -Confirm:$false
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
  [Parameter(Mandatory=$true)][string]$Database,
  [ValidateSet(0,1024,2048,4096,8192,16384)][int]$PageSize = 0,
  [string]$GstatPath = 'C:\Program Files\Firebird\Firebird_2_5\bin\gstat.exe',
  [string]$GfixPath  = 'C:\Program Files\Firebird\Firebird_2_5\bin\gfix.exe',
  [string]$User      = $(if($env:ISC_USER){ $env:ISC_USER } else { 'SYSDBA' }),
  [string]$Password  = $(if($env:ISC_PASSWORD){ $env:ISC_PASSWORD } else { 'masterkey' }),
  [switch]$Isolate,
  [switch]$StopService,
  [switch]$AllowValidHeader
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_FirebirdCommon.ps1')
$GstatPath = Resolve-FbToolPath 'gstat' $GstatPath
$GfixPath = Resolve-FbToolPath 'gfix' $GfixPath

$bakFile = "$Database.hdrbak"
if(-not (Test-Path -LiteralPath $Database)){ Exit-FbError "Banco nao encontrado: $Database" 3 }
Write-Host ("==== Repair-FirebirdHeader  |  {0} ====" -f $Database) -ForegroundColor Cyan

$claim = [BitConverter]::ToUInt16((Read-FbBytes -Path $Database -Offset 16 -Count 2), 0)
$claimedValid = $script:FbValidPageSizes -contains [int]$claim
Write-Host ("  page_size lido atual: {0}  ({1})" -f $claim, $(if($claimedValid){'VALIDO'}else{'INVALIDO'}))

if($claimedValid -and -not $AllowValidHeader){
  Write-Warning "O header lido parece VALIDO. Este script recusa operar sobre header bom para evitar piorar."
  Write-Host  "  Se voce esta CERTO que precisa forcar, use -AllowValidHeader." -ForegroundColor Yellow
  exit 1
}

# Determinar valor alvo
$fromBak = 0
if(Test-Path -LiteralPath $bakFile){
  $line = Get-Content -LiteralPath $bakFile | Select-Object -First 1
  if($line -match 'PAGESIZE=(\d+)'){ $fromBak = [int]$Matches[1] }
}
$fromScan = Find-FbRealPageSize -Path $Database
Write-Host ("  sidecar .hdrbak     : {0}" -f $(if($fromBak){$fromBak}else{'(nao ha)'}))
Write-Host ("  varredura (PIP/TIP) : {0}" -f $(if($fromScan){$fromScan}else{'(nao detectou)'}))

$target = 0; $source = ''
if($PageSize -gt 0){ $target = $PageSize; $source = 'parametro -PageSize' }
elseif($fromBak -gt 0 -and $fromScan -gt 0 -and $fromBak -ne $fromScan){
  Exit-FbError ("Sidecar ({0}) e varredura ({1}) discordam. Confira e informe -PageSize explicitamente." -f $fromBak, $fromScan) 2
}
elseif($fromBak -gt 0){ $target = $fromBak; $source = "sidecar $bakFile" }
elseif($fromScan -gt 0){ $target = $fromScan; $source = 'varredura das paginas 1/2' }

if(-not ($script:FbValidPageSizes -contains $target)){
  Exit-FbError "Nao consegui determinar um page_size valido para corrigir (obtido: $target). Veja a procedure 03 secao 5." 2
}
Write-Host ("  page_size alvo : {0}  (fonte: {1})" -f $target, $source) -ForegroundColor Yellow

$lo = [byte]($target -band 0xFF); $hi = [byte](($target -shr 8) -band 0xFF)
if(-not $PSCmdlet.ShouldProcess($Database, ("gravar page_size={0} (bytes 0x{1:X2} 0x{2:X2}) no offset 0x10" -f $target, $lo, $hi))){
  Write-Host "  Nada foi gravado." -ForegroundColor DarkGray
  exit 4
}

# Sidecar do estado atual (para reverter o reparo, se preciso)
$preBak = "$Database.pre-repair.hdrbak"
Set-Content -LiteralPath $preBak -Value "PAGESIZE=$claim" -Encoding ASCII
Write-Host "  Estado pre-reparo salvo em: $preBak" -ForegroundColor DarkGray

$svcParados = @()
try {
  if($StopService){
    if(-not (Test-FbAdmin)){ Exit-FbError "-StopService exige console como Administrador." 3 }
    $svc = @(Get-FbServices | Sort-Object { if($_.PathName -match '(?i)fbguard'){0}else{1} })
    foreach($s in $svc){ if($s.State -eq 'Running'){ Stop-Service -Name $s.Name -Force; $svcParados += $s.Name } }
    Start-Sleep -Seconds 2
  }
  if($Isolate){
    Write-Host "  gfix -shut full -force 0 ..." -ForegroundColor DarkGray
    $r = Invoke-FbNative -Exe $GfixPath -Arguments @('-shut','full','-force','0',$Database) -User $User -Password $Password
    if($r.Exit -ne 0){ Write-Warning ("gfix -shut nao funcionou (normal com header corrompido): {0}" -f $r.Text) }
  }

  try { $fs = [IO.File]::Open($Database, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
  catch { Exit-FbError ("Nao consegui abrir o arquivo em modo EXCLUSIVO (algum processo o segura). Procedure 02 secao 4. Detalhe: {0}" -f $_.Exception.Message) 3 }
  try {
    [void]$fs.Seek(16, 'Begin')
    $fs.Write([byte[]]@($lo, $hi), 0, 2)
    $fs.Flush()
  } finally { $fs.Dispose() }
  Write-Host ("  page_size regravado: {0} (bytes 0x{1:X2} 0x{2:X2})" -f $target, $lo, $hi) -ForegroundColor Green

  if($Isolate){
    $r = Invoke-FbNative -Exe $GfixPath -Arguments @('-online',$Database) -User $User -Password $Password
    if($r.Exit -ne 0){ Write-Warning ("gfix -online retornou Exit={0}: {1}" -f $r.Exit, $r.Text) }
  }
} finally {
  # religa na ordem inversa: Server antes do Guardian
  [array]::Reverse($svcParados)
  foreach($n in $svcParados){ Start-Service -Name $n -ErrorAction SilentlyContinue }
}

# Verificar com gstat -h
Write-Host "  --- gstat -h ---" -ForegroundColor DarkGray
$g = Invoke-FbNative -Exe $GstatPath -Arguments @('-h', $Database)
Write-Host $g.Text
if($g.Exit -eq 0 -and $g.Text -match 'Page size'){
  Write-Host ">> CORRIGIDO com sucesso." -ForegroundColor Green
  exit 0
} else {
  Write-Host ">> Ainda com problema. Outro campo do header pode estar corrompido (ver procedure 03 secao 5)." -ForegroundColor Red
  exit 2
}
