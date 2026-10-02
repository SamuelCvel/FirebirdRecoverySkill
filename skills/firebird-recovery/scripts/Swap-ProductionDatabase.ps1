<#
.SYNOPSIS
  Troca o banco de producao pelo banco recuperado, com pre-checagens, -WhatIf e rollback.

.DESCRIPTION
  1. Pre-checagens (nada e alterado): os dois arquivos existem; o candidato le no gstat, esta online e
     sem nbackup travado; dialect igual ao da producao (e page size, salvo -AllowDifferentPageSize)
     quando o header da producao le; nenhum indice inativo/pendente no candidato; candidato conecta;
     espaco livre quando ha copia. Forced writes desligado no candidato vira aviso.
     -RunHealthCheck roda Test-FirebirdHealth.ps1 -Validation full no candidato antes (recomendado).
  2. Isolar a producao:
       -Isolation Service  (padrao) para Guardian e Server - todos os bancos; precisa Administrador.
       -Isolation Shutdown gfix -shut full -force 0 so neste banco; os outros seguem atendendo.
  3. Conferir que ninguem segura o arquivo (open exclusivo).
  4. Renomear a producao para <producao>.antigo.<data> (NUNCA apaga).
  5. Mover o candidato para o caminho de producao (-KeepCandidate copia, mantendo o candidato).
     Se 4-5 falharem, desfaz sozinho.
  6. Voltar: sobe o servico (modo Service). No modo Shutdown o arquivo novo ja entra online.
  7. Conferir: gstat -h + conexao isql. Imprime o passo de rollback.

  Pede confirmacao (ConfirmImpact High). Em execucao nao-interativa passe -Confirm:$false depois de
  mostrar o plano ao usuario; -WhatIf so mostra.

  Exit codes: 0 ok; 1 parametro ou pre-checagem; 2 falha na troca ou na conferencia final;
  3 sem permissao / arquivo em uso; 4 nada foi feito (-WhatIf ou confirmacao negada).

.EXAMPLE
  .\Swap-ProductionDatabase.ps1 -Production D:\dados\BANCO.FDB -Candidate D:\rec\BANCO_RECUPERADO.FDB -WhatIf
  .\Swap-ProductionDatabase.ps1 -Production D:\dados\BANCO.FDB -Candidate D:\rec\BANCO_RECUPERADO.FDB -Isolation Shutdown -RunHealthCheck
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
  [Parameter(Mandatory=$true)][string]$Production,
  [Parameter(Mandatory=$true)][string]$Candidate,
  [ValidateSet('Service','Shutdown')][string]$Isolation = 'Service',
  [switch]$KeepCandidate,
  [switch]$RunHealthCheck,
  [switch]$AllowDifferentPageSize,
  [string]$GstatPath = 'C:\Program Files\Firebird\Firebird_2_5\bin\gstat.exe',
  [string]$GfixPath  = 'C:\Program Files\Firebird\Firebird_2_5\bin\gfix.exe',
  [string]$IsqlPath  = 'C:\Program Files\Firebird\Firebird_2_5\bin\isql.exe',
  [string]$User     = $(if($env:ISC_USER){ $env:ISC_USER } else { 'SYSDBA' }),
  [string]$Password = $(if($env:ISC_PASSWORD){ $env:ISC_PASSWORD } else { 'masterkey' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_FirebirdCommon.ps1')
$GstatPath = Resolve-FbToolPath 'gstat' $GstatPath
$GfixPath  = Resolve-FbToolPath 'gfix'  $GfixPath
$IsqlPath  = Resolve-FbToolPath 'isql'  $IsqlPath

foreach($p in @($Production, $Candidate)){ if(-not (Test-Path -LiteralPath $p)){ Exit-FbError "Arquivo nao encontrado: $p" 1 } }
$Production = (Resolve-Path -LiteralPath $Production).Path
$Candidate  = (Resolve-Path -LiteralPath $Candidate).Path
if($Production -eq $Candidate){ Exit-FbError "Producao e candidato sao o mesmo arquivo." 1 }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$old   = "$Production.antigo.$stamp"

Write-Host ("==== Swap-ProductionDatabase  |  {0}  <=  {1}" -f $Production, $Candidate) -ForegroundColor Cyan

# ---------------- 1. pre-checagens ----------------
$problemas = New-Object System.Collections.Generic.List[string]
$hc = Get-FbHeaderInfo -GstatPath $GstatPath -Database $Candidate
if(-not $hc.Ok){ $problemas.Add("candidato: gstat -h nao leu o header") }
else {
  if($hc.Shutdown -ne 'none'){ $problemas.Add("candidato em shutdown ($($hc.Shutdown)) - rode 'gfix -online' nele") }
  if($hc.BackupLock){ $problemas.Add("candidato com nbackup travado (backup lock)") }
  if(-not $hc.ForcedWrites){ Write-Warning "candidato com forced writes DESLIGADO - recomendado: gfix -write sync antes da troca" }
}
$hp = Get-FbHeaderInfo -GstatPath $GstatPath -Database $Production
if($hp.Ok -and $hc.Ok){
  if($hp.Dialect -ne $hc.Dialect){ $problemas.Add("dialect diferente: producao $($hp.Dialect) x candidato $($hc.Dialect) (a aplicacao quebraria)") }
  if($hp.PageSize -ne $hc.PageSize -and -not $AllowDifferentPageSize){ $problemas.Add("page size diferente: producao $($hp.PageSize) x candidato $($hc.PageSize) (use -AllowDifferentPageSize se for intencional)") }
} elseif(-not $hp.Ok){
  Write-Warning "header da producao nao le (banco corrompido?) - sem comparar dialect/page size"
}
if($hc.Ok -and $hc.Shutdown -eq 'none'){
  $q = "SET HEADING OFF;`nSELECT 'NAO_ATIVOS=' || COUNT(*) FROM RDB`$INDICES WHERE COALESCE(RDB`$INDEX_INACTIVE,0)<>0 AND COALESCE(RDB`$SYSTEM_FLAG,0)=0;`n"
  $r = Invoke-FbIsql -IsqlPath $IsqlPath -Database $Candidate -Sql $q -User $User -Password $Password
  $m = [regex]::Match($r.Text, 'NAO_ATIVOS=(\d+)')
  if(-not $m.Success){ $problemas.Add("candidato nao conecta no isql: " + (($r.Lines | Select-Object -First 2) -join ' ')) }
  elseif([int]$m.Groups[1].Value -gt 0){ $problemas.Add("candidato tem $($m.Groups[1].Value) indice(s) inativo(s)/pendente(s) - procedure 05 secao 3") }
}
$mesmoVolume = ([IO.Path]::GetPathRoot($Production) -eq [IO.Path]::GetPathRoot($Candidate))
if($KeepCandidate -or -not $mesmoVolume){
  $livre = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Production)).AvailableFreeSpace
  $precisa = [long]((Get-Item -LiteralPath $Candidate).Length * 1.1)
  if($livre -lt $precisa){ $problemas.Add(("espaco insuficiente no volume da producao: livre {0:N0} MB, precisa {1:N0} MB" -f ($livre/1MB), ($precisa/1MB))) }
}
if($problemas.Count -gt 0){
  Write-Host "PRE-CHECAGEM FALHOU (nada foi alterado):" -ForegroundColor Red
  $problemas | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  exit 1
}
Write-Host ("  pre-checagens OK  (candidato: page size {0}, dialect {1}, {2})" -f $hc.PageSize, $hc.Dialect, $(if($hc.Attributes){$hc.Attributes}else{'sem atributos'})) -ForegroundColor Green

if($RunHealthCheck){
  Write-Host "  rodando Test-FirebirdHealth no candidato..." -ForegroundColor DarkGray
  & (Join-Path $PSScriptRoot 'Test-FirebirdHealth.ps1') -Database $Candidate -Validation full -User $User -Password $Password
  if($LASTEXITCODE -ne 0){ Exit-FbError "Health check do candidato com FALHA - troca cancelada (nada foi alterado)." 1 }
}

$acao = if($KeepCandidate){ 'copiar' } else { 'mover' }
if(-not $PSCmdlet.ShouldProcess($Production, ("renomear para '{0}' e {1} '{2}' no lugar (isolamento: {3})" -f (Split-Path $old -Leaf), $acao, $Candidate, $Isolation))){
  Write-Host "  Nada foi alterado." -ForegroundColor DarkGray
  exit 4
}

# ---------------- 2. isolar ----------------
$svcParados = @()
function Start-FbAgain {
  if($svcParados.Count -gt 0){
    $ordem = @($svcParados); [array]::Reverse($ordem)    # Server antes do Guardian
    foreach($n in $ordem){ try { Start-Service -Name $n -ErrorAction Stop } catch { Write-Warning "Nao subiu $n : $($_.Exception.Message)" } }
    Start-Sleep -Seconds 2
  }
}
if($Isolation -eq 'Service'){
  if(-not (Test-FbAdmin)){ Exit-FbError "-Isolation Service precisa de console como Administrador (ou use -Isolation Shutdown)." 3 }
  $svc = @(Get-FbServices | Where-Object State -eq 'Running' | Sort-Object { if($_.PathName -match '(?i)fbguard'){0}else{1} })
  foreach($s in $svc){ Write-Host "  parando $($s.Name)..." -ForegroundColor DarkGray; Stop-Service -Name $s.Name -Force; $svcParados += $s.Name }
  Start-Sleep -Seconds 2
} else {
  Write-Host "  gfix -shut full -force 0 na producao..." -ForegroundColor DarkGray
  $r = Invoke-FbNative -Exe $GfixPath -Arguments @('-shut', 'full', '-force', '0', $Production) -User $User -Password $Password
  if($r.Exit -ne 0){ Write-Warning ("gfix -shut falhou (normal se a producao esta corrompida): {0}" -f $r.Text) }
}

# ---------------- 3. ninguem segurando o arquivo ----------------
if(-not (Test-FbExclusiveOpen -Path $Production)){
  Start-FbAgain
  if($Isolation -eq 'Shutdown'){ [void](Invoke-FbNative -Exe $GfixPath -Arguments @('-online', $Production) -User $User -Password $Password) }
  Exit-FbError "A producao continua em uso por algum processo (aplicacao, antivirus, copia). Nada foi trocado." 3
}

# ---------------- 4-5. trocar ----------------
$renomeado = $false; $colocado = $false
try {
  Move-Item -LiteralPath $Production -Destination $old
  $renomeado = $true
  Write-Host ("  producao antiga guardada em: {0}" -f $old) -ForegroundColor DarkGray
  if($KeepCandidate){ Copy-Item -LiteralPath $Candidate -Destination $Production }
  else { Move-Item -LiteralPath $Candidate -Destination $Production }
  $colocado = $true
  Write-Host ("  candidato {0} para {1}" -f $(if($KeepCandidate){'copiado'}else{'movido'}), $Production) -ForegroundColor Green
} catch {
  Write-Host ("  FALHA na troca: {0}" -f $_.Exception.Message) -ForegroundColor Red
  if($renomeado -and -not $colocado){
    if($KeepCandidate -and (Test-Path -LiteralPath $Production)){ Remove-Item -LiteralPath $Production -Force }   # copia parcial feita por este script
    Move-Item -LiteralPath $old -Destination $Production
    Write-Host "  rollback feito: producao original de volta no lugar." -ForegroundColor Yellow
  }
  Start-FbAgain
  if($Isolation -eq 'Shutdown'){ [void](Invoke-FbNative -Exe $GfixPath -Arguments @('-online', $Production) -User $User -Password $Password) }
  exit 2
}

# ---------------- 6. voltar ----------------
Start-FbAgain

# ---------------- 7. conferir ----------------
$hn = Get-FbHeaderInfo -GstatPath $GstatPath -Database $Production
$con = Invoke-FbIsql -IsqlPath $IsqlPath -Database $Production -Sql "SET HEADING OFF;`nSELECT 'CONECTOU' FROM RDB`$DATABASE;`n" -User $User -Password $Password
$ok = $hn.Ok -and $hn.Shutdown -eq 'none' -and ($con.Text -match 'CONECTOU')
Write-Host ""
if($ok){ Write-Host (">> Troca concluida. {0}: online, {1}." -f $Production, $(if($hn.Attributes){$hn.Attributes}else{'sem atributos'})) -ForegroundColor Green }
else   { Write-Host (">> A troca foi feita, mas a conferencia falhou: gstat ok={0}, shutdown={1}, conexao={2}" -f $hn.Ok, $hn.Shutdown, ($con.Text -match 'CONECTOU')) -ForegroundColor Red }
Write-Host  ">> Rollback, se precisar (com o servico parado ou o banco em 'gfix -shut full -force 0'):" -ForegroundColor Yellow
Write-Host ("     Move-Item -LiteralPath `"{0}`" -Destination `"{0}.recuperado-falhou.{1}`"" -f $Production, $stamp) -ForegroundColor Yellow
Write-Host ("     Move-Item -LiteralPath `"{0}`" -Destination `"{1}`"" -f $old, $Production) -ForegroundColor Yellow
if($Isolation -eq 'Shutdown'){ Write-Host ("     (o arquivo antigo esta em full shutdown: para abri-lo, gfix -online `"{0}`")" -f $Production) -ForegroundColor Yellow }
Write-Host  ">> Nao apague o arquivo antigo por pelo menos 30 dias." -ForegroundColor DarkGray
if($ok){ exit 0 } else { exit 2 }
