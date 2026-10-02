<#
.SYNOPSIS
  Valida a skill e gera o pacote .skill (zip com a pasta da skill na raiz).

.DESCRIPTION
  Empacotador proprio, para rodar igual na maquina do desenvolvedor e no CI, sem
  depender do skill-creator. Aplica as mesmas regras de validacao da especificacao
  de Agent Skills (as mesmas que o upload do claude.ai aplica):
    - frontmatter YAML valido (testado com PyYAML quando o python estiver disponivel)
    - so as chaves name, description, license, compatibility, metadata, allowed-tools
    - name: [a-z0-9-], ate 64, sem hifen nas pontas nem '--', igual ao nome da pasta
    - description: obrigatoria, ate 1024 caracteres, sem '<' ou '>'
    - compatibility: ate 500 caracteres
  O zip leva a pasta da skill na raiz (firebird-recovery/...), com '/' nos caminhos,
  e deixa de fora evals/, __pycache__, *.pyc e .DS_Store (como o package_skill.py).

  Exit codes: 0 ok; 1 validacao falhou; 2 erro de execucao.

.EXAMPLE
  .\tools\Build-SkillPackage.ps1
  .\tools\Build-SkillPackage.ps1 -OutDir C:\temp\pacotes
#>
[CmdletBinding()]
param(
  [string]$SkillDir,
  [string]$OutDir
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if(-not $SkillDir){ $SkillDir = Join-Path $root 'skills\firebird-recovery' }
if(-not $OutDir){ $OutDir = Join-Path $root 'dist' }
$SkillDir = (Resolve-Path -LiteralPath $SkillDir).Path.TrimEnd('\','/')
$skillName = Split-Path $SkillDir -Leaf
$skillMd = Join-Path $SkillDir 'SKILL.md'
if(-not (Test-Path -LiteralPath $skillMd)){ Write-Host "SKILL.md nao encontrado em $SkillDir" -ForegroundColor Red; exit 2 }

# ---------------- validacao ----------------
$errors = New-Object System.Collections.Generic.List[string]
$text = [IO.File]::ReadAllText($skillMd)
$m = [regex]::Match($text, '(?s)\A---\r?\n(.*?)\r?\n---\r?\n')
if(-not $m.Success){ $errors.Add('SKILL.md nao comeca com frontmatter (--- ... ---).') }
else {
  $fm = $m.Groups[1].Value
  $allowed = 'name','description','license','compatibility','metadata','allowed-tools'
  $keys = [regex]::Matches($fm, '(?m)^([A-Za-z0-9_-]+):') | ForEach-Object { $_.Groups[1].Value }
  foreach($k in $keys){ if($allowed -notcontains $k){ $errors.Add("Chave nao permitida no frontmatter: '$k' (o upload no claude.ai recusa).") } }
  function Get-Scalar([string]$key){
    $x = [regex]::Match($fm, "(?m)^${key}:[ \t]*(.*)$")
    if($x.Success){ return $x.Groups[1].Value.Trim() } else { return $null }
  }
  $name = Get-Scalar 'name'
  $desc = Get-Scalar 'description'
  $comp = Get-Scalar 'compatibility'
  if(-not $name){ $errors.Add('Falta name.') }
  elseif($name -notmatch '^[a-z0-9-]{1,64}$' -or $name.StartsWith('-') -or $name.EndsWith('-') -or $name.Contains('--')){ $errors.Add("name invalido: '$name'.") }
  elseif($name -ne $skillName){ $errors.Add("name ('$name') diferente do nome da pasta ('$skillName').") }
  if(-not $desc){ $errors.Add('Falta description.') }
  else {
    $d = $desc.Trim('"', "'")
    if($d.Length -gt 1024){ $errors.Add("description com $($d.Length) caracteres (maximo 1024).") }
    if($d -match '[<>]'){ $errors.Add("description nao pode ter '<' ou '>'.") }
  }
  if($comp -and $comp.Trim('"', "'").Length -gt 500){ $errors.Add("compatibility com $($comp.Length) caracteres (maximo 500).") }

  # YAML de verdade: ': ' solto num valor quebra o parse (aconteceu na 1.1.1)
  $py = Get-Command python -ErrorAction SilentlyContinue
  if($py){
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('fm-' + [guid]::NewGuid().ToString('N') + '.yaml')
    [IO.File]::WriteAllText($tmp, $fm, (New-Object Text.UTF8Encoding($false)))
    try {
      $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      $out = & python -X utf8 -c "import sys,yaml; d=yaml.safe_load(open(sys.argv[1],encoding='utf-8')); assert isinstance(d,dict), 'frontmatter nao e um mapa'; print('ok')" $tmp 2>&1 | ForEach-Object { "$_" }
      $ErrorActionPreference = $prev
      if(($out -join ' ') -match "No module named 'yaml'"){ Write-Host "(PyYAML ausente: pulei o parse YAML - pip install pyyaml)" -ForegroundColor DarkYellow }
      elseif(($out -join ' ') -notmatch '\bok\b'){ $errors.Add("frontmatter nao e YAML valido: " + (($out | Select-Object -Last 2) -join ' ')) }
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  } else {
    # sem python: pelo menos o caso classico de ': ' num valor sem aspas
    foreach($k in 'description','compatibility'){
      $v = Get-Scalar $k
      if($v -and -not ($v.StartsWith('"') -or $v.StartsWith("'")) -and $v.Contains(': ')){ $errors.Add("$k tem ': ' sem aspas (YAML invalido).") }
    }
  }
}
if($errors.Count -gt 0){
  Write-Host "VALIDACAO FALHOU:" -ForegroundColor Red
  $errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  exit 1
}
Write-Host ("Skill valida: {0} (description {1} caracteres)" -f $skillName, $desc.Trim('"', "'").Length) -ForegroundColor Green

# ---------------- pacote ----------------
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$pkg = Join-Path $OutDir "$skillName.skill"
if(Test-Path -LiteralPath $pkg){ Remove-Item -LiteralPath $pkg -Force }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$fs = [IO.File]::Open($pkg, [IO.FileMode]::CreateNew)
$n = 0
try {
  $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
  try {
    Get-ChildItem -LiteralPath $SkillDir -Recurse -File | Sort-Object FullName | ForEach-Object {
      $rel = $_.FullName.Substring($SkillDir.Length + 1).Replace('\', '/')
      if($rel -match '^evals/' -or $rel -match '(^|/)__pycache__/' -or $rel -like '*.pyc' -or $_.Name -eq '.DS_Store'){ return }
      [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, "$skillName/$rel", [IO.Compression.CompressionLevel]::Optimal)
      $script:n++
    }
  } finally { $zip.Dispose() }
} finally { $fs.Dispose() }
Write-Host ("Pacote: {0} ({1} arquivos, {2:N0} bytes)" -f $pkg, $n, (Get-Item -LiteralPath $pkg).Length) -ForegroundColor Green
exit 0
