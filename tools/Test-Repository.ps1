<#
.SYNOPSIS
  Verificacoes de consistencia do repositorio (roda igual local e no CI).

.DESCRIPTION
  - JSON valido: .claude-plugin/plugin.json, .claude-plugin/marketplace.json, evals/evals.json.
  - Nomes coerentes: plugin.json, entrada do marketplace, pasta da skill e 'name' do SKILL.md.
  - Versao: so no plugin.json (nao na entrada do marketplace); igual ao metadata.version do SKILL.md;
    com secao no CHANGELOG; igual a tag quando roda num build de tag (GITHUB_REF_NAME = vX.Y.Z).
  - Sintaxe de todos os .ps1 (parser do PowerShell).
  - Referencias nas docs: todo 'scripts/X.ps1', 'sql/X.sql', 'procedures/X.md', 'references/X.md' e
    'templates/X.md' citado nos .md da skill tem que existir.
  - Sumario: procedure/referencia com mais de 100 linhas tem secao de sumario, e os links dela
    apontam para titulos que existem.

  Exit codes: 0 ok; 1 alguma verificacao falhou.

.EXAMPLE
  .\tools\Test-Repository.ps1
#>
[CmdletBinding()]
param([string]$Root)
$ErrorActionPreference = 'Stop'
if(-not $Root){ $Root = Split-Path $PSScriptRoot -Parent }
$Root = (Resolve-Path -LiteralPath $Root).Path
$falhas = New-Object System.Collections.Generic.List[string]
function Falha([string]$m){ $falhas.Add($m); Write-Host "  FALHA: $m" -ForegroundColor Red }
function Ok([string]$m){ Write-Host "  ok: $m" -ForegroundColor Green }

# ---------------- JSON ----------------
$json = @{}
foreach($rel in '.claude-plugin/plugin.json', '.claude-plugin/marketplace.json', 'skills/firebird-recovery/evals/evals.json'){
  $p = Join-Path $Root $rel
  if(-not (Test-Path -LiteralPath $p)){ Falha "$rel nao existe"; continue }
  try { $json[$rel] = [IO.File]::ReadAllText($p) | ConvertFrom-Json; Ok "$rel e JSON valido" }
  catch { Falha "$rel nao e JSON valido: $($_.Exception.Message)" }
}

# ---------------- nomes e versao ----------------
$skillDir = Join-Path $Root 'skills/firebird-recovery'
$skillMd = [IO.File]::ReadAllText((Join-Path $skillDir 'SKILL.md'))
$fm = [regex]::Match($skillMd, '(?s)\A---\r?\n(.*?)\r?\n---').Groups[1].Value
$skillName = [regex]::Match($fm, '(?m)^name:\s*(\S+)').Groups[1].Value
$skillVer  = [regex]::Match($fm, '(?m)^\s+version:\s*"?([0-9][^"\s]*)"?').Groups[1].Value
$plugin = $json['.claude-plugin/plugin.json']
$market = $json['.claude-plugin/marketplace.json']
if($plugin -and $market){
  $entry = @($market.plugins)[0]
  $nomes = @($plugin.name, $entry.name, (Split-Path $skillDir -Leaf), $skillName)
  if(@($nomes | Sort-Object -Unique).Count -eq 1){ Ok "nome coerente: $($plugin.name)" } else { Falha ("nomes divergentes: plugin.json={0} marketplace={1} pasta={2} SKILL.md={3}" -f $nomes) }
  if($entry.PSObject.Properties.Name -contains 'version'){ Falha 'a entrada do marketplace nao deve ter version (fica so no plugin.json)' }
  if(-not $plugin.version){ Falha 'plugin.json sem version' }
  elseif($plugin.version -ne $skillVer){ Falha "versao divergente: plugin.json $($plugin.version) x SKILL.md metadata.version $skillVer" }
  else { Ok "versao $($plugin.version) (plugin.json = SKILL.md)" }
  $changelog = [IO.File]::ReadAllText((Join-Path $Root 'CHANGELOG.md'))
  if($plugin.version -and $changelog -notmatch ('(?m)^## \[' + [regex]::Escape($plugin.version) + '\]')){ Falha "CHANGELOG.md sem secao [$($plugin.version)]" }
  elseif($plugin.version){ Ok "CHANGELOG tem [$($plugin.version)]" }
  if($env:GITHUB_REF_NAME -match '^v(\d+\.\d+\.\d+.*)$'){
    if($Matches[1] -ne $plugin.version){ Falha "tag $($env:GITHUB_REF_NAME) diferente da versao $($plugin.version)" } else { Ok "tag $($env:GITHUB_REF_NAME) = versao" }
  }
}

# ---------------- sintaxe dos .ps1 ----------------
$ps1 = Get-ChildItem -LiteralPath $Root -Recurse -Filter *.ps1 -File | Where-Object { $_.FullName -notmatch '\\(\.git|node_modules)\\' }
$ruins = 0
foreach($f in $ps1){
  $tokens = $null; $errs = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
  if($errs -and $errs.Count -gt 0){ $ruins++; Falha ("{0}: {1} (linha {2})" -f $f.FullName.Substring($Root.Length + 1), $errs[0].Message, $errs[0].Extent.StartLineNumber) }
}
if($ruins -eq 0){ Ok "$($ps1.Count) arquivo(s) .ps1 sem erro de sintaxe" }

# ---------------- referencias nas docs ----------------
$md = @(Get-ChildItem -LiteralPath $skillDir -Recurse -Filter *.md -File) + @(Get-Item -LiteralPath (Join-Path $Root 'README.md'))
$faltando = 0
foreach($f in $md){
  $txt = [IO.File]::ReadAllText($f.FullName)
  # pega 'scripts/X.ps1', '<SKILL>\scripts\X.ps1', '${CLAUDE_SKILL_DIR}/sql/X.sql' etc.
  foreach($m in [regex]::Matches($txt, '(?<![\w.])(scripts|sql|procedures|references|templates)[\\/]([A-Za-z0-9_.-]+\.(?:ps1|sql|md))')){
    $alvo = Join-Path $skillDir ($m.Groups[1].Value + '/' + $m.Groups[2].Value)
    if(-not (Test-Path -LiteralPath $alvo)){
      $faltando++
      Falha ("{0} cita '{1}/{2}', que nao existe" -f $f.FullName.Substring($Root.Length + 1), $m.Groups[1].Value, $m.Groups[2].Value)
    }
  }
}
if($faltando -eq 0){ Ok "referencias a arquivos nas docs da skill: todas existem ($($md.Count) .md)" }

# ---------------- sumario nas docs longas ----------------
# Procedure/referencia com mais de 100 linhas precisa de '## Sumario' (o Claude ve o escopo ao abrir
# so o comeco do arquivo) e todo link do sumario tem que apontar para um titulo que existe.
$tituloSumario = "## Sum$([char]0xE1)rio"   # sem acento literal: o PS 5.1 le .ps1 sem BOM como ANSI
function Get-MdSlug([string]$h){ (($h.Trim().ToLowerInvariant()) -replace '[^\p{L}\p{N}_\- ]', '') -replace ' ', '-' }
$problemasSumario = 0
$longas = Get-ChildItem -LiteralPath $skillDir -Recurse -Filter *.md -File | Where-Object { $_.Name -ne 'SKILL.md' -and $_.DirectoryName -notmatch '[\\/](templates|evals)$' }
foreach($f in $longas){
  $linhas = [IO.File]::ReadAllLines($f.FullName)
  $rel = $f.FullName.Substring($Root.Length + 1)
  $slugs = New-Object 'System.Collections.Generic.HashSet[string]'
  $fence = $false
  foreach($l in $linhas){
    if($l.StartsWith('```')){ $fence = -not $fence; continue }
    if(-not $fence -and $l -match '^#{1,6} (.+)$'){ [void]$slugs.Add((Get-MdSlug $Matches[1])) }
  }
  $ini = [Array]::IndexOf($linhas, $tituloSumario)
  if($ini -lt 0){
    if($linhas.Count -gt 100){ $problemasSumario++; Falha ("{0} tem {1} linhas e nao tem '{2}'" -f $rel, $linhas.Count, $tituloSumario) }
    continue
  }
  for($i = $ini + 1; $i -lt $linhas.Count -and $linhas[$i] -notmatch '^## '; $i++){
    foreach($m in [regex]::Matches($linhas[$i], '\]\(#([^)]+)\)')){
      if(-not $slugs.Contains($m.Groups[1].Value)){ $problemasSumario++; Falha ("{0}: link do sumario '#{1}' nao corresponde a nenhum titulo" -f $rel, $m.Groups[1].Value) }
    }
  }
}
if($problemasSumario -eq 0){ Ok "sumario nas docs com mais de 100 linhas, links do sumario validos ($(@($longas).Count) .md)" }

Write-Host ""
if($falhas.Count -gt 0){ Write-Host ("{0} verificacao(oes) falharam." -f $falhas.Count) -ForegroundColor Red; exit 1 }
Write-Host "Repositorio consistente." -ForegroundColor Green
exit 0
