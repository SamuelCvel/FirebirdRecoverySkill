<#
.SYNOPSIS
  Demonstra (de forma REVERSIVEL) a corrupcao de 1 byte no cabecalho de um banco
  Firebird 2.5 -- um defeito real ja visto em campo -- e como identifica-lo e corrigi-lo.

.DESCRIPTION
  O campo page_size fica no offset 0x10 (2 bytes, little-endian) da pagina 0 (header).
  Ligar o bit 0x80 no byte do offset 0x11 transforma, por ex., 16384 (0x4000) em
  49152 (0xC000) -- valor invalido -- e o banco deixa de abrir.

  Acoes:
    setup    -> copia o banco de exemplo do Firebird (EMPLOYEE.FDB) para -Database,
                para treinar SEM usar banco de cliente
    status   -> leitura rapida do header (page_size lido x valido) -- nao usa o servidor
    diagnose -> status + detecta o page_size REAL por varredura + roda 'gstat -h'
    corrupt  -> salva o valor original (.hdrbak) e liga o bit 0x80  (QUEBRA o banco)
    fix      -> regrava o page_size correto (reversivel) e confirma com 'gstat -h'

  Script independente (nao depende dos outros scripts da skill) para poder ser
  entregue sozinho a equipe. Funciona no Windows PowerShell 5.1 e no PowerShell 7.

  SERVICO FIREBIRD:
    * Ler/diagnosticar NAO exige parar o servico.
    * Escrever bytes (corrupt/fix) exige que ESTE banco nao esteja aberto pelo servidor:
        -Isolate     => 'gfix -shut full -force 0' / 'gfix -online' so neste banco (recomendado)
        -StopService => para/reinicia TODO o servico Firebird (precisa de Administrador)
        (sem nenhum) => tenta abrir em modo exclusivo; se o servidor estiver com o banco
                        aberto, AVISA e aborta sem alterar nada.
    * gfix/gbak exigem o servico NO AR.

  corrupt e fix pedem confirmacao; -Force (ou -Confirm:$false) pula, -WhatIf so mostra.

.EXAMPLE
  .\Demo-CorrupcaoHeader.ps1 -Database C:\teste\DEMO.FDB -Action setup
  .\Demo-CorrupcaoHeader.ps1 -Database C:\teste\DEMO.FDB -Action status
  .\Demo-CorrupcaoHeader.ps1 -Database C:\teste\DEMO.FDB -Action corrupt -Isolate -Force
  .\Demo-CorrupcaoHeader.ps1 -Database C:\teste\DEMO.FDB -Action diagnose
  .\Demo-CorrupcaoHeader.ps1 -Database C:\teste\DEMO.FDB -Action fix -Isolate
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
  [Parameter(Mandatory=$true)][string]$Database,
  [Parameter(Mandatory=$true)][ValidateSet('setup','corrupt','fix','diagnose','status')][string]$Action,
  [string]$GstatPath = 'C:\Program Files\Firebird\Firebird_2_5\bin\gstat.exe',
  [string]$GfixPath  = 'C:\Program Files\Firebird\Firebird_2_5\bin\gfix.exe',
  [string]$User      = 'SYSDBA',
  [string]$Password  = 'masterkey',
  [switch]$Isolate,
  [switch]$StopService,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
if($Force){ $ConfirmPreference = 'None' }
$VALID     = 1024,2048,4096,8192,16384
$GuardSvc  = 'FirebirdGuardianDefaultInstance'
$ServerSvc = 'FirebirdServerDefaultInstance'
$bakFile   = "$Database.hdrbak"

# ---------- helpers de baixo nivel ----------
function Invoke-Exe([string]$Exe, [string[]]$Arguments){
  # No PS 5.1, com ErrorActionPreference=Stop, stderr de um .exe vira erro terminante.
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $lines = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $prev }
  return [pscustomobject]@{ Exit = $code; Text = ($lines -join "`n") }
}
function Read-Bytes([string]$path,[long]$off,[int]$len){
  $fs = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
  try { [void]$fs.Seek($off,'Begin'); $b = New-Object byte[] $len; [void]$fs.Read($b,0,$len); return ,$b }
  finally { $fs.Dispose() }
}
function Get-ClaimedPageSize([string]$path){ return [BitConverter]::ToUInt16((Read-Bytes $path 16 2),0) }

function Find-RealPageSize([string]$path){
  # A pagina 1 (PIP, pag_type 2) ou a 2 (TIP, pag_type 3) tem o checksum 12345 (0x3039)
  # nos bytes [+2..+3]. O 1o page_size candidato em que uma delas casa = page_size real.
  $len = (Get-Item -LiteralPath $path).Length
  foreach($sz in $VALID){
    foreach($pr in @(@(1,2),@(2,3))){
      $off = [long]$sz * $pr[0]
      if($off + 4 -gt $len){ continue }
      $b = Read-Bytes $path $off 4
      if($b[0] -eq $pr[1] -and $b[2] -eq 0x39 -and $b[3] -eq 0x30){ return [int]$sz }
    }
  }
  return 0
}
function Write-BytesExclusive([string]$path,[long]$off,[byte[]]$vals){
  try { $fs = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
  catch { throw "Nao consegui abrir o arquivo em modo EXCLUSIVO. O servidor Firebird provavelmente esta com este banco ABERTO. Use -Isolate (gfix -shut full) ou -StopService. Detalhe: $($_.Exception.Message)" }
  try { [void]$fs.Seek($off,'Begin'); $fs.Write($vals,0,$vals.Length); $fs.Flush() }
  finally { $fs.Dispose() }
}
function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}
function Invoke-Gstat([string]$path){ return Invoke-Exe $GstatPath @('-h', $path) }

# ---------- isolar SOMENTE este banco (gfix) ----------
function Db-Shutdown([string]$path){
  Write-Host "  gfix -shut full -force 0 (tira so este banco de linha) ..." -ForegroundColor DarkGray
  $r = Invoke-Exe $GfixPath @('-shut','full','-force','0','-user',$User,'-password',$Password,$path)
  if($r.Exit -ne 0){ throw "Falha no gfix -shut (Exit=$($r.Exit)): $($r.Text)" }
}
function Db-Online([string]$path){
  Write-Host "  gfix -online (devolve o banco para producao) ..." -ForegroundColor DarkGray
  $r = Invoke-Exe $GfixPath @('-online','-user',$User,'-password',$Password,$path)
  if($r.Exit -ne 0){ Write-Warning "gfix -online retornou Exit=$($r.Exit) -- verifique manualmente. $($r.Text)" }
}

# ---------- parar/reiniciar TODO o servico ----------
$script:SvcStopped = $false
function Service-StopIfRequested {
  if(-not $StopService){ return }
  if(-not (Test-Admin)){ throw "-StopService exige console aberto como Administrador." }
  Write-Host "  Parando o servico Firebird (guardian + server)..." -ForegroundColor DarkGray
  Stop-Service $GuardSvc  -Force -ErrorAction SilentlyContinue
  Stop-Service $ServerSvc -Force -ErrorAction SilentlyContinue
  $script:SvcStopped = $true
  Start-Sleep -Seconds 1
}
function Service-StartIfStopped {
  if($script:SvcStopped){
    Write-Host "  Reiniciando o servico Firebird..." -ForegroundColor DarkGray
    Start-Service $ServerSvc -ErrorAction SilentlyContinue
    Start-Service $GuardSvc  -ErrorAction SilentlyContinue
  }
}

function Show-Header([string]$path){
  $claim = Get-ClaimedPageSize $path
  $b     = Read-Bytes $path 16 2
  $ok    = $VALID -contains [int]$claim
  Write-Host ("  page_size no header : {0,-6}  (bytes 0x{1:X2} 0x{2:X2}, offset 0x10-0x11)" -f $claim,$b[0],$b[1])
  if($ok){ Write-Host "  -> VALIDO" -ForegroundColor Green } else { Write-Host "  -> INVALIDO (corrompido)" -ForegroundColor Red }
  return $ok
}

# ================= pre-checks =================
Write-Host ("==== Demo corrupcao de header Firebird  |  Acao: {0}  |  {1} ====" -f $Action.ToUpper(),$Database) -ForegroundColor Cyan
if($Action -ne 'setup' -and -not (Test-Path -LiteralPath $Database)){ throw "Banco nao encontrado: $Database (use -Action setup para criar um banco de treino)" }

switch($Action){

  'setup' {
    $root = Split-Path (Split-Path $GstatPath -Parent) -Parent
    $sample = Join-Path $root 'examples\empbuild\EMPLOYEE.FDB'
    if(-not (Test-Path -LiteralPath $sample)){ throw "Banco de exemplo nao encontrado: $sample" }
    if((Test-Path -LiteralPath $Database) -and -not $Force){ throw "Ja existe: $Database (use -Force para sobrescrever)" }
    $dir = Split-Path $Database -Parent
    if($dir -and -not (Test-Path -LiteralPath $dir)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -LiteralPath $sample -Destination $Database -Force
    Remove-Item -LiteralPath $bakFile -ErrorAction SilentlyContinue
    Write-Host "  Banco de treino criado a partir de $sample" -ForegroundColor Green
    [void](Show-Header $Database)
  }

  'status' {
    [void](Show-Header $Database)
    $real = Find-RealPageSize $Database
    if($real){ Write-Host "  page_size REAL (varredura) : $real" -ForegroundColor Yellow }
    else     { Write-Host "  page_size REAL: nao detectado por varredura." -ForegroundColor Yellow }
  }

  'diagnose' {
    $ok   = Show-Header $Database
    $real = Find-RealPageSize $Database
    if($real){ Write-Host "  page_size REAL (varredura) : $real" -ForegroundColor Yellow }
    Write-Host "  --- gstat -h ---" -ForegroundColor DarkGray
    $g = Invoke-Gstat $Database
    Write-Host $g.Text
    if(($g.Text -match 'unable to allocate memory') -or ($g.Exit -ne 0) -or (-not $ok)){
      Write-Host "  >> SINTOMA classico de header corrompido (gstat nao leu o cabecalho)." -ForegroundColor Red
      if($real){
        $lo = $real -band 0xFF; $hi = ($real -shr 8) -band 0xFF
        Write-Host ("  >> Correcao: gravar page_size={0} (bytes 0x{1:X2} 0x{2:X2}) no offset 0x10. Rode: -Action fix" -f $real,$lo,$hi) -ForegroundColor Green
      }
    } else {
      Write-Host "  >> Cabecalho OK." -ForegroundColor Green
    }
  }

  'corrupt' {
    if(-not (Show-Header $Database)){ Write-Warning "Header ja parece invalido. Abortando para nao mascarar o estado."; break }
    Write-Warning "Isto vai QUEBRAR o banco de proposito. Use APENAS em banco de TESTE."
    if(-not $PSCmdlet.ShouldProcess($Database, 'ligar o bit 0x80 do byte 0x11 (corromper page_size)')){ Write-Host "Cancelado."; break }
    $orig = Get-ClaimedPageSize $Database
    Set-Content -LiteralPath $bakFile -Value "PAGESIZE=$orig" -Encoding ASCII
    Write-Host "  Valor original salvo em: $bakFile  (PAGESIZE=$orig)" -ForegroundColor DarkGray
    try {
      Service-StopIfRequested
      if($Isolate){ Db-Shutdown $Database }
      $hi    = (Read-Bytes $Database 17 1)[0]
      $newHi = [byte]($hi -bor 0x80)
      Write-BytesExclusive $Database 17 ([byte[]]@($newHi))
      Write-Host ("  Byte 0x11 alterado: 0x{0:X2} -> 0x{1:X2}  (bit 0x80 ligado)" -f $hi,$newHi) -ForegroundColor Red
    } finally { Service-StartIfStopped }
    Write-Host ("  CORROMPIDO. page_size agora: {0} (invalido). Rode '-Action diagnose'." -f (Get-ClaimedPageSize $Database)) -ForegroundColor Yellow
  }

  'fix' {
    [void](Show-Header $Database)
    $target = 0
    if(Test-Path -LiteralPath $bakFile){
      if(((Get-Content -LiteralPath $bakFile | Select-Object -First 1)) -match 'PAGESIZE=(\d+)'){ $target = [int]$Matches[1] }
      Write-Host "  Valor original do backup (.hdrbak): $target" -ForegroundColor DarkGray
    }
    if($target -le 0){
      $target = Find-RealPageSize $Database
      Write-Host "  Sem backup; page_size REAL detectado por varredura: $target" -ForegroundColor DarkGray
    }
    if(-not ($VALID -contains $target)){ throw "Nao consegui determinar um page_size valido para corrigir (obtido: $target)." }
    if(-not $PSCmdlet.ShouldProcess($Database, "regravar page_size=$target no offset 0x10")){ Write-Host "Cancelado."; break }
    $lo = [byte]($target -band 0xFF); $hi = [byte](($target -shr 8) -band 0xFF)
    try {
      Service-StopIfRequested
      Write-BytesExclusive $Database 16 ([byte[]]@($lo, $hi))
      Write-Host ("  page_size regravado: {0} (bytes 0x{1:X2} 0x{2:X2})" -f $target,$lo,$hi) -ForegroundColor Green
      if($Isolate){ Db-Online $Database }
    } finally { Service-StartIfStopped }
    Write-Host "  --- gstat -h (confirmacao) ---" -ForegroundColor DarkGray
    $g = Invoke-Gstat $Database
    Write-Host $g.Text
    if($g.Exit -eq 0 -and $g.Text -match 'Page size'){ Write-Host "  >> CORRIGIDO com sucesso." -ForegroundColor Green }
    else { Write-Host "  >> Ainda com problema; verifique." -ForegroundColor Red }
  }
}
