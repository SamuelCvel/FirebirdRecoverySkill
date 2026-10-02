<#
.SYNOPSIS
  Funcoes compartilhadas pelos scripts da skill firebird-recovery.

.DESCRIPTION
  Carregue no inicio de cada script com:
      . (Join-Path $PSScriptRoot '_FirebirdCommon.ps1')

  Compativel com Windows PowerShell 5.1 e PowerShell 7.

  Por que existe: no Windows PowerShell 5.1, com $ErrorActionPreference = 'Stop',
  qualquer linha que um .exe (gstat, gfix, gbak, isql) escreve no stderr vira um erro
  TERMINANTE (NativeCommandError) - o script morre exatamente quando a ferramenta
  reporta o problema que ele deveria diagnosticar. Invoke-FbNative isola isso.
#>

$script:FbValidPageSizes = 1024, 2048, 4096, 8192, 16384

function Exit-FbError {
  <# Mostra o erro e encerra o script com o codigo pedido. Write-Error puro, com
     $ErrorActionPreference = 'Stop', encerraria SEMPRE com exit 1 (antes do 'exit N'). #>
  param([Parameter(Mandatory = $true)][string]$Message, [int]$Code = 1)
  Write-Error -Message $Message -ErrorAction Continue
  exit $Code
}

function Invoke-FbNative {
  <# Roda um executavel e devolve Exit, Lines e Text. Nunca lanca excecao por causa de stderr. #>
  param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string[]]$Arguments = @()
  )
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $code = $null
  try {
    $lines = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prev
  }
  [pscustomobject]@{ Exit = $code; Lines = $lines; Text = ($lines -join [Environment]::NewLine) }
}

function Invoke-FbIsql {
  <# Roda SQL no isql por arquivo temporario (-i). Assim o -b (bail) funciona e nao ha stdin. #>
  param(
    [Parameter(Mandatory = $true)][string]$IsqlPath,
    [Parameter(Mandatory = $true)][string]$Database,
    [Parameter(Mandatory = $true)][string]$Sql,
    [string]$User,
    [string]$Password,
    [switch]$Bail
  )
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('fbrec-' + [guid]::NewGuid().ToString('N') + '.sql')
  [IO.File]::WriteAllText($tmp, $Sql, (New-Object Text.UTF8Encoding($false)))
  try {
    $a = @('-q')
    if($Bail){ $a += '-b' }
    if($User){ $a += @('-user', $User) }
    if($Password){ $a += @('-password', $Password) }
    $a += @('-i', $tmp, $Database)
    Invoke-FbNative -Exe $IsqlPath -Arguments $a
  } finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
}

function Read-FbBytes {
  <# Le bytes do arquivo sem bloquear o servidor (FileShare.ReadWrite). #>
  param([string]$Path, [long]$Offset, [int]$Count)
  $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  try {
    [void]$fs.Seek($Offset, 'Begin')
    $b = New-Object byte[] $Count
    $n = $fs.Read($b, 0, $Count)
    if($n -lt $Count){ $b = $b[0..([Math]::Max(0, $n - 1))] }
    return ,$b
  } finally { $fs.Dispose() }
}

function Find-FbRealPageSize {
  <#
    Descobre o page_size real de um banco ODS 11 (Firebird 2.x) sem confiar no header.
    Toda pagina ODS 11 tem o checksum constante 12345 (0x3039) no offset 2. A pagina 1 e
    sempre a PIP (pag_type 2) e a pagina 2 normalmente a TIP (pag_type 3). O primeiro
    candidato em que uma delas aparece no lugar certo e o page_size real. Devolve 0 se nada casa
    (corrupcao maior, arquivo nao-Firebird, ou banco ODS 12+ que nao tem mais o checksum).
  #>
  param([string]$Path)
  $len = (Get-Item -LiteralPath $Path).Length
  foreach($sz in $script:FbValidPageSizes){
    foreach($probe in @(@{ Page = 1; Type = 2 }, @{ Page = 2; Type = 3 })){
      $off = [long]$sz * $probe.Page
      if($off + 4 -gt $len){ continue }
      $b = Read-FbBytes -Path $Path -Offset $off -Count 4
      if($b.Length -ge 4 -and $b[0] -eq $probe.Type -and $b[2] -eq 0x39 -and $b[3] -eq 0x30){ return [int]$sz }
    }
  }
  return 0
}

function Test-FbAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Get-FbServices {
  <# Servicos do Firebird pelo executavel (o nome da instancia pode variar). #>
  Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
    Where-Object { $_.PathName -match '(?i)\\(fbguard|fbserver|fb_inet_server|fb_smp_server|firebird)\.exe' } |
    Select-Object Name, State, StartMode, PathName
}
