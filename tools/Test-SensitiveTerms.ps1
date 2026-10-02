<#
.SYNOPSIS
  Procura termos sensiveis (nomes de clientes, sistemas, tabelas reais, caminhos pessoais)
  nos arquivos do repositorio - inclusive DENTRO de pacotes .skill/.zip.

.DESCRIPTION
  Duas fontes de padroes (expressoes regulares .NET, uma por linha):
    1) Lista LOCAL em .git/info/sensitive-terms.txt - nunca vai para o commit, entao pode
       conter os nomes reais que nao podem vazar. Linhas vazias e iniciadas com # sao ignoradas.
    2) Padroes genericos embutidos (caminho de perfil do Windows, e-mail), que valem tambem
       no CI, onde a lista local nao existe. Desligue com -NoGeneric.

  Modos:
    (padrao)  varre os arquivos versionados e os novos nao ignorados (git ls-files -co --exclude-standard).
    -Staged   varre so o que esta no stage (uso no hook pre-commit).

  Exit codes: 0 limpo; 1 achou termo sensivel; 2 erro de execucao.

.EXAMPLE
  .\tools\Test-SensitiveTerms.ps1
  .\tools\Test-SensitiveTerms.ps1 -Staged
#>
[CmdletBinding()]
param(
  [string]$Root,
  [string]$TermsFile,
  [switch]$Staged,
  [switch]$NoGeneric
)
$ErrorActionPreference = 'Stop'

if(-not $Root){ $Root = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>$null) }
if(-not $Root -or -not (Test-Path -LiteralPath $Root)){ Write-Host "Nao achei a raiz do repositorio." -ForegroundColor Red; exit 2 }
$Root = (Resolve-Path -LiteralPath $Root).Path
if(-not $TermsFile){ $TermsFile = Join-Path $Root '.git\info\sensitive-terms.txt' }

$patterns = New-Object System.Collections.Generic.List[object]
if(Test-Path -LiteralPath $TermsFile){
  foreach($l in Get-Content -LiteralPath $TermsFile){
    $s = $l.Trim()
    if($s -and -not $s.StartsWith('#')){ $patterns.Add([pscustomobject]@{ Fonte = 'lista local'; Rx = [regex]$s }) }
  }
} else {
  Write-Host ("(sem lista local em {0} - so os padroes genericos)" -f $TermsFile) -ForegroundColor DarkGray
}
if(-not $NoGeneric){
  # caminho real de perfil do Windows (C:\Users\fulano), mas nao placeholders como C:\Users\<usuario>
  $patterns.Add([pscustomobject]@{ Fonte = 'generico'; Rx = [regex]'(?i)\b[A-Z]:\\Users\\(?![<$%{])[A-Za-z0-9._-]+' })
  # e-mail (exceto enderecos de exemplo/atribuicao)
  $patterns.Add([pscustomobject]@{ Fonte = 'generico'; Rx = [regex]'(?i)\b[A-Z0-9._%+-]+@(?!example\.(com|org)\b|anthropic\.com\b)[A-Z0-9.-]+\.[A-Z]{2,}\b' })
}
if($patterns.Count -eq 0){ Write-Host "Nenhum padrao para procurar." -ForegroundColor Yellow; exit 0 }

$selfRel = 'tools/Test-SensitiveTerms.ps1'
if($Staged){
  $files = @(& git -C $Root diff --cached --name-only --diff-filter=ACMR)
} else {
  $files = @(& git -C $Root ls-files -co --exclude-standard)
}
$files = $files | Where-Object { $_ -and $_ -ne $selfRel }

$hits = New-Object System.Collections.Generic.List[string]
function Test-Text([string]$label, [string]$text){
  $n = 0
  foreach($line in ($text -split "`r?`n")){
    $n++
    foreach($p in $patterns){
      foreach($m in $p.Rx.Matches($line)){
        $hits.Add(("{0}:{1}: [{2}] {3}" -f $label, $n, $p.Fonte, $m.Value))
      }
    }
  }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipExt = '.skill', '.zip'
$binExt = '.png', '.jpg', '.jpeg', '.gif', '.ico', '.pdf', '.fdb', '.gdb', '.fbk', '.exe', '.dll'
foreach($rel in $files){
  $full = Join-Path $Root $rel
  if(-not (Test-Path -LiteralPath $full)){ continue }
  $ext = [IO.Path]::GetExtension($rel).ToLowerInvariant()
  if($zipExt -contains $ext){
    try {
      $zip = [IO.Compression.ZipFile]::OpenRead($full)
      try {
        foreach($e in $zip.Entries){
          if($e.Length -eq 0){ continue }
          $sr = New-Object IO.StreamReader($e.Open())
          try { Test-Text ("{0}!{1}" -f $rel, $e.FullName) $sr.ReadToEnd() } finally { $sr.Dispose() }
        }
      } finally { $zip.Dispose() }
    } catch { $hits.Add(("{0}: nao consegui abrir como zip ({1})" -f $rel, $_.Exception.Message)) }
  } elseif($binExt -notcontains $ext){
    $text = if($Staged){ (& git -C $Root show (":" + $rel)) -join "`n" } else { [IO.File]::ReadAllText($full) }
    Test-Text $rel $text
  }
}

if($hits.Count -gt 0){
  Write-Host ("TERMOS SENSIVEIS ENCONTRADOS ({0}):" -f $hits.Count) -ForegroundColor Red
  $hits | ForEach-Object { Write-Host ("  " + $_) -ForegroundColor Red }
  Write-Host "Troque por nomes genericos antes de commitar." -ForegroundColor Yellow
  exit 1
}
Write-Host ("OK: {0} arquivo(s) verificados, nenhum termo sensivel." -f @($files).Count) -ForegroundColor Green
exit 0
