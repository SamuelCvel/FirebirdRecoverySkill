<#
.SYNOPSIS
  Coleta evidencias do ambiente para a causa raiz de uma corrupcao Firebird (SOMENTE LEITURA).

.DESCRIPTION
  - Firebird: servicos e arquitetura (SuperServer / Classic / SuperClassic), versao do servidor
    (fbsvcmgr - tambem confirma usuario/senha), linhas ativas do firebird.conf.
  - Banco (-Database, opcional): disco local x rede, tamanho, forced writes e dicas do header.
  - Disco: saude (Get-PhysicalDisk), contadores de confiabilidade (precisa Administrador), espaco livre.
  - Windows (ultimos -Days dias): erros/avisos de disco e NTFS; desligamentos inesperados
    (Kernel-Power 41, EventLog 6008).
  - Defender: protecao em tempo real e exclusoes (ler exclusoes precisa Administrador).
  - firebird.log: bugcheck / consistency check / corrupt / I/O error / wrong page type / checksum.

  Nao altera nada. O que nao pode ser lido (permissao, recurso ausente) aparece como "nao lido".
  Gera <OutDir>\ambiente-firebird-<data>.md e mostra os achados no console.

.EXAMPLE
  .\Get-FirebirdEnvironmentReport.ps1 -Database D:\dados\BANCO.FDB
  .\Get-FirebirdEnvironmentReport.ps1 -Days 90 -OutDir C:\temp
#>
[CmdletBinding()]
param(
  [string]$Database,
  [int]$Days = 30,
  [int]$LogLines = 30,
  [string]$OutDir,
  [string]$GstatPath    = 'C:\Program Files\Firebird\Firebird_2_5\bin\gstat.exe',
  [string]$FbsvcmgrPath = 'C:\Program Files\Firebird\Firebird_2_5\bin\fbsvcmgr.exe',
  [string]$User     = $(if($env:ISC_USER){ $env:ISC_USER } else { 'SYSDBA' }),
  [string]$Password = $(if($env:ISC_PASSWORD){ $env:ISC_PASSWORD } else { 'masterkey' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_FirebirdCommon.ps1')
$GstatPath    = Resolve-FbToolPath 'gstat'    $GstatPath
$FbsvcmgrPath = Resolve-FbToolPath 'fbsvcmgr' $FbsvcmgrPath
if(-not $OutDir){ $OutDir = (Get-Location).Path }
if($Database -and -not (Test-Path -LiteralPath $Database)){ Exit-FbError "Banco nao encontrado: $Database" 1 }

$achados = New-Object System.Collections.Generic.List[string]
$md = New-Object System.Text.StringBuilder
function Sec([string]$t){ [void]$md.AppendLine(''); [void]$md.AppendLine("## $t"); [void]$md.AppendLine('') }
function Line([string]$t){ [void]$md.AppendLine($t) }
function Achado([string]$t){ $achados.Add($t); Write-Host ("  [!] " + $t) -ForegroundColor Yellow }

Write-Host "==== Relatorio de ambiente Firebird (somente leitura)" -ForegroundColor Cyan
Line "# Ambiente Firebird - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Line ''
Line "- Maquina: $env:COMPUTERNAME  |  Windows: $([Environment]::OSVersion.VersionString)  |  periodo de eventos: $Days dias"

# ---------------- Firebird ----------------
Sec 'Firebird'
$bin = Get-FbBinDir
$root = if($bin){ Split-Path $bin -Parent } else { $null }
Line "- Instalacao: $(if($root){$root}else{'nao encontrada'})"
$svc = @(Get-FbServices)
if($svc.Count -eq 0){ Line '- Servicos: nenhum encontrado (pode estar rodando como aplicacao)' }
foreach($s in $svc){
  $arq = switch -Regex ($s.PathName){ 'fbserver\.exe' { 'SuperServer' } 'fb_inet_server\.exe' { 'Classic' } 'fb_smp_server\.exe' { 'SuperClassic' } 'fbguard\.exe' { 'Guardian' } 'firebird\.exe' { 'Firebird 3+' } default { '?' } }
  Line ("- Servico ``{0}``: {1}, inicio {2}, {3}" -f $s.Name, $s.State, $s.StartMode, $arq)
}
$ver = $null
try { $ver = Get-FbServerVersion -FbsvcmgrPath $FbsvcmgrPath -User $User -Password $Password } catch { }
Line "- Versao do servidor: $(if($ver){$ver}else{'nao lida (servidor fora do ar ou usuario/senha)'})"
if($ver -and $ver -lt [version]'2.5.4.0'){ Achado "servidor $ver nao tem validacao online (2.5.4+); considere atualizar para 2.5.9" }
if($root -and (Test-Path -LiteralPath (Join-Path $root 'firebird.conf'))){
  $conf = @(Get-Content -LiteralPath (Join-Path $root 'firebird.conf') | Where-Object { $_ -match '^\s*[A-Za-z]' })
  Line "- firebird.conf - linhas ativas: $(if($conf.Count){''}else{'(nenhuma - tudo no padrao)'})"
  foreach($c in $conf){ Line ("  - ``{0}``" -f $c.Trim()) }
  if($conf -match '^\s*RemoteFileOpenAbility\s*=\s*1'){ Achado 'RemoteFileOpenAbility = 1: o servidor aceita abrir banco em compartilhamento de rede (risco de corrupcao)' }
}

# ---------------- Banco ----------------
if($Database){
  Sec 'Banco'
  $full = (Resolve-Path -LiteralPath $Database).Path
  $fi = Get-Item -LiteralPath $full
  $tipo = 'local'
  if($full.StartsWith('\\')){ $tipo = 'REDE (caminho UNC)' }
  else {
    $dl = $full.Substring(0, 2)
    $ld = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$dl'" -ErrorAction SilentlyContinue
    if($ld -and $ld.DriveType -eq 4){ $tipo = "REDE (unidade mapeada $dl)" }
    elseif($ld -and $ld.DriveType -eq 2){ $tipo = "removivel ($dl)" }
  }
  Line "- Arquivo: ``$full``"
  Line ("- Tamanho: {0:N0} bytes  |  ultima gravacao: {1}" -f $fi.Length, $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
  Line "- Disco: $tipo"
  if($tipo -like 'REDE*'){ Achado 'banco em compartilhamento de rede: o Firebird nao foi feito para isso (corrupcao por cache/lock de rede)' }
  $h = Get-FbHeaderInfo -GstatPath $GstatPath -Database $full
  if($h.Ok){
    Line ("- Header: page size {0}, ODS {1}, dialect {2}, Attributes: {3}" -f $h.PageSize, $h.OdsVersion, $h.Dialect, $(if($h.Attributes){$h.Attributes}else{'(nenhum)'}))
    Line ("- Transacoes: Next {0:N0}, OIT {1:N0}, OAT {2:N0}" -f $h.NextTransaction, $h.OldestTransaction, $h.OldestActive)
    foreach($x in @(Get-FbHeaderHints -Info $h)){ Line ("- {0}: {1}" -f $x.Nivel, $x.Texto); if($x.Nivel -ne 'INFO'){ Achado $x.Texto } }
  } else { Line '- Header: gstat -h nao leu (ver Diagnose-FirebirdHeader.ps1)'; Achado 'gstat -h nao le o header do banco' }
}

# ---------------- Disco ----------------
Sec 'Disco'
try {
  foreach($d in @(Get-PhysicalDisk -ErrorAction Stop)){
    Line ("- ``{0}`` ({1}, {2:N0} GB): saude {3}, estado {4}" -f $d.FriendlyName, $d.MediaType, ($d.Size / 1GB), $d.HealthStatus, $d.OperationalStatus)
    if("$($d.HealthStatus)" -ne 'Healthy'){ Achado ("disco {0} com saude {1}" -f $d.FriendlyName, $d.HealthStatus) }
  }
} catch { Line '- Get-PhysicalDisk: nao lido' }
try {
  $rc = @(Get-PhysicalDisk -ErrorAction Stop | Get-StorageReliabilityCounter -ErrorAction Stop)
  foreach($r in $rc){
    Line ("- Confiabilidade {0}: leituras nao corrigidas {1}, escritas nao corrigidas {2}, desgaste {3}%, temperatura {4} C" -f $r.DeviceId, $r.ReadErrorsUncorrected, $r.WriteErrorsUncorrected, $r.Wear, $r.Temperature)
    if($r.ReadErrorsUncorrected -gt 0 -or $r.WriteErrorsUncorrected -gt 0){ Achado ("disco {0} com erros nao corrigidos (leitura {1}, escrita {2})" -f $r.DeviceId, $r.ReadErrorsUncorrected, $r.WriteErrorsUncorrected) }
  }
} catch { Line '- Contadores de confiabilidade: nao lidos (precisa Administrador)' }
foreach($v in [IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -eq 'Fixed' }){
  $pct = 100.0 * $v.AvailableFreeSpace / [Math]::Max([int64]1, [int64]$v.TotalSize)
  Line ("- Volume {0} livre {1:N1} GB ({2:N0}%)" -f $v.Name, ($v.AvailableFreeSpace / 1GB), $pct)
  if($pct -lt 10){ Achado ("volume {0} com {1:N0}% livre (disco cheio corrompe banco)" -f $v.Name, $pct) }
}

# ---------------- Eventos do Windows ----------------
Sec "Eventos do Windows (ultimos $Days dias)"
$desde = (Get-Date).AddDays(-$Days)
try {
  $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'disk','Ntfs','Microsoft-Windows-Ntfs','stornvme','storahci'; StartTime = $desde } -ErrorAction Stop | Where-Object Level -le 3)
} catch { $ev = @() }
Line "- Erros/avisos de disco e NTFS: $($ev.Count)"
foreach($e in ($ev | Select-Object -First 10)){ Line ("  - {0} {1} id {2}: {3}" -f $e.TimeCreated.ToString('yyyy-MM-dd HH:mm'), $e.ProviderName, $e.Id, (($e.Message -split "`r?`n")[0])) }
if(@($ev | Where-Object Level -le 2).Count -gt 0){ Achado ("{0} erro(s) de disco/NTFS no log do sistema" -f @($ev | Where-Object Level -le 2).Count) }
try {
  $sd = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power','EventLog'; Id = 41, 6008; StartTime = $desde } -ErrorAction Stop)
} catch { $sd = @() }
Line "- Desligamentos inesperados (Kernel-Power 41 / EventLog 6008): $($sd.Count)"
foreach($e in ($sd | Select-Object -First 10)){ Line ("  - {0} id {1}" -f $e.TimeCreated.ToString('yyyy-MM-dd HH:mm'), $e.Id) }
if($sd.Count -gt 0){ Achado ("{0} desligamento(s) inesperado(s) - combinado com forced writes desligado, e a causa classica de corrupcao" -f $sd.Count) }

# ---------------- Defender ----------------
Sec 'Antivirus (Microsoft Defender)'
try {
  $st = Get-MpComputerStatus -ErrorAction Stop
  Line ("- Protecao em tempo real: {0}" -f $st.RealTimeProtectionEnabled)
  $pref = Get-MpPreference -ErrorAction Stop
  $ex = @($pref.ExclusionPath) + @($pref.ExclusionExtension) + @($pref.ExclusionProcess) | Where-Object { $_ }
  if($ex -match 'Must be an administrator|N/A'){ Line '- Exclusoes: nao lidas (precisa Administrador)' }
  else {
    Line ("- Exclusoes: {0}" -f $(if($ex.Count){ ($ex -join '; ') } else { '(nenhuma)' }))
    if($st.RealTimeProtectionEnabled -and $Database){
      $pasta = Split-Path (Resolve-Path -LiteralPath $Database).Path -Parent
      $coberto = $ex | Where-Object { $pasta -like "$_*" -or $_ -match '(?i)^\.?(fdb|gdb|ib)$' -or $_ -match '(?i)fbserver|fb_inet_server|fb_smp_server' }
      if(-not $coberto){ Achado 'Defender em tempo real sem exclusao para a pasta/extensao do banco ou para o servidor Firebird' }
    }
  }
} catch { Line '- Defender: nao lido (ausente, desativado por outro antivirus, ou sem permissao)' }

# ---------------- firebird.log ----------------
Sec 'firebird.log'
$log = if($root){ Join-Path $root 'firebird.log' } else { $null }
if($log -and (Test-Path -LiteralPath $log)){
  $pad = 'bugcheck|consistency check|corrupt|I/O error|wrong page type|checksum error'
  $m = @(Select-String -LiteralPath $log -Pattern $pad)
  Line ("- {0} linha(s) relevantes (padrao: {1})" -f $m.Count, $pad)
  foreach($x in ($m | Select-Object -Last $LogLines)){ Line ("  - linha {0}: ``{1}``" -f $x.LineNumber, $x.Line.Trim()) }
  if(@($m | Where-Object { $_.Line -match 'bugcheck|consistency check' }).Count -gt 0){ Achado 'firebird.log registra bugcheck/consistency check (corrupcao interna)' }
} else { Line '- firebird.log nao encontrado' }

# ---------------- achados ----------------
Sec 'Achados'
if($achados.Count -eq 0){ Line '- Nenhum sinal de risco nas evidencias coletadas.' } else { foreach($a in $achados){ Line "- $a" } }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$arq = Join-Path $OutDir ("ambiente-firebird-{0}.md" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
[IO.File]::WriteAllText($arq, $md.ToString(), (New-Object Text.UTF8Encoding($false)))
Write-Host ""
Write-Host (">> {0} achado(s). Relatorio: {1}" -f $achados.Count, $arq) -ForegroundColor $(if($achados.Count){'Yellow'}else{'Green'})
exit 0
