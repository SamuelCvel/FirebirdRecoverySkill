<#
  Kit minimo de testes (sem dependencia de modulo externo): roda igual no Windows PowerShell 5.1,
  no PowerShell 7 e no CI. Carregue com:  . (Join-Path $PSScriptRoot '_TestKit.ps1')
#>
$script:TestResults = New-Object System.Collections.Generic.List[object]

function Test-Case {
  param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][scriptblock]$Body)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    & $Body
    $sw.Stop()
    $script:TestResults.Add([pscustomobject]@{ Teste = $Name; OK = $true; Segundos = [Math]::Round($sw.Elapsed.TotalSeconds, 1); Erro = '' })
    Write-Host ("  [ok]    {0}" -f $Name) -ForegroundColor Green
  } catch {
    $sw.Stop()
    $script:TestResults.Add([pscustomobject]@{ Teste = $Name; OK = $false; Segundos = [Math]::Round($sw.Elapsed.TotalSeconds, 1); Erro = $_.Exception.Message })
    Write-Host ("  [FALHA] {0} - {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
  }
}

function Assert-Equal($Expected, $Actual, [string]$Message = '') {
  if($Expected -ne $Actual){ throw ("{0} esperado [{1}] obtido [{2}]" -f $Message, $Expected, $Actual) }
}
function Assert-True($Condition, [string]$Message = '') {
  if(-not $Condition){ throw ("condicao falsa: {0}" -f $Message) }
}
function Assert-Match([string]$Text, [string]$Pattern, [string]$Message = '') {
  if($Text -notmatch $Pattern){ throw ("{0} - padrao '{1}' nao encontrado" -f $Message, $Pattern) }
}

function Invoke-Script {
  <# Roda um script num processo separado (como o usuario rodaria) e devolve Exit e Text.
     -Shell: pwsh ou powershell.exe. Argumentos passam por -Command (arrays e -Confirm:$false funcionam). #>
  param([Parameter(Mandatory = $true)][string]$Path, [string[]]$Arguments = @(), [string]$Shell = $script:TestShell)
  if(-not $Shell){ $Shell = if($PSVersionTable.PSEdition -eq 'Core'){ 'pwsh' } else { 'powershell.exe' } }
  $argText = ($Arguments | ForEach-Object {
    if($_ -match '^-[A-Za-z]' -or $_ -match '^\$'){ $_ }
    elseif($_ -match "^'.*'(,'.*')*$"){ $_ }          # array ja citado: 'a','b'
    else { "'" + $_.Replace("'", "''") + "'" }
  }) -join ' '
  # 'exit N' do script chega como $LASTEXITCODE; erro antes de o script rodar (parametro
  # invalido, arquivo inexistente) deixa $? falso com $LASTEXITCODE 0 -> 99, para nao parecer sucesso.
  $cmd = "`$global:LASTEXITCODE = 0; & '$($Path.Replace("'", "''"))' $argText; if(-not `$? -and `$LASTEXITCODE -eq 0){ exit 99 }; exit `$LASTEXITCODE"
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $out = @(& $Shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $cmd 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $prev }
  [pscustomobject]@{ Exit = $code; Text = ($out -join "`n") }
}

function Assert-Run($Result, [int]$Exit, [string]$Pattern = '') {
  <# Confere exit code e (opcional) um padrao na saida; na falha mostra o fim da saida. #>
  $tail = (($Result.Text -split "`n") | Where-Object { $_ -match '\S' } | Select-Object -Last 6) -join ' | '
  if($Result.Exit -ne $Exit){ throw ("exit esperado {0}, obtido {1}: {2}" -f $Exit, $Result.Exit, $tail) }
  if($Pattern -and $Result.Text -notmatch $Pattern){ throw ("saida sem '{0}': {1}" -f $Pattern, $tail) }
}

function Write-TestSummary {
  $falhas = @($script:TestResults | Where-Object { -not $_.OK })
  Write-Host ""
  Write-Host ("{0} teste(s), {1} falha(s)" -f $script:TestResults.Count, $falhas.Count) -ForegroundColor $(if($falhas.Count){ 'Red' } else { 'Green' })
  foreach($f in $falhas){ Write-Host ("  - {0}: {1}" -f $f.Teste, $f.Erro) -ForegroundColor Red }
  return $falhas.Count
}
