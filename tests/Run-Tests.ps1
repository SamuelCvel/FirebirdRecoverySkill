<#
.SYNOPSIS
  Roda os testes da skill.

.DESCRIPTION
  Unit.Tests.ps1         sempre (nao precisa do Firebird; e o que roda no CI).
  Integration.Tests.ps1  com -Integration: precisa do Firebird 2.5 instalado (usa o banco de exemplo
                         EMPLOYEE.FDB e cria copias descartaveis numa pasta temporaria; nunca toca em
                         banco de cliente).
  -KeepFixtures          mantem a pasta temporaria com os bancos de teste (para investigar falha).
  Exit code: 0 tudo passou; 1 alguma falha.

.EXAMPLE
  .\tests\Run-Tests.ps1
  .\tests\Run-Tests.ps1 -Integration
  powershell.exe -File .\tests\Run-Tests.ps1 -Integration     # Windows PowerShell 5.1
#>
[CmdletBinding()]
param([switch]$Integration, [switch]$KeepFixtures)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_TestKit.ps1')
$script:TestShell = if($PSVersionTable.PSEdition -eq 'Core'){ 'pwsh' } else { 'powershell.exe' }
$script:KeepFixtures = [bool]$KeepFixtures
Write-Host ("Testes - PowerShell {0} ({1})" -f $PSVersionTable.PSVersion, $script:TestShell) -ForegroundColor Cyan
. (Join-Path $PSScriptRoot 'Unit.Tests.ps1')
if($Integration){ . (Join-Path $PSScriptRoot 'Integration.Tests.ps1') }
$falhas = Write-TestSummary
if($falhas -gt 0){ exit 1 } else { exit 0 }
