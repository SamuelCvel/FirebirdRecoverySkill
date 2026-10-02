<#
.SYNOPSIS
  Diagnostico SOMENTE LEITURA do cabecalho de um banco Firebird 2.5.
  Nao altera o arquivo. Pode rodar com o servidor no ar e o banco em uso.

.DESCRIPTION
  Le os primeiros bytes do header (pagina 0), reporta o page_size declarado,
  verifica se e valido, e faz uma varredura para descobrir o page_size REAL
  (procurando a pagina 1, PIP, ou a 2, TIP, com checksum 12345 = 0x3039 nos
  offsets candidatos). Confere tambem se o tamanho do arquivo e multiplo do
  page_size (senao o arquivo esta truncado). Em seguida roda 'gstat -h'.

  Resultados possiveis (impressos e refletidos no exit code):
    0  Header OK; sem corrupcao detectada na fase leitura.
    1  page_size declarado INVALIDO mas REAL detectado (caso classico).
    2  Header ilegivel e scan tambem falhou; corrupcao maior.
    3  Erro de execucao (gstat ausente, arquivo nao encontrado).
    4  Header OK, mas o tamanho do arquivo nao e multiplo do page_size (arquivo truncado).

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
. (Join-Path $PSScriptRoot '_FirebirdCommon.ps1')
$GstatPath = Resolve-FbToolPath 'gstat' $GstatPath

if(-not (Test-Path -LiteralPath $Database)){ Exit-FbError "Banco nao encontrado: $Database" 3 }
if(-not (Test-Path -LiteralPath $GstatPath)){ Exit-FbError "gstat.exe nao encontrado em: $GstatPath" 3 }

Write-Host ("==== Diagnostico de header  |  {0} ====" -f $Database) -ForegroundColor Cyan

# Leitura local
$h = Read-FbBytes -Path $Database -Offset 0 -Count 64
$pagType0  = $h[0]
$checksum0 = [BitConverter]::ToUInt16($h, 2)
$claim     = [BitConverter]::ToUInt16($h, 16)
$ods       = [BitConverter]::ToUInt16($h, 18)
$sequence  = [BitConverter]::ToUInt16($h, 40)
$flags     = [BitConverter]::ToUInt16($h, 42)
$claimedValid = $script:FbValidPageSizes -contains [int]$claim
$fileLen = (Get-Item -LiteralPath $Database).Length

Write-Host ""
Write-Host "Leitura do header (pagina 0):" -ForegroundColor White
Write-Host ("  pag_type pagina 0 : 0x{0:X2}  (esperado 0x01 = header)" -f $pagType0)
Write-Host ("  checksum          : {0}      (esperado 12345 no ODS 11)" -f $checksum0)
Write-Host ("  page_size lido    : {0,-6}    (bytes 0x{1:X2} 0x{2:X2})" -f $claim,$h[16],$h[17])
if($claimedValid){ Write-Host "  -> page_size VALIDO" -ForegroundColor Green }
else { Write-Host "  -> page_size INVALIDO" -ForegroundColor Red }
Write-Host ("  ods version       : 0x{0:X4} (0x800B esperado p/ FB 2.5)" -f $ods)
Write-Host ("  sequence          : {0}      (tem que ser 0)" -f $sequence)
Write-Host ("  hdr_flags         : 0x{0:X4} (tipico 0x0102 = forced writes + dialect 3)" -f $flags)
Write-Host ("  tamanho do arquivo: {0:N0} bytes" -f $fileLen)

if($ods -eq 0x800C -or $ods -eq 0x800D){
  Write-Host "  >> Banco de Firebird 3.0+ (ODS 12/13). Esta skill e para ODS 11 (FB 2.x); o scan por checksum nao se aplica." -ForegroundColor Yellow
}

# Scan
$real = Find-FbRealPageSize -Path $Database
if($real){ Write-Host ("  page_size REAL    : {0}  (detectado por varredura das paginas 1/2)" -f $real) -ForegroundColor Yellow }
else     { Write-Host  "  page_size REAL    : NAO DETECTADO por varredura" -ForegroundColor Yellow }

$ps = if($claimedValid){ [int]$claim } elseif($real){ $real } else { 0 }
$truncated = ($ps -gt 0 -and ($fileLen % $ps) -ne 0)
if($truncated){
  Write-Host ("  >> Tamanho NAO e multiplo do page_size ({0} bytes sobrando): arquivo TRUNCADO (copia interrompida, disco cheio)." -f ($fileLen % $ps)) -ForegroundColor Red
}

# gstat -h
Write-Host ""
Write-Host "--- gstat -h ---" -ForegroundColor DarkGray
$g = Get-FbHeaderInfo -GstatPath $GstatPath -Database $Database
Write-Host $g.Text

# Dicas de saude (so quando o gstat leu o header)
$hints = @(Get-FbHeaderHints -Info $g)
if($hints.Count -gt 0){
  Write-Host ""
  Write-Host "Dicas de saude:" -ForegroundColor White
  foreach($h in $hints){
    $cor = switch($h.Nivel){ 'FALHA' { 'Red' } 'ATENCAO' { 'Yellow' } default { 'Gray' } }
    Write-Host ("  [{0}] {1}" -f $h.Nivel, $h.Texto) -ForegroundColor $cor
  }
}

# Diagnostico
Write-Host ""
$verdict = 0
if($claimedValid -and $g.Ok){
  if($truncated){
    Write-Host ">> Header OK, mas o arquivo esta TRUNCADO: o fim do banco vai dar I/O error/EOF. Veja procedure 04." -ForegroundColor Red
    $verdict = 4
  } else {
    Write-Host ">> Header OK." -ForegroundColor Green
    $verdict = 0
  }
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
else {
  Write-Host ">> gstat falhou mesmo com page_size aparentemente valido."     -ForegroundColor Red
  Write-Host ">>   Inspecione ODS (0x12), sequence (0x28) e flags (0x2A) - procedure 03 secao 5." -ForegroundColor Yellow
  $verdict = 2
}

exit $verdict
