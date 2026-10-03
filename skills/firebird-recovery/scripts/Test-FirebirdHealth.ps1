<#
.SYNOPSIS
  Health check de um banco Firebird 2.5 nas 4 lentes, com relatorio .md e .json.

.DESCRIPTION
  Lente 0 - estado     : gstat -h (le o arquivo, nao conecta). Banco em shutdown/manutencao ou com
                         nbackup travado = FALHA (-BringOnline roda 'gfix -online' antes).
  Lente 1 - header     : page size, ODS, forced writes, contador de transacoes (% do limite do 2.5),
                         Next - OIT, arquivo truncado.
  Lente 2 - validacao  : -Validation online (fbsvcmgr action_validate, FB 2.5.4+, com usuarios
                         conectados) | full (gfix -v -full, exige acesso exclusivo) | none.
  Lente 3 - backup     : gbak -b -g SEM -ignore (o backup que a rotina faria). Se falhar, repete com
                         -ignore para dizer se os dados ainda saem. -SkipBackup pula.
  Lente 4 - isql       : objetos, indices nao ativos, registros por tabela (-1 = tabela ilegivel),
                         FKs orfas (o proximo restore quebraria). -ReferenceDatabase ou -ReferenceCounts
                         comparam as contagens (ex.: original x recuperado).

  -SnapshotCopy <arquivo>: para banco EM PRODUCAO. Faz 'nbackup -L' / copia / 'nbackup -N' no banco e
  'nbackup -F' na copia, e roda as lentes NA COPIA. Os usuarios seguem trabalhando.

  Somente leitura no banco analisado, exceto: -BringOnline (gfix -online) e o lock temporario do nbackup
  com -SnapshotCopy. A validacao 'full' libera paginas orfas (comportamento do gfix -v).

  Saida: tabela no console + <banco>.health-<data>.md e .json (em -OutDir; padrao: pasta do banco).
  Exit codes: 0 sem FALHA (pode ter ATENCAO); 1 parametro invalido; 2 alguma FALHA.

.EXAMPLE
  .\Test-FirebirdHealth.ps1 -Database C:\dados\BANCO.FDB
  .\Test-FirebirdHealth.ps1 -Database C:\dados\BANCO.FDB -SnapshotCopy D:\analise\BANCO-copia.FDB
  .\Test-FirebirdHealth.ps1 -Database C:\rec\RECUPERADO.FDB -Validation full -ReferenceDatabase C:\rec\ORIGINAL-copia.FDB
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Database,
  [ValidateSet('online','full','none')][string]$Validation = 'online',
  [switch]$SkipBackup,
  [switch]$KeepBackup,
  [switch]$BringOnline,
  [string]$SnapshotCopy,
  [string]$ReferenceDatabase,
  [string]$ReferenceCounts,
  [string]$OutDir,
  [string]$GstatPath    = 'C:\Program Files\Firebird\Firebird_2_5\bin\gstat.exe',
  [string]$GfixPath     = 'C:\Program Files\Firebird\Firebird_2_5\bin\gfix.exe',
  [string]$GbakPath     = 'C:\Program Files\Firebird\Firebird_2_5\bin\gbak.exe',
  [string]$IsqlPath     = 'C:\Program Files\Firebird\Firebird_2_5\bin\isql.exe',
  [string]$FbsvcmgrPath = 'C:\Program Files\Firebird\Firebird_2_5\bin\fbsvcmgr.exe',
  [string]$NbackupPath  = 'C:\Program Files\Firebird\Firebird_2_5\bin\nbackup.exe',
  [string]$User     = $(if($env:ISC_USER){ $env:ISC_USER } else { 'SYSDBA' }),
  [string]$Password = $(if($env:ISC_PASSWORD){ $env:ISC_PASSWORD } else { 'masterkey' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_FirebirdCommon.ps1')
$GstatPath    = Resolve-FbToolPath 'gstat'    $GstatPath
$GfixPath     = Resolve-FbToolPath 'gfix'     $GfixPath
$GbakPath     = Resolve-FbToolPath 'gbak'     $GbakPath
$IsqlPath     = Resolve-FbToolPath 'isql'     $IsqlPath
$FbsvcmgrPath = Resolve-FbToolPath 'fbsvcmgr' $FbsvcmgrPath
$NbackupPath  = Resolve-FbToolPath 'nbackup'  $NbackupPath

if(-not (Test-Path -LiteralPath $Database)){ Exit-FbError "Banco nao encontrado: $Database" 1 }
if($ReferenceDatabase -and -not (Test-Path -LiteralPath $ReferenceDatabase)){ Exit-FbError "Banco de referencia nao encontrado: $ReferenceDatabase" 1 }
if($ReferenceCounts -and -not (Test-Path -LiteralPath $ReferenceCounts)){ Exit-FbError "Arquivo de contagens nao encontrado: $ReferenceCounts" 1 }
$sqlDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'sql'
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$inicio = Get-Date

$checks  = New-Object System.Collections.Generic.List[object]
$details = [ordered]@{}
function Add-Check([string]$Lente, [string]$Item, [string]$Status, [string]$Detalhe){
  $checks.Add([pscustomobject]@{ Lente = $Lente; Item = $Item; Status = $Status; Detalhe = $Detalhe })
  $cor = switch($Status){ 'OK' { 'Green' } 'ATENCAO' { 'Yellow' } 'FALHA' { 'Red' } default { 'DarkGray' } }
  Write-Host ("  [{0,-7}] {1,-10} {2}: {3}" -f $Status, $Lente, $Item, $Detalhe) -ForegroundColor $cor
}

Write-Host ("==== Test-FirebirdHealth  |  {0}" -f $Database) -ForegroundColor Cyan

# ---------------- copia consistente de banco em uso (nbackup) ----------------
$target = $Database
if($SnapshotCopy){
  if(Test-Path -LiteralPath $SnapshotCopy){ Exit-FbError "A copia ja existe: $SnapshotCopy (escolha outro nome)." 1 }
  Write-Host "  nbackup -L (escritas vao para o .delta; usuarios seguem conectados)..." -ForegroundColor DarkGray
  $l = Invoke-FbNative -Exe $NbackupPath -Arguments @('-L', $Database) -User $User -Password $Password
  if($l.Exit -ne 0){
    Add-Check 'copia' 'nbackup -L' 'FALHA' $l.Text
  } else {
    try {
      Copy-Item -LiteralPath $Database -Destination $SnapshotCopy
    } finally {
      $n = Invoke-FbNative -Exe $NbackupPath -Arguments @('-N', $Database) -User $User -Password $Password
      if($n.Exit -ne 0){ Write-Warning ("nbackup -N FALHOU - rode manualmente: nbackup -N `"{0}`"  ({1})" -f $Database, $n.Text) }
    }
    $f = Invoke-FbNative -Exe $NbackupPath -Arguments @('-F', $SnapshotCopy) -User $User -Password $Password
    if($f.Exit -ne 0){ Add-Check 'copia' 'nbackup -F' 'FALHA' $f.Text }
    else { Add-Check 'copia' 'nbackup' 'OK' "copia consistente em $SnapshotCopy"; $target = $SnapshotCopy }
  }
}
if(-not $OutDir){ $OutDir = Split-Path -Parent (Resolve-Path -LiteralPath $target).Path }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$base = Join-Path $OutDir ("{0}.health-{1}" -f (Split-Path $target -Leaf), $stamp)

# ---------------- Lente 0 - estado ----------------
$h = Get-FbHeaderInfo -GstatPath $GstatPath -Database $target
$podeConectar = $false
if(-not $h.Ok){
  Add-Check 'estado' 'gstat -h' 'FALHA' 'gstat nao leu o header - rode Diagnose-FirebirdHeader.ps1 (procedure 03)'
} else {
  if($h.Shutdown -ne 'none' -and $BringOnline){
    $o = Invoke-FbNative -Exe $GfixPath -Arguments @('-online', $target) -User $User -Password $Password
    if($o.Exit -eq 0){ $h = Get-FbHeaderInfo -GstatPath $GstatPath -Database $target; Add-Check 'estado' 'gfix -online' 'OK' 'banco tirado do shutdown' }
    else { Add-Check 'estado' 'gfix -online' 'FALHA' $o.Text }
  }
  if($h.Shutdown -ne 'none'){ Add-Check 'estado' 'shutdown' 'FALHA' ("banco em shutdown ({0}) - 'gfix -online' ou -BringOnline" -f $h.Shutdown) }
  elseif($h.BackupLock){ Add-Check 'estado' 'nbackup' 'FALHA' "backup lock ativo - 'nbackup -N' no banco (ou 'nbackup -F' se for copia)" }
  else { Add-Check 'estado' 'acesso' 'OK' ("online; Attributes: {0}" -f $(if($h.Attributes){$h.Attributes}else{'(nenhum)'})); $podeConectar = $true }
}

# ---------------- Lente 1 - header ----------------
if($h.Ok){
  if($script:FbValidPageSizes -contains [int]$h.PageSize){ Add-Check 'header' 'page size' 'OK' $h.PageSize } else { Add-Check 'header' 'page size' 'FALHA' $h.PageSize }
  if($h.OdsVersion -like '11.*'){ Add-Check 'header' 'ODS' 'OK' $h.OdsVersion } else { Add-Check 'header' 'ODS' 'FALHA' ("{0} (esta skill e para ODS 11 / FB 2.x)" -f $h.OdsVersion) }
  if($h.Dialect){ Add-Check 'header' 'dialect' 'OK' $h.Dialect }
  $len = (Get-Item -LiteralPath $target).Length
  if($h.PageSize -and ($len % $h.PageSize) -ne 0){ Add-Check 'header' 'tamanho' 'FALHA' ("{0:N0} bytes nao e multiplo do page size - arquivo truncado" -f $len) }
  else { Add-Check 'header' 'tamanho' 'OK' ("{0:N0} bytes ({1:N0} paginas)" -f $len, ($len / [Math]::Max([int64]1, [int64]$h.PageSize))) }
  if($h.NextTransaction){ Add-Check 'header' 'transacoes' 'OK' ("Next {0:N0} ({1:N2}% do limite do 2.5); OIT {2:N0}; OAT {3:N0}" -f $h.NextTransaction, (100.0 * $h.NextTransaction / $script:FbMaxTransaction25), $h.OldestTransaction, $h.OldestActive) }
  foreach($x in @(Get-FbHeaderHints -Info $h)){
    if($x.Texto -notmatch 'shutdown|nbackup'){ Add-Check 'header' 'dica' $x.Nivel $x.Texto }
  }
}

# ---------------- Lente 2 - validacao ----------------
$modo = $Validation
if($modo -eq 'online' -and $podeConectar){
  $ver = Get-FbServerVersion -FbsvcmgrPath $FbsvcmgrPath -User $User -Password $Password
  if(-not $ver){ Add-Check 'validacao' 'servidor' 'FALHA' 'fbsvcmgr nao respondeu (servidor fora do ar ou usuario/senha errados)'; $modo = 'none' }
  elseif($ver -lt [version]'2.5.4.0'){ Add-Check 'validacao' 'servidor' 'ATENCAO' ("servidor {0} nao tem validacao online (2.5.4+); usando gfix -v -full" -f $ver); $modo = 'full' }
}
if(-not $podeConectar -and $modo -ne 'none'){ Add-Check 'validacao' $modo 'PULADO' 'banco nao esta acessivel (lente 0)' }
elseif($modo -eq 'online'){
  # Pagina ilegivel ABORTA a validacao online e as tabelas seguintes ficam sem validar. A tabela da pagina
  # vem do numero da pagina no erro (Find-FbPageOwner); revalida sem ela, ate terminar (no maximo 10 rodadas).
  $excluir = New-Object System.Collections.Generic.List[string]
  $abortos = New-Object System.Collections.Generic.List[string]
  $logVal  = New-Object System.Text.StringBuilder
  $p = $null; $semDono = $false
  for($rodada = 1; $rodada -le 10; $rodada++){
    $valArgs = @('service_mgr', 'action_validate', 'dbname', $target)
    if($excluir.Count){ $valArgs += @('val_tab_excl', (($excluir | ForEach-Object { ConvertTo-FbSimilarLiteral $_ }) -join '|')) }
    $v = Invoke-FbNative -Exe $FbsvcmgrPath -Arguments $valArgs -User $User -Password $Password
    [void]$logVal.AppendLine(("==== rodada {0}{1}" -f $rodada, $(if($excluir.Count){ ' (sem: ' + ($excluir -join ', ') + ')' } else { '' })))
    [void]$logVal.AppendLine($v.Text)
    $p = ConvertFrom-FbOnlineValidation -Lines $v.Lines -Exit $v.Exit
    if(-not $p.Aborted){ break }
    $donos = Find-FbPageOwner -IsqlPath $IsqlPath -Database $target -Pages $p.BadPages -User $User -Password $Password
    $novas = @($donos.Values | Select-Object -Unique | Where-Object { $excluir -notcontains $_ })
    if($novas.Count -eq 0){ $semDono = $true; break }
    foreach($t in $novas){
      $pgs = (@($donos.Keys | Where-Object { $donos[$_] -eq $t }) | Sort-Object) -join ', '
      $abortos.Add(("{0} (pagina {1}: {2})" -f $t, $pgs, $p.ErrorText))
      $excluir.Add($t)
    }
  }
  [IO.File]::WriteAllText("$base.validacao.log", $logVal.ToString())
  if($abortos.Count){ $details['Tabelas com pagina ilegivel (abortaram a validacao online)'] = @($abortos) }
  if($p.TablesWithErrors.Count){ $details['Tabelas com erro na validacao online'] = @($p.TablesWithErrors) }
  if($semDono){
    Add-Check 'validacao' 'online' 'FALHA' ("validacao abortou sem eu identificar a tabela (ultima no log: {0}; erro: {1}){2} - rode gfix -v -full numa copia" -f $(if($p.LastRelation){ $p.LastRelation } else { '?' }), $p.ErrorText, $(if($abortos.Count){ '; ja identificadas: ' + ($excluir -join ', ') } else { '' }))
  } elseif($p.Aborted){
    Add-Check 'validacao' 'online' 'FALHA' ("validacao abortou em {0} tabelas e parei ({1}) - corrupcao extensa, procedure 04 secao 5b" -f $excluir.Count, ($excluir -join ', '))
  } else {
    if($abortos.Count){ Add-Check 'validacao' 'online' 'FALHA' ("pagina ilegivel abortou a validacao em: {0}. Revalidado sem ela(s): {1} tabela(s) ok" -f ($abortos -join '; '), $p.TablesOk) }
    if($p.TablesWithErrors.Count){ Add-Check 'validacao' 'online' 'FALHA' ("tabelas com erro: {0}" -f ($p.TablesWithErrors -join ', ')) }
    if(-not $abortos.Count -and -not $p.TablesWithErrors.Count){ Add-Check 'validacao' 'online' 'OK' ("{0} tabela(s) ok" -f $p.TablesOk) }
  }
}
elseif($modo -eq 'full'){
  $v = Invoke-FbNative -Exe $GfixPath -Arguments @('-v', '-full', $target) -User $User -Password $Password
  [IO.File]::WriteAllText("$base.validacao.log", $v.Text)
  $saida = @($v.Lines | Where-Object { $_ -match '\S' })
  if($v.Text -match 'secondary server attachments'){ Add-Check 'validacao' 'gfix -v -full' 'FALHA' 'outra conexao aberta: gfix -v exige acesso exclusivo (use -Validation online ou gfix -shut single)' }
  elseif($saida.Count -gt 0){ Add-Check 'validacao' 'gfix -v -full' 'FALHA' (($saida | Select-Object -First 4) -join ' | '); $details['Saida do gfix -v -full'] = $saida }
  else { Add-Check 'validacao' 'gfix -v -full' 'OK' 'saida vazia' }
}
else { Add-Check 'validacao' 'nenhuma' 'PULADO' '-Validation none' }

# ---------------- Lente 3 - backup ----------------
if($SkipBackup){ Add-Check 'backup' 'gbak -b' 'PULADO' '-SkipBackup' }
elseif(-not $podeConectar){ Add-Check 'backup' 'gbak -b' 'PULADO' 'banco nao esta acessivel (lente 0)' }
else {
  $fbk = "$base.fbk"; $log = "$base.gbak.log"
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $b = Invoke-FbNative -Exe $GbakPath -Arguments @('-b', '-v', '-g', '-y', $log, $target, $fbk) -User $User -Password $Password
  $sw.Stop()
  $fim = (Test-Path -LiteralPath $log) -and ($null -ne (Select-String -LiteralPath $log -Pattern 'closing file, committing, and finishing'))
  $erros = if(Test-Path -LiteralPath $log){ @(Select-String -LiteralPath $log -Pattern 'gbak:\s*ERROR') } else { @() }
  if($b.Exit -eq 0 -and $fim -and $erros.Count -eq 0){
    Add-Check 'backup' 'gbak -b -g' 'OK' ("{0:N0} bytes em {1:N0}s" -f (Get-Item -LiteralPath $fbk).Length, $sw.Elapsed.TotalSeconds)
  } else {
    Add-Check 'backup' 'gbak -b -g' 'FALHA' ("o backup normal FALHA: {0}" -f (($erros | Select-Object -First 2 | ForEach-Object { $_.Line.Trim() }) -join ' | '))
    $fbk2 = "$base.ignore.fbk"; $log2 = "$base.gbak-ignore.log"
    $b2 = Invoke-FbNative -Exe $GbakPath -Arguments @('-b', '-v', '-ignore', '-g', '-y', $log2, $target, $fbk2) -User $User -Password $Password
    $fim2 = (Test-Path -LiteralPath $log2) -and ($null -ne (Select-String -LiteralPath $log2 -Pattern 'closing file, committing, and finishing'))
    if($b2.Exit -eq 0 -and $fim2){ Add-Check 'backup' 'gbak -b -ignore' 'ATENCAO' 'com -ignore o backup sai: corrupcao de checksum - dados recuperaveis (procedure 04 secao 2)' }
    else { Add-Check 'backup' 'gbak -b -ignore' 'FALHA' 'nem com -ignore: Salvage-Backup.ps1 mostra a tabela que quebra (procedure 06)' }
    if(-not $KeepBackup -and (Test-Path -LiteralPath $fbk2)){ Remove-Item -LiteralPath $fbk2 -Force }
  }
  if(-not $KeepBackup -and (Test-Path -LiteralPath $fbk)){ Remove-Item -LiteralPath $fbk -Force }
}

# ---------------- Lente 4 - isql ----------------
function Read-Counts([string[]]$lines){
  $map = [ordered]@{}
  foreach($l in $lines){ if($l -match '^\s*(\S+)\|(-?\d+)\s*$'){ $map[$Matches[1]] = [int64]$Matches[2] } }
  return $map
}
$contagens = $null
if(-not $podeConectar){ Add-Check 'isql' 'contagens' 'PULADO' 'banco nao esta acessivel (lente 0)' }
else {
  # objetos
  $obj = Invoke-FbIsqlFile -IsqlPath $IsqlPath -Database $target -SqlFile (Join-Path $sqlDir 'contagem-objetos.sql') -User $User -Password $Password
  $o = [ordered]@{}
  foreach($l in $obj.Lines){ if($l -match '^\s*([A-Z_]+)\s+(\d+)\s*$'){ $o[$Matches[1]] = [int64]$Matches[2] } }
  if($o.Count -eq 0){ Add-Check 'isql' 'objetos' 'FALHA' ("isql nao retornou contagens: {0}" -f (($obj.Lines | Select-Object -First 2) -join ' ')) }
  else {
    $details['Objetos'] = $o
    Add-Check 'isql' 'objetos' 'OK' (($o.Keys | Where-Object { $_ -notmatch 'INDICES_(INATIVOS|PENDENTES)|TRIGGERS_INATIVOS' } | ForEach-Object { "$_=$($o[$_])" }) -join ' ')
    if($o['INDICES_INATIVOS'] -gt 0 -or $o['INDICES_PENDENTES'] -gt 0){ Add-Check 'isql' 'indices' 'FALHA' ("inativos {0}, pendentes {1} - procedure 05 secoes 3/4b" -f $o['INDICES_INATIVOS'], $o['INDICES_PENDENTES']) }
    else { Add-Check 'isql' 'indices' 'OK' 'todos ativos' }
    if($o['TRIGGERS_INATIVOS'] -gt 0){ Add-Check 'isql' 'triggers' 'ATENCAO' ("{0} trigger(s) inativo(s) - confira se e intencional" -f $o['TRIGGERS_INATIVOS']) }
  }
  # registros por tabela
  $reg = Invoke-FbIsqlFile -IsqlPath $IsqlPath -Database $target -SqlFile (Join-Path $sqlDir 'contagem-registros-por-tabela.sql') -User $User -Password $Password
  $contagens = Read-Counts $reg.Lines
  [IO.File]::WriteAllLines("$base.contagem.txt", [string[]]@($contagens.Keys | ForEach-Object { "$_|$($contagens[$_])" }))
  $ileg = @($contagens.Keys | Where-Object { $contagens[$_] -lt 0 })
  $total = ($contagens.Values | Where-Object { $_ -ge 0 } | Measure-Object -Sum).Sum
  if($contagens.Count -eq 0){ Add-Check 'isql' 'registros' 'FALHA' 'contagem por tabela nao retornou nada' }
  elseif($ileg.Count -gt 0){ Add-Check 'isql' 'registros' 'FALHA' ("tabela(s) ilegivel(is): {0}" -f ($ileg -join ', ')); $details['Tabelas ilegiveis'] = $ileg }
  else { Add-Check 'isql' 'registros' 'OK' ("{0:N0} registros em {1} tabelas (contagem em {2})" -f $total, $contagens.Count, (Split-Path "$base.contagem.txt" -Leaf)) }
  # FKs orfas
  $fk = Invoke-FbIsqlFile -IsqlPath $IsqlPath -Database $target -SqlFile (Join-Path $sqlDir 'validar-fk-orfas.sql') -User $User -Password $Password
  $orfas = @(); $semConta = @()
  foreach($l in $fk.Lines){
    if($l -match '^\s*(\S+)\|(\S+)\|(\S+)\|(-?\d+)\s*$'){
      if([int64]$Matches[4] -gt 0){ $orfas += ('{0} ({1} -> {2}): {3}' -f $Matches[1], $Matches[2], $Matches[3], $Matches[4]) }
      elseif([int64]$Matches[4] -lt 0){ $semConta += $Matches[1] }
    }
  }
  if($orfas.Count -gt 0){ Add-Check 'isql' 'FKs orfas' 'FALHA' ("{0} FK(s) com orfas - o proximo restore vai quebrar (procedure 05 secao 4c)" -f $orfas.Count); $details['FKs com orfas'] = $orfas }
  else { Add-Check 'isql' 'FKs orfas' 'OK' 'nenhuma' }
  if($semConta.Count -gt 0){ Add-Check 'isql' 'FKs orfas' 'ATENCAO' ("nao consegui contar: {0}" -f ($semConta -join ', ')) }

  # comparacao com referencia
  $ref = $null
  if($ReferenceDatabase){
    $r = Invoke-FbIsqlFile -IsqlPath $IsqlPath -Database $ReferenceDatabase -SqlFile (Join-Path $sqlDir 'contagem-registros-por-tabela.sql') -User $User -Password $Password
    $ref = Read-Counts $r.Lines
  } elseif($ReferenceCounts){
    $ref = Read-Counts (Get-Content -LiteralPath $ReferenceCounts)
  }
  if($ref){
    $dif = @()
    foreach($k in (@($ref.Keys) + @($contagens.Keys) | Sort-Object -Unique)){
      $a = if($ref.Contains($k)){ $ref[$k] } else { $null }
      $b = if($contagens.Contains($k)){ $contagens[$k] } else { $null }
      if($a -ne $b){ $dif += ('{0}: referencia {1} / analisado {2}' -f $k, $(if($null -eq $a){'(nao existe)'}else{$a}), $(if($null -eq $b){'(nao existe)'}else{$b})) }
    }
    $tRef = ($ref.Values | Where-Object { $_ -ge 0 } | Measure-Object -Sum).Sum
    if($dif.Count -eq 0){ Add-Check 'comparacao' 'registros' 'OK' ("identico a referencia ({0:N0} registros)" -f $tRef) }
    else { Add-Check 'comparacao' 'registros' 'ATENCAO' ("{0} tabela(s) diferem; total referencia {1:N0} x analisado {2:N0}" -f $dif.Count, $tRef, $total); $details['Diferencas de contagem'] = $dif }
  }
}

# ---------------- relatorio ----------------
$falhas = @($checks | Where-Object Status -eq 'FALHA').Count
$atenc  = @($checks | Where-Object Status -eq 'ATENCAO').Count
$veredito = if($falhas -gt 0){ 'FALHA' } elseif($atenc -gt 0){ 'OK com atencao' } else { 'OK' }

$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# Health check Firebird - $(Split-Path $target -Leaf)")
[void]$md.AppendLine('')
[void]$md.AppendLine("- Banco analisado: ``$target``")
if($SnapshotCopy){ [void]$md.AppendLine("- Copia de: ``$Database`` (nbackup)") }
[void]$md.AppendLine("- Data: $($inicio.ToString('yyyy-MM-dd HH:mm')) - duracao $([int]((Get-Date) - $inicio).TotalSeconds) s")
[void]$md.AppendLine("- Validacao: $modo")
[void]$md.AppendLine("- **Resultado: $veredito** ($falhas falha(s), $atenc atencao)")
[void]$md.AppendLine('')
[void]$md.AppendLine('| Lente | Item | Status | Detalhe |')
[void]$md.AppendLine('|---|---|---|---|')
foreach($c in $checks){ [void]$md.AppendLine(('| {0} | {1} | {2} | {3} |' -f $c.Lente, $c.Item, $c.Status, ($c.Detalhe -replace '\|', '/'))) }
foreach($k in $details.Keys){
  [void]$md.AppendLine(''); [void]$md.AppendLine("## $k"); [void]$md.AppendLine('')
  $v = $details[$k]
  if($v -is [System.Collections.IDictionary]){ foreach($kk in $v.Keys){ [void]$md.AppendLine("- $kk = $($v[$kk])") } }
  else { foreach($i in @($v)){ [void]$md.AppendLine("- $i") } }
}
[IO.File]::WriteAllText("$base.md", $md.ToString(), (New-Object Text.UTF8Encoding($false)))
$json = [ordered]@{ banco = $target; origem = $Database; data = $inicio.ToString('s'); validacao = $modo; resultado = $veredito; falhas = $falhas; atencao = $atenc; verificacoes = $checks; detalhes = $details }
[IO.File]::WriteAllText("$base.json", ($json | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))

Write-Host ""
$corV = if($falhas -gt 0){ 'Red' } elseif($atenc -gt 0){ 'Yellow' } else { 'Green' }
Write-Host (">> Resultado: {0}  ({1} falha(s), {2} atencao)" -f $veredito, $falhas, $atenc) -ForegroundColor $corV
Write-Host (">> Relatorio: {0}.md  |  {0}.json" -f $base) -ForegroundColor DarkGray
if($falhas -gt 0){ exit 2 } else { exit 0 }
