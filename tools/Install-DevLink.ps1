<#
.SYNOPSIS
  Liga a skill instalada em ~/.claude/skills ao repositorio (junction), para nao
  precisar mais copiar a pasta a cada mudanca.

.DESCRIPTION
  Cria ~/.claude/skills/firebird-recovery como JUNCTION para skills/firebird-recovery
  deste repositorio. Junction nao exige Administrador. O Claude Code passa a ler a skill
  direto do working tree (edicoes valem na hora).

  Se ja existir uma pasta comum no destino, ela e MOVIDA (nunca apagada) para
  ~/.claude/skills-backup/firebird-recovery-<data>, fora da pasta de skills (senao o
  Claude Code carregaria as duas).

  Atencao: se voce tambem instalar a skill como plugin (/plugin install), as duas
  versoes carregam. Use uma ou outra.

  -WhatIf mostra o que faria.

.EXAMPLE
  .\tools\Install-DevLink.ps1
  .\tools\Install-DevLink.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$SkillsRoot = (Join-Path $HOME '.claude\skills')
)
$ErrorActionPreference = 'Stop'
$source = (Resolve-Path -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'skills\firebird-recovery')).Path
$target = Join-Path $SkillsRoot 'firebird-recovery'

if(Test-Path -LiteralPath $target){
  $item = Get-Item -LiteralPath $target -Force
  $isLink = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
  if($isLink){
    $current = @($item.Target)[0]
    if($current -and ((Resolve-Path -LiteralPath $current).Path -eq $source)){
      Write-Host "Ja esta ligado: $target -> $source" -ForegroundColor Green
      exit 0
    }
    if($PSCmdlet.ShouldProcess($target, "remover link antigo (-> $current)")){
      # remove so o link; [IO.Directory]::Delete de um reparse point nao apaga o conteudo do destino
      [IO.Directory]::Delete($target)
    } else { exit 0 }
  } else {
    $bkRoot = Join-Path (Split-Path $SkillsRoot -Parent) 'skills-backup'
    $bk = Join-Path $bkRoot ('firebird-recovery-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    if($PSCmdlet.ShouldProcess($target, "mover a copia atual para $bk")){
      New-Item -ItemType Directory -Force -Path $bkRoot | Out-Null
      Move-Item -LiteralPath $target -Destination $bk
      Write-Host "Copia anterior guardada em: $bk" -ForegroundColor DarkGray
    } else { exit 0 }
  }
}

if($PSCmdlet.ShouldProcess($target, "criar junction -> $source")){
  New-Item -ItemType Directory -Force -Path $SkillsRoot | Out-Null
  New-Item -ItemType Junction -Path $target -Target $source | Out-Null
  Write-Host "Ligado: $target -> $source" -ForegroundColor Green
}
exit 0
