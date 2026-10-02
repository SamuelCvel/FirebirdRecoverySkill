<#
.SYNOPSIS
  Funcoes compartilhadas pelos scripts da skill firebird-recovery.

.DESCRIPTION
  Carregue no inicio de cada script com:
      . (Join-Path $PSScriptRoot '_FirebirdCommon.ps1')

  Compativel com Windows PowerShell 5.1 e PowerShell 7.

  Por que existe:
  - No Windows PowerShell 5.1, com $ErrorActionPreference = 'Stop', qualquer linha que um
    .exe (gstat, gfix, gbak, isql) escreve no stderr vira erro TERMINANTE - o script morria
    exatamente quando a ferramenta reportava o problema. Invoke-FbNative isola isso.
  - Credenciais vao para o processo filho por ISC_USER/ISC_PASSWORD, so durante a chamada:
    a senha nao aparece na linha de comando nem na lista de processos.
#>

$script:FbValidPageSizes   = 1024, 2048, 4096, 8192, 16384
$script:FbMaxTransaction25 = 2147483647

function Exit-FbError {
  <# Mostra o erro e encerra o script com o codigo pedido. Write-Error puro, com
     $ErrorActionPreference = 'Stop', encerraria SEMPRE com exit 1 (antes do 'exit N'). #>
  param([Parameter(Mandatory = $true)][string]$Message, [int]$Code = 1)
  Write-Error -Message $Message -ErrorAction Continue
  exit $Code
}

function Invoke-FbNative {
  <#
    Roda um executavel e devolve Exit, Lines e Text. Nunca lanca excecao por causa de stderr.
    -User/-Password: passados ao processo filho por ISC_USER/ISC_PASSWORD (gbak, gfix, isql,
    nbackup e fbsvcmgr usam essas variaveis quando a linha de comando nao traz usuario/senha).
    Os valores anteriores do ambiente sao restaurados em seguida.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string[]]$Arguments = @(),
    [string]$User,
    [string]$Password
  )
  $prevUser = $env:ISC_USER
  $prevPwd  = $env:ISC_PASSWORD
  if($User){ $env:ISC_USER = $User }
  if($Password){ $env:ISC_PASSWORD = $Password }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $code = $null
  try {
    $lines = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prev
    $env:ISC_USER = $prevUser
    $env:ISC_PASSWORD = $prevPwd
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
    $a += @('-i', $tmp, $Database)
    Invoke-FbNative -Exe $IsqlPath -Arguments $a -User $User -Password $Password
  } finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-FbIsqlFile {
  <# Roda um arquivo .sql da skill (ex.: sql\contagem-objetos.sql) no banco. #>
  param(
    [Parameter(Mandatory = $true)][string]$IsqlPath,
    [Parameter(Mandatory = $true)][string]$Database,
    [Parameter(Mandatory = $true)][string]$SqlFile,
    [string]$User,
    [string]$Password
  )
  Invoke-FbNative -Exe $IsqlPath -Arguments @('-q', '-i', $SqlFile, $Database) -User $User -Password $Password
}

function Get-FbBinDir {
  <# Pasta bin do Firebird: variavel FIREBIRD, registro (instancia DefaultInstance), caminhos padrao. #>
  $cands = New-Object System.Collections.Generic.List[string]
  if($env:FIREBIRD){ $cands.Add((Join-Path $env:FIREBIRD 'bin')); $cands.Add($env:FIREBIRD) }
  foreach($k in 'HKLM:\SOFTWARE\Firebird Project\Firebird Server\Instances',
                'HKLM:\SOFTWARE\WOW6432Node\Firebird Project\Firebird Server\Instances'){
    try {
      $v = (Get-ItemProperty -Path $k -ErrorAction Stop).DefaultInstance
      if($v){ $cands.Add((Join-Path $v 'bin')) }
    } catch { }
  }
  $cands.Add('C:\Program Files\Firebird\Firebird_2_5\bin')
  $cands.Add('C:\Program Files (x86)\Firebird\Firebird_2_5\bin')
  foreach($c in $cands){ if($c -and (Test-Path -LiteralPath (Join-Path $c 'gbak.exe'))){ return $c } }
  return $null
}

function Resolve-FbToolPath {
  <# Usa o caminho informado se existir; senao procura a ferramenta na instalacao do Firebird. #>
  param([Parameter(Mandatory = $true)][string]$Name, [string]$Given)
  if($Given -and (Test-Path -LiteralPath $Given)){ return $Given }
  $bin = Get-FbBinDir
  if($bin){
    $p = Join-Path $bin "$Name.exe"
    if(Test-Path -LiteralPath $p){ return $p }
  }
  return $Given
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

function Test-FbExclusiveOpen {
  <# $true se o arquivo abre em modo exclusivo (ninguem mais o segura). #>
  param([Parameter(Mandatory = $true)][string]$Path)
  try {
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $fs.Dispose()
    return $true
  } catch { return $false }
}

function Get-FbHeaderInfo {
  <# Roda 'gstat -h' (le o arquivo direto, sem conectar) e devolve os campos em um objeto. #>
  param([Parameter(Mandatory = $true)][string]$GstatPath, [Parameter(Mandatory = $true)][string]$Database)
  $r = Invoke-FbNative -Exe $GstatPath -Arguments @('-h', $Database)
  return ConvertFrom-FbGstatHeader -Text $r.Text -Exit $r.Exit
}

function ConvertFrom-FbGstatHeader {
  <# Converte o texto do 'gstat -h' em objeto (separado do Get-FbHeaderInfo para poder ser testado). #>
  param([string]$Text, $Exit = 0)
  $t = $Text
  $r = [pscustomobject]@{ Exit = $Exit }
  $num = {
    param([string]$label)
    $m = [regex]::Match($t, ('(?m)^\s*' + [regex]::Escape($label) + ':?\s+(\d+)'))
    if($m.Success){ [int64]$m.Groups[1].Value } else { $null }
  }
  $attr = ([regex]::Match($t, '(?m)^\s*Attributes[ \t]*(.*)$')).Groups[1].Value.Trim()
  $shut = 'none'
  if($attr -match 'full shutdown'){ $shut = 'full' }
  elseif($attr -match 'single-user maintenance'){ $shut = 'single' }
  elseif($attr -match 'multi-user maintenance'){ $shut = 'multi' }
  [pscustomobject]@{
    Ok                = ($r.Exit -eq 0 -and $t -match 'Page size')
    Exit              = $r.Exit
    Text              = $t
    PageSize          = & $num 'Page size'
    OdsVersion        = ([regex]::Match($t, '(?m)^\s*ODS version\s+([\d.]+)')).Groups[1].Value
    OldestTransaction = & $num 'Oldest transaction'
    OldestActive      = & $num 'Oldest active'
    OldestSnapshot    = & $num 'Oldest snapshot'
    NextTransaction   = & $num 'Next transaction'
    Dialect           = & $num 'Database dialect'
    SweepInterval     = & $num 'Sweep interval'
    PageBuffers       = & $num 'Page buffers'
    Attributes        = $attr
    ForcedWrites      = ($attr -match 'force write')
    Shutdown          = $shut
    ReadOnly          = ($attr -match 'read only')
    BackupLock        = ($attr -match 'backup lock|backup merge')
  }
}

function Get-FbHeaderHints {
  <# Dicas de saude a partir do Get-FbHeaderInfo. Nivel: FALHA, ATENCAO ou INFO. #>
  param([Parameter(Mandatory = $true)]$Info)
  $out = New-Object System.Collections.Generic.List[object]
  if(-not $Info.Ok){ return $out }
  $add = { param($n, $t) $out.Add([pscustomobject]@{ Nivel = $n; Texto = $t }) }
  if(-not $Info.ForcedWrites){ & $add 'ATENCAO' 'forced writes DESLIGADO - principal causa de corrupcao apos queda de energia no Windows (gfix -write sync)' }
  if($Info.Shutdown -ne 'none'){ & $add 'FALHA' ("banco em shutdown ({0}) - so volta com 'gfix -online'" -f $Info.Shutdown) }
  if($Info.ReadOnly){ & $add 'ATENCAO' 'banco em modo read-only (gfix -mode read_write)' }
  if($Info.BackupLock){ & $add 'FALHA' "estado do nbackup ativo (backup lock): falta 'nbackup -N' no banco, ou 'nbackup -F' se isto for uma copia" }
  if($Info.NextTransaction){
    $pct = 100.0 * $Info.NextTransaction / $script:FbMaxTransaction25
    if($pct -ge 80){ & $add 'FALHA' ("contador de transacoes em {0:N1}% do limite do FB 2.5 (2.147.483.647) - planeje backup+restore ja" -f $pct) }
    elseif($pct -ge 50){ & $add 'ATENCAO' ("contador de transacoes em {0:N1}% do limite do FB 2.5 - backup+restore zera o contador" -f $pct) }
  }
  if($Info.NextTransaction -and $null -ne $Info.OldestTransaction){
    $gap = $Info.NextTransaction - $Info.OldestTransaction
    $ref = if($Info.SweepInterval){ $Info.SweepInterval } else { 20000 }
    if($gap -gt 100000 -and $gap -gt 5 * $ref){
      & $add 'ATENCAO' ("Next - OIT = {0:N0} transacoes (sweep {1}): transacao travada ou sweep sem avancar - afeta desempenho, nao e corrupcao" -f $gap, $(if($Info.SweepInterval){$Info.SweepInterval}else{'padrao'}))
    }
  }
  return $out
}

function Get-FbServerVersion {
  <# Versao do SERVIDOR via Services API (tambem valida usuario/senha). Devolve [version] ou $null. #>
  param([Parameter(Mandatory = $true)][string]$FbsvcmgrPath, [string]$User, [string]$Password)
  $r = Invoke-FbNative -Exe $FbsvcmgrPath -Arguments @('service_mgr', 'info_server_version') -User $User -Password $Password
  $m = [regex]::Match($r.Text, 'V(\d+)\.(\d+)\.(\d+)\.(\d+)')
  if($m.Success){ return [version]('{0}.{1}.{2}.{3}' -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value, $m.Groups[4].Value) }
  return $null
}

function Test-FbCorruptionError {
  <#
    $true se a mensagem indica DANO FISICO (pagina com tipo errado, checksum, falha de leitura,
    consistency check) - o unico tipo de erro que justifica encolher janela ou pular registros.
    Erro de SQL, login, permissao, constraint ou arquivo inexistente NAO conta: quem chama deve parar.
  #>
  param([string]$Text)
  return ($Text -match '(?i)appears corrupt|wrong page type|is of wrong type|checksum error|consistency check|bugcheck|wrong record length|I/O error during "?(ReadFile|read)|Error while trying to read')
}

function Get-FbErrorSummary {
  <#
    Resume a saida de erro do isql nas linhas que explicam o problema: o que vem depois de
    'Statement failed', sem o eco do comando (EDS), o caminho do .sql temporario e a posicao no bloco.
    Ex.: 'database file appears corrupt () | bad checksum | checksum error on database page 750'
  #>
  param([string[]]$Lines, [int]$Max = 3)
  $all = @($Lines | Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim() })
  $i = -1
  for($k = 0; $k -lt $all.Count; $k++){ if($all[$k] -match '^Statement failed'){ $i = $k; break } }
  $cand = if($i -ge 0 -and $i + 1 -lt $all.Count){ $all[($i + 1)..($all.Count - 1)] } else { $all }
  $ruido = '^(After line \d+ in file|-?At (block )?line|-?Data source :|-?Statement :|Execute statement error at|Use CONNECT or CREATE DATABASE)'
  $msg = @($cand | Where-Object { $_ -notmatch $ruido } | ForEach-Object { ($_.TrimStart('-').Trim()) -replace '^\d{9} : ', '' } | Select-Object -First $Max)
  if($msg.Count -eq 0){ $msg = @($all | Select-Object -Last $Max) }
  return ($msg -join ' | ')
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
