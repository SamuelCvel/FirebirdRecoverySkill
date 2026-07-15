<#
.SYNOPSIS
  Diagnostico SOMENTE LEITURA do cabecalho de um banco Firebird 2.5.
  Nao altera o arquivo. Pode rodar com o servidor no ar e o banco em uso.

.DESCRIPTION
  Le os primeiros bytes do header (pagina 0), reporta o page_size declarado,
  verifica se e valido, e faz uma varredura para descobrir o page_size REAL
  (procurando a pagina 1, PIP, com checksum 12345 = 0x3039 nos offsets candidatos).
  Em seguida roda 'gstat -h' e interpreta a saida.

  Resultados possiveis (impressos e refletidos no exit code):
    0  Header OK; sem corrupcao detectada na fase leitura.
    1  page_size declarado INVALIDO mas REAL detectado (caso classico).
    2  Header ilegivel e scan tambem falhou; corrupcao maior.
    3  Erro de execucao (gstat ausente, arquivo nao encontrado).

.PARAMETER Database
  Caminho completo do .fdb/.gdb/.ib a inspecionar.

.PARAMETER GstatPath
  Caminho do gstat.exe (padrao: instalacao FB 2.5).

.EXAMPLE
  .\Diagnose-FirebirdHeader.ps1 -Database C:\path\BANCO.FDB
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Database,
  [string]$GstatPath = 'C:\Program Files\Firebird\Firebird_2_5\bin\gstat.exe'
)

$ErrorActionPreference = 'Stop'
$VALID = 1024,2048,4096,8192,16384

function Read-Bytes([string]$path,[long]$off,[int]$len){
  $fs = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
  try { [void]$fs.Seek($off,'Begin'); $b = New-Object byte[] $len; [void]$fs.Read($b,0,$len); return $b }
  finally { $fs.Dispose() }
}
function Get-ClaimedPageSize([string]$path){ return [BitConverter]::ToUInt16((Read-Bytes $path 16 2),0) }
function Get-OdsVersion([string]$path){ return [BitConverter]::ToUInt16((Read-Bytes $path 18 2),0) }
function Find-RealPageSize([string]$path){
  foreach($sz in $VALID){
    try { $b = Read-Bytes $path $sz 4 } catch { continue }
    if($b.Length -ge 4 -and $b[2] -eq 0x39 -and $b[3] -eq 0x30 -and $b[0] -ge 1 -and $b[0] -le 12){ return [int]$sz }
  }
  return 0
}

if(-not (Test-Path -LiteralPath $Database)){ Write-Error "Banco nao encontrado: $Database"; exit 3 }
if(-not (Test-Path -LiteralPath $GstatPath)){ Write-Error "gstat.exe nao encontrado em: $GstatPath"; exit 3 }

Write-Host ("==== Diagnostico de header  |  {0} ====" -f $Database) -ForegroundColor Cyan

# Leitura local
$claim = Get-ClaimedPageSize $Database
$bytes = Read-Bytes $Database 16 2
$ods   = Get-OdsVersion $Database
$claimedValid = $VALID -contains [int]$claim

# Pag_type da pagina 0 (deveria ser 1)
$pagType0 = (Read-Bytes $Database 0 1)[0]
$checksum0 = [BitConverter]::ToUInt16((Read-Bytes $Database 2 2),0)

Write-Host ""
Write-Host "Leitura do header (offset 0x00..0x13):" -ForegroundColor White
Write-Host ("  pag_type pagina 0 : 0x{0:X2}  (esperado 0x01 = header)" -f $pagType0)
Write-Host ("  checksum          : {0}      (esperado 12345)" -f $checksum0)
Write-Host ("  page_size lido    : {0,-6}    (bytes 0x{1:X2} 0x{2:X2})" -f $claim,$bytes[0],$bytes[1])
if($claimedValid){ Write-Host "  -> page_size VALIDO" -ForegroundColor Green }
else { Write-Host "  -> page_size INVALIDO" -ForegroundColor Red }
Write-Host ("  ods version       : 0x{0:X4} (0x800B esperado p/ FB 2.5)" -f $ods)

# Scan
$real = Find-RealPageSize $Database
if($real){ Write-Host ("  page_size REAL    : {0}  (detectado por varredura da pagina 1)" -f $real) -ForegroundColor Yellow }
else     { Write-Host  "  page_size REAL    : NAO DETECTADO por varredura" -ForegroundColor Yellow }

# gstat -h
Write-Host ""
Write-Host "--- gstat -h ---" -ForegroundColor DarkGray
$gout = & $GstatPath -h $Database 2>&1
$gexit = $LASTEXITCODE
$gtext = ($gout -join "`n")
Write-Host $gtext

# Diagnostico
Write-Host ""
$verdict = 0
if($claimedValid -and $gexit -eq 0 -and ($gtext -match 'Page size')){
  Write-Host ">> Header OK." -ForegroundColor Green
  $verdict = 0
}
elseif($real -and -not $claimedValid){
  $lo = $real -band 0xFF; $hi = ($real -shr 8) -band 0xFF
  Write-Host ">> page_size CORROMPIDO (caso classico)." -ForegroundColor Red
  Write-Host (">>   Correcao: gravar page_size={0} (bytes 0x{1:X2} 0x{2:X2}) no offset 0x10." -f $real,$lo,$hi) -ForegroundColor Yellow
  Write-Host  ">>   Use: Repair-FirebirdHeader.ps1 -Database `"$Database`""    -ForegroundColor Yellow
  $verdict = 1
}
elseif(-not $real){
  Write-Host ">> CORRUPCAO MAIOR: header ilegivel e scan tambem falhou."     -ForegroundColor Red
  Write-Host ">>   Considere restaurar de backup. Veja procedure 03 secao 5." -ForegroundColor Yellow
  $verdict = 2
}
elseif($gexit -ne 0){
  Write-Host ">> gstat falhou mesmo com page_size aparentemente valido."     -ForegroundColor Red
  Write-Host ">>   Inspecione ods version e flags (offsets 0x12 e 0x2A)."    -ForegroundColor Yellow
  $verdict = 2
}

exit $verdict
