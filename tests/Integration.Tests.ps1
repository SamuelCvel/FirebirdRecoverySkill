<#
  Testes de integracao: precisam do Firebird 2.5 instalado e do servico rodando.
  Usam SO bancos descartaveis numa pasta temporaria: copias do banco de exemplo EMPLOYEE.FDB
  (pasta examples\empbuild da instalacao) e bancos sinteticos criados aqui. Nunca tocam em
  banco real. Carregado pelo Run-Tests.ps1 -Integration.
  Credenciais: ISC_USER/ISC_PASSWORD do ambiente, senao SYSDBA/masterkey.
#>
$root   = Split-Path $PSScriptRoot -Parent
$skill  = Join-Path $root 'skills\firebird-recovery'
$sk     = Join-Path $skill 'scripts'
$sqlDir = Join-Path $skill 'sql'
. (Join-Path $sk '_FirebirdCommon.ps1')

Write-Host "== Integracao: preparando bancos de teste ==" -ForegroundColor Cyan
$bin = Get-FbBinDir
if(-not $bin){ Test-Case 'Firebird 2.5 instalado' { throw 'gbak.exe nao encontrado (instale o Firebird 2.5 ou defina a variavel FIREBIRD)' }; return }
$isql   = Join-Path $bin 'isql.exe'
$fbUser = if($env:ISC_USER){ $env:ISC_USER } else { 'SYSDBA' }
$fbPass = if($env:ISC_PASSWORD){ $env:ISC_PASSWORD } else { 'masterkey' }
$ver = Get-FbServerVersion -FbsvcmgrPath (Join-Path $bin 'fbsvcmgr.exe') -User $fbUser -Password $fbPass
if(-not $ver -or $ver.Major -ne 2){
  Test-Case 'Servidor Firebird 2.x respondendo' { throw ("fbsvcmgr nao respondeu ou versao inesperada ({0}): servico parado ou usuario/senha errados (ISC_USER/ISC_PASSWORD)" -f $ver) }
  return
}
$sample = Join-Path (Split-Path $bin -Parent) 'examples\empbuild\EMPLOYEE.FDB'
if(-not (Test-Path -LiteralPath $sample)){ Test-Case 'Banco de exemplo EMPLOYEE.FDB' { throw "nao encontrado: $sample" }; return }

$it = Join-Path ([IO.Path]::GetTempPath()) ('fbrec-it-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $it | Out-Null
Write-Host ("  Firebird {0}  |  pasta: {1}" -f $ver, $it) -ForegroundColor DarkGray

# ---------------- ajudantes ----------------
function ItPath([string]$Name){ Join-Path $it $Name }
function New-EmpCopy([string]$Name){
  $p = ItPath $Name
  [IO.File]::Copy($sample, $p, $true)
  [IO.File]::SetAttributes($p, [IO.FileAttributes]::Normal)
  $p
}
function Invoke-ItSql([string]$Database, [string]$Sql){ Invoke-FbIsql -IsqlPath $isql -Database $Database -Sql $Sql -User $fbUser -Password $fbPass }
function Invoke-ItTool([string]$Exe, [string[]]$Arguments){ Invoke-FbNative -Exe (Join-Path $bin $Exe) -Arguments $Arguments -User $fbUser -Password $fbPass }
function Invoke-ItScript([string]$Sql){
  # script sem banco na linha de comando (CREATE DATABASE usa ISC_USER/ISC_PASSWORD)
  $f = ItPath ('script-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.sql')
  [IO.File]::WriteAllText($f, $Sql, (New-Object Text.UTF8Encoding($false)))
  Invoke-FbNative -Exe $isql -Arguments @('-q', '-b', '-i', $f) -User $fbUser -Password $fbPass
}
function Get-SqlScalar([string]$Database, [string]$Query){
  $r = Invoke-ItSql $Database ("SET HEADING OFF;`n{0};" -f $Query)
  $l = @($r.Lines | Where-Object { $_ -match '\S' })
  if($r.Exit -ne 0 -or $l.Count -eq 0){ throw ("consulta falhou: {0} -> {1}" -f $Query, ($r.Lines -join ' ')) }
  $l[0].Trim()
}
function Set-FileBytes([string]$Path, [long]$Offset, [byte[]]$Bytes){
  $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  try { [void]$fs.Seek($Offset, 'Begin'); $fs.Write($Bytes, 0, $Bytes.Length) } finally { $fs.Dispose() }
}
function Get-PageSizeOf([string]$Path){ [int][BitConverter]::ToUInt16((Read-FbBytes -Path $Path -Offset 16 -Count 2), 0) }
function Get-DataPages([string]$Path, [int]$RelationId){
  <# sequencia -> numero fisico das paginas de dados (pag_type 5) de uma tabela: dpg_sequence em 0x10, dpg_relation em 0x14 #>
  $ps = Get-PageSizeOf $Path
  $b = [IO.File]::ReadAllBytes($Path)
  $map = @{}
  for($p = 0; ($p + 1) * $ps -le $b.Length; $p++){
    $o = $p * $ps
    if($b[$o] -eq 5 -and [BitConverter]::ToUInt16($b, $o + 0x14) -eq $RelationId){ $map[[long][BitConverter]::ToUInt32($b, $o + 0x10)] = $p }
  }
  $map
}
function Get-KeyPageSeq([string]$Database, [string]$Table, [string]$KeyExpr){
  <# chave -> sequencia da pagina de dados, pelo RDB$DB_KEY (bytes 4-7 = numero do registro + 1;
     registros por pagina = (page_size - 28) / 17). E o gabarito do que uma pagina zerada leva junto. #>
  $perPage = [Math]::Floor(((Get-PageSizeOf $Database) - 28) / 17)
  $r = Invoke-ItSql $Database ("SET HEADING OFF;`nSELECT {0}, RDB`$DB_KEY FROM {1};" -f $KeyExpr, $Table)
  $map = @{}
  foreach($l in $r.Lines){
    $m = [regex]::Match($l, '^\s*(\S+)\s+([0-9A-Fa-f]{16})\s*$')
    if(-not $m.Success){ continue }
    $h = $m.Groups[2].Value
    [byte[]]$k = for($i = 0; $i -lt 16; $i += 2){ [Convert]::ToByte($h.Substring($i, 2), 16) }
    $recno = [long][BitConverter]::ToUInt32($k, 4) + ([long]$k[3] -shl 32) - 1
    $map[$m.Groups[1].Value] = [long][Math]::Floor($recno / $perPage)
  }
  $map
}
function Get-RelationId([string]$Database, [string]$Table){
  [int](Get-SqlScalar $Database ("SELECT RDB`$RELATION_ID FROM RDB`$RELATIONS WHERE RDB`$RELATION_NAME = '{0}'" -f $Table))
}
function Clear-Pages([string]$Path, [long[]]$Pages){
  $ps = Get-PageSizeOf $Path
  foreach($p in $Pages){ Set-FileBytes $Path ($p * $ps) (New-Object byte[] $ps) }
}

# ---------------- bancos de teste ----------------
$fixturesOk = $true
Test-Case 'Fixtures: copias do EMPLOYEE (header, truncado, forced writes, pagina zerada)' {
  $script:emp   = New-EmpCopy 'EMP.FDB'
  $script:hdr   = New-EmpCopy 'EMP_HDR.FDB'
  Set-FileBytes $hdr 17 ([byte[]]@(((Read-FbBytes -Path $hdr -Offset 17 -Count 1)[0]) -bor 0x80))
  $script:trunc = New-EmpCopy 'EMP_TRUNC.FDB'
  $fs = [IO.File]::Open($trunc, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  try { $fs.SetLength($fs.Length - 1000) } finally { $fs.Dispose() }
  $script:fwoff = New-EmpCopy 'EMP_FWOFF.FDB'
  $r = Invoke-ItTool 'gfix.exe' @('-write', 'async', $fwoff); Assert-Equal 0 $r.Exit 'gfix -write async'
  $script:corr  = New-EmpCopy 'EMP_CORR.FDB'
  $pages = Get-DataPages $corr (Get-RelationId $emp 'SALES')
  Assert-True ($pages.Count -gt 0) 'paginas de dados da SALES'
  Clear-Pages $corr ([long[]]@($pages.Values))
  $script:notDb = ItPath 'nao-e-banco.fdb'
  [IO.File]::WriteAllText($notDb, 'isto nao e um banco Firebird')
  $script:okFbk = ItPath 'emp-ok.fbk'
  $r = Invoke-ItTool 'gbak.exe' @('-b', '-g', $emp, $okFbk); Assert-Equal 0 $r.Exit 'gbak -b'
  $all = [IO.File]::ReadAllBytes($okFbk)
  $cut = New-Object byte[] ([int]($all.Length * 0.6)); [Array]::Copy($all, $cut, $cut.Length)
  $script:truncFbk = ItPath 'emp-truncado.fbk'
  [IO.File]::WriteAllBytes($truncFbk, $cut)
}
Test-Case 'Fixtures: banco com FK composta e orfa escondida (indices inativos)' {
  $fk = ItPath 'FK.FDB'
  $r = Invoke-ItScript @"
CREATE DATABASE '$fk' PAGE_SIZE 4096;
CREATE TABLE PAI (EMP INTEGER NOT NULL, COD INTEGER NOT NULL, CONSTRAINT PK_PAI PRIMARY KEY (EMP, COD));
CREATE TABLE FILHA (ID INTEGER NOT NULL PRIMARY KEY, EMP INTEGER, COD INTEGER,
  CONSTRAINT FK_FILHA_PAI FOREIGN KEY (EMP, COD) REFERENCES PAI (EMP, COD));
COMMIT;
INSERT INTO PAI VALUES (1, 10);
INSERT INTO PAI VALUES (1, 20);
INSERT INTO PAI VALUES (2, 10);
INSERT INTO FILHA VALUES (1, 1, 10);
INSERT INTO FILHA VALUES (2, 1, 20);
INSERT INTO FILHA VALUES (3, 2, 10);
INSERT INTO FILHA VALUES (4, NULL, 99);
COMMIT;
"@
  Assert-Equal 0 $r.Exit $r.Text
  $fbk = ItPath 'fk.fbk'
  $r = Invoke-ItTool 'gbak.exe' @('-b', $fk, $fbk); Assert-Equal 0 $r.Exit 'gbak -b'
  $script:fkInactive = ItPath 'FK_I.FDB'
  $r = Invoke-ItTool 'gbak.exe' @('-c', '-i', $fbk, $fkInactive); Assert-Equal 0 $r.Exit 'gbak -c -i'
  # (2,20): EMP 2 existe e COD 20 existe, mas o PAR nao - validar coluna a coluna deixaria passar
  $r = Invoke-ItSql $fkInactive "INSERT INTO FILHA VALUES (5, 2, 20);`nCOMMIT;"
  Assert-Equal 0 $r.Exit $r.Text
}
Test-Case 'Fixtures: banco do pump (chave inteira, composta e texto) com paginas zeradas' {
  $script:pump = ItPath 'PUMP.FDB'
  $pad = ((1..9) | ForEach-Object { 'UUID_TO_CHAR(GEN_UUID())' }) -join ' || '
  $r = Invoke-ItScript @"
CREATE DATABASE '$pump' PAGE_SIZE 4096;
CREATE TABLE T1 (ID INTEGER NOT NULL PRIMARY KEY, PAD VARCHAR(400));
CREATE TABLE T2 (EMP INTEGER NOT NULL, COD INTEGER NOT NULL, PAD VARCHAR(400), CONSTRAINT PK_T2 PRIMARY KEY (EMP, COD));
CREATE TABLE T3 (CODIGO VARCHAR(20) NOT NULL PRIMARY KEY, PAD VARCHAR(400));
COMMIT;
SET TERM ^ ;
EXECUTE BLOCK AS
  DECLARE I INTEGER = 1;
  DECLARE E INTEGER;
  DECLARE C INTEGER;
BEGIN
  WHILE (I <= 3000) DO BEGIN INSERT INTO T1 VALUES (:I, $pad); I = I + 1; END
  E = 1;
  WHILE (E <= 3) DO BEGIN
    C = 1;
    WHILE (C <= 800) DO BEGIN INSERT INTO T2 VALUES (:E, :C, $pad); C = C + 1; END
    E = E + 1;
  END
  I = 1;
  WHILE (I <= 500) DO BEGIN INSERT INTO T3 VALUES ('C' || LPAD(:I, 6, '0'), $pad); I = I + 1; END
END^
SET TERM ; ^
COMMIT;
"@
  Assert-Equal 0 $r.Exit $r.Text
  $script:pumpMeta = ItPath 'pump-meta.fbk'
  $r = Invoke-ItTool 'gbak.exe' @('-b', '-m', $pump, $pumpMeta); Assert-Equal 0 $r.Exit 'gbak -b -m'
  $script:keys = @{
    T1 = Get-KeyPageSeq $pump 'T1' 'ID'
    T2 = Get-KeyPageSeq $pump 'T2' "EMP || '|' || COD"
    T3 = Get-KeyPageSeq $pump 'T3' 'CODIGO'
  }
  Assert-Equal 3000 $keys.T1.Count 'chaves T1'; Assert-Equal 2400 $keys.T2.Count 'chaves T2'; Assert-Equal 500 $keys.T3.Count 'chaves T3'
  # paginas a zerar: meio da T1; na T2 a fronteira EMP 1 -> 2 e o meio do EMP 3; meio da T3
  $bad = @{
    T1 = @($keys.T1['1500'])
    T2 = @($keys.T2['1|800'], $keys.T2['2|1'], $keys.T2['3|400'] | Select-Object -Unique)
    T3 = @($keys.T3['C000250'])
  }
  $script:pumpCorr = ItPath 'PUMP_CORR.FDB'
  [IO.File]::Copy($pump, $pumpCorr, $true)
  $script:lost = @{}
  foreach($t in 'T1', 'T2', 'T3'){
    $pages = Get-DataPages $pumpCorr (Get-RelationId $pump $t)
    Clear-Pages $pumpCorr ([long[]]@($bad[$t] | ForEach-Object { $pages[[long]$_] }))
    $k = $keys[$t]
    $lost[$t] = @($k.Keys | Where-Object { $bad[$t] -contains $k[$_] })
    Assert-True ($lost[$t].Count -gt 0) "gabarito de perdas da $t"
  }
}
if(@($script:TestResults | Where-Object { $_.Teste -like 'Fixtures:*' -and -not $_.OK }).Count){
  Write-Host "  Fixtures falharam: pulei o resto da integracao." -ForegroundColor Red
  return
}

# ---------------- header ----------------
Write-Host "== Integracao: header ==" -ForegroundColor Cyan
Test-Case 'Diagnose: banco saudavel' { Assert-Run (Invoke-Script "$sk\Diagnose-FirebirdHeader.ps1" @('-Database', $emp)) 0 'Header OK' }
Test-Case 'Diagnose: page_size corrompido' { Assert-Run (Invoke-Script "$sk\Diagnose-FirebirdHeader.ps1" @('-Database', $hdr)) 1 'CORROMPIDO' }
Test-Case 'Diagnose: arquivo truncado' { Assert-Run (Invoke-Script "$sk\Diagnose-FirebirdHeader.ps1" @('-Database', $trunc)) 4 'TRUNCADO' }
Test-Case 'Diagnose: forced writes desligado' { Assert-Run (Invoke-Script "$sk\Diagnose-FirebirdHeader.ps1" @('-Database', $fwoff)) 0 'forced writes DESLIGADO' }
Test-Case 'Diagnose: arquivo inexistente' { Assert-Run (Invoke-Script "$sk\Diagnose-FirebirdHeader.ps1" @('-Database', (ItPath 'nao-existe.fdb'))) 3 }
Test-Case 'Repair: -WhatIf nao grava' {
  $script:rep = ItPath 'EMP_REP.FDB'; [IO.File]::Copy($hdr, $rep, $true)
  $antes = [IO.File]::ReadAllBytes($rep)[17]
  Assert-Run (Invoke-Script "$sk\Repair-FirebirdHeader.ps1" @('-Database', $rep, '-WhatIf')) 4
  Assert-Equal $antes ([IO.File]::ReadAllBytes($rep)[17]) 'byte 0x11 intacto'
}
Test-Case 'Repair: corrige com -Confirm:$false' { Assert-Run (Invoke-Script "$sk\Repair-FirebirdHeader.ps1" @('-Database', $rep, '-Confirm:$false')) 0 'CORRIGIDO' }
Test-Case 'Repair: recusa header valido' { Assert-Run (Invoke-Script "$sk\Repair-FirebirdHeader.ps1" @('-Database', $rep, '-Confirm:$false')) 1 }
Test-Case 'Demo: setup, corrupt, diagnose, fix' {
  $demo = ItPath 'DEMO.FDB'
  Assert-Run (Invoke-Script "$sk\Demo-CorrupcaoHeader.ps1" @('-Database', $demo, '-Action', 'setup')) 0 'Banco de treino criado'
  Assert-Run (Invoke-Script "$sk\Demo-CorrupcaoHeader.ps1" @('-Database', $demo, '-Action', 'corrupt', '-Force')) 0 'CORROMPIDO'
  Assert-Run (Invoke-Script "$sk\Demo-CorrupcaoHeader.ps1" @('-Database', $demo, '-Action', 'diagnose')) 0 'SINTOMA classico'
  Assert-Run (Invoke-Script "$sk\Demo-CorrupcaoHeader.ps1" @('-Database', $demo, '-Action', 'fix', '-Force')) 0 'CORRIGIDO com sucesso'
}

# ---------------- backup, restore e servico ----------------
Write-Host "== Integracao: backup, restore, shutdown ==" -ForegroundColor Cyan
Test-Case 'Salvage-Backup: aponta a tabela da pagina zerada' { Assert-Run (Invoke-Script "$sk\Salvage-Backup.ps1" @('-Database', $corr, '-BackupFile', (ItPath 'corr.fbk'))) 2 'Tabela afetada: SALES' }
Test-Case 'Salvage-Backup: banco saudavel' { Assert-Run (Invoke-Script "$sk\Salvage-Backup.ps1" @('-Database', $emp, '-BackupFile', (ItPath 'salv-ok.fbk'))) 0 'Backup limpo' }
Test-Case 'Salvage-Backup: nao sobrescreve sem -Force' { Assert-Run (Invoke-Script "$sk\Salvage-Backup.ps1" @('-Database', $emp, '-BackupFile', (ItPath 'salv-ok.fbk'))) 4 }
Test-Case 'Restore-Clean: restore normal' { Assert-Run (Invoke-Script "$sk\Restore-Clean.ps1" @('-BackupFile', $okFbk, '-TargetDatabase', (ItPath 'REST.FDB'))) 0 'Restore OK' }
Test-Case 'Restore-Clean: nao sobrescreve sem -Replace' { Assert-Run (Invoke-Script "$sk\Restore-Clean.ps1" @('-BackupFile', $okFbk, '-TargetDatabase', (ItPath 'REST.FDB'))) 4 }
Test-Case 'Restore-Clean: so metadata' { Assert-Run (Invoke-Script "$sk\Restore-Clean.ps1" @('-BackupFile', $okFbk, '-TargetDatabase', (ItPath 'REST_META.FDB'), '-MetadataOnly')) 0 'Restore OK' }
Test-Case 'Restore-Clean: .fbk truncado deixa o destino em manutencao' { Assert-Run (Invoke-Script "$sk\Restore-Clean.ps1" @('-BackupFile', $truncFbk, '-TargetDatabase', (ItPath 'REST_TRUNC.FDB'))) 2 'manutencao' }
Test-Case 'Firebird-Service: shutdown full e online' {
  $svc = New-EmpCopy 'EMP_SVC.FDB'
  Assert-Run (Invoke-Script "$sk\Firebird-Service.ps1" @('-Action', 'shutdown', '-Database', $svc)) 0 'OK \(full\)'
  Assert-Equal 'full' (Get-FbHeaderInfo -GstatPath (Join-Path $bin 'gstat.exe') -Database $svc).Shutdown 'estado apos shutdown'
  Assert-Run (Invoke-Script "$sk\Firebird-Service.ps1" @('-Action', 'online', '-Database', $svc)) 0 'OK\.'
  Assert-Equal 'none' (Get-FbHeaderInfo -GstatPath (Join-Path $bin 'gstat.exe') -Database $svc).Shutdown 'estado apos online'
}
Test-Case 'Firebird-Service: arquivo que nao e banco' { Assert-Run (Invoke-Script "$sk\Firebird-Service.ps1" @('-Action', 'shutdown', '-Database', $notDb)) 2 }

# ---------------- SQL da skill ----------------
Write-Host "== Integracao: SQL da skill ==" -ForegroundColor Cyan
Test-Case 'sondar-tabelas.sql: acha a tabela ilegivel sem parar' {
  $r = Invoke-FbIsqlFile -IsqlPath $isql -Database $corr -SqlFile (Join-Path $sqlDir 'sondar-tabelas.sql') -User $fbUser -Password $fbPass
  Assert-Match $r.Text 'SALES\s*\|\s*-1\s*\|\s*ERRO' 'SALES com erro'
  Assert-Match $r.Text 'EMPLOYEE\s*\|\s*\d+\s*\|\s*OK' 'demais tabelas lidas'
}
Test-Case 'validar-fk-orfas.sql: orfa de FK composta (e ignora FK com NULL)' {
  $r = Invoke-FbIsqlFile -IsqlPath $isql -Database $fkInactive -SqlFile (Join-Path $sqlDir 'validar-fk-orfas.sql') -User $fbUser -Password $fbPass
  Assert-Match $r.Text 'FK_FILHA_PAI\s*\|\s*FILHA\s*\|\s*PAI\s*\|\s*1\b' 'uma orfa'
}
Test-Case 'gerar-script-salvage.sql: copia o EMPLOYEE inteiro por EDS' {
  $dst = ItPath 'SALV.FDB'
  $r = Invoke-ItTool 'gbak.exe' @('-c', '-m', '-i', $okFbk, $dst); Assert-Equal 0 $r.Exit 'destino so com metadata'
  $g = Invoke-FbIsqlFile -IsqlPath $isql -Database $dst -SqlFile (Join-Path $sqlDir 'gerar-script-salvage.sql') -User $fbUser -Password $fbPass
  Assert-Equal 0 $g.Exit 'gerador'
  $pronto = ItPath 'copiar-pronto.sql'
  $txt = ($g.Lines -join "`r`n").Replace('<ORIGEM>', $emp).Replace('<USUARIO>', $fbUser).Replace('<SENHA>', $fbPass)
  [IO.File]::WriteAllText($pronto, $txt, (New-Object Text.UTF8Encoding($false)))
  try {
    $c = Invoke-FbNative -Exe $isql -Arguments @('-q', '-b', '-e', '-nod', '-i', $pronto, $dst) -User $fbUser -Password $fbPass
  } finally { Remove-Item -LiteralPath $pronto -Force -ErrorAction SilentlyContinue }
  Assert-Equal 0 $c.Exit (($c.Lines | Select-Object -Last 4) -join ' | ')
  $cont = Join-Path $sqlDir 'contagem-registros-por-tabela.sql'
  $a = (Invoke-FbIsqlFile -IsqlPath $isql -Database $emp -SqlFile $cont -User $fbUser -Password $fbPass).Lines | Where-Object { $_ -match '\|' } | ForEach-Object { $_.Trim() }
  $b = (Invoke-FbIsqlFile -IsqlPath $isql -Database $dst -SqlFile $cont -User $fbUser -Password $fbPass).Lines | Where-Object { $_ -match '\|' } | ForEach-Object { $_.Trim() }
  Assert-True (@($a).Count -gt 5) 'contagens da origem'
  Assert-Equal (@($a) -join ';') (@($b) -join ';') 'contagens origem x destino'
  Assert-Equal (Get-SqlScalar $emp 'SELECT GEN_ID(EMP_NO_GEN, 0) FROM RDB$DATABASE') (Get-SqlScalar $dst 'SELECT GEN_ID(EMP_NO_GEN, 0) FROM RDB$DATABASE') 'generator sincronizado'
}

# ---------------- pump por chave ----------------
Write-Host "== Integracao: pump por chave (EDS) ==" -ForegroundColor Cyan
function New-PumpTarget([string]$Name, [string]$Fbk){
  $d = ItPath $Name
  $r = Invoke-ItTool 'gbak.exe' @('-c', '-m', '-i', $Fbk, $d)
  if($r.Exit -ne 0){ throw "restore do destino falhou: $($r.Text)" }
  $d
}
function Assert-PumpResult([string]$Target, [string]$Table, [string]$KeyExpr, [int]$Total, [string[]]$Lost){
  # destino = origem menos EXATAMENTE as chaves das paginas zeradas, sem duplicata
  $c = Get-SqlScalar $Target ("SELECT COUNT(*) || '|' || COUNT(DISTINCT {0}) FROM {1}" -f $KeyExpr, $Table)
  Assert-Equal ("{0}|{0}" -f ($Total - $Lost.Count)) $c "linhas|distintas em $Table"
  $in = ($Lost | ForEach-Object { "'" + $_ + "'" }) -join ','
  Assert-Equal '0' (Get-SqlScalar $Target ("SELECT COUNT(*) FROM {0} WHERE {1} IN ({2})" -f $Table, $KeyExpr, $in)) "chaves perdidas no destino ($Table)"
}
Test-Case 'Pump: uma janela no EMPLOYEE' {
  $dst = New-PumpTarget 'EMP_PUMP.FDB' $okFbk
  Assert-Run (Invoke-Script "$sk\Salvage-TableByTable.ps1" @('-Action', 'pump', '-Database', $emp, '-TargetDatabase', $dst, '-Table', 'EMPLOYEE', '-Window', '50')) 0 'copiados nesta janela: 42'
}
Test-Case 'Pump -Auto: chave inteira perde so a pagina zerada' {
  $dst = New-PumpTarget 'PUMP_T1.FDB' $pumpMeta
  Assert-Run (Invoke-Script "$sk\Salvage-TableByTable.ps1" @('-Action', 'pump', '-Database', $pumpCorr, '-TargetDatabase', $dst, '-Table', 'T1', '-Window', '500', '-Auto', '-ReportFile', (ItPath 'T1.csv'))) 0 'faixas perdidas: 1'
  Assert-PumpResult $dst 'T1' 'ID' 3000 $lost.T1
  Assert-True (@(Import-Csv -Path (ItPath 'T1.csv') -Delimiter ';').Count -ge 1) 'relatorio CSV'
}
Test-Case 'Pump -Auto: chave composta, inclusive pagina na troca de prefixo' {
  $dst = New-PumpTarget 'PUMP_T2.FDB' $pumpMeta
  Assert-Run (Invoke-Script "$sk\Salvage-TableByTable.ps1" @('-Action', 'pump', '-Database', $pumpCorr, '-TargetDatabase', $dst, '-Table', 'T2', '-Window', '500', '-Auto', '-ReportFile', (ItPath 'T2.csv'))) 0 'Tabela concluida'
  Assert-PumpResult $dst 'T2' "EMP || '|' || COD" 2400 $lost.T2
}
Test-Case 'Pump -Auto: chave texto para na regiao ruim e retoma com -StartKey' {
  $dst = New-PumpTarget 'PUMP_T3.FDB' $pumpMeta
  $r = Invoke-Script "$sk\Salvage-TableByTable.ps1" @('-Action', 'pump', '-Database', $pumpCorr, '-TargetDatabase', $dst, '-Table', 'T3', '-Window', '100', '-Auto', '-ReportFile', (ItPath 'T3a.csv'))
  Assert-Run $r 2 'StartKey'
  Assert-Match $r.Text 'parou em C\d+: .*Erro: .*(appears corrupt|checksum|wrong page type|wrong type)' 'motivo da parada com a mensagem real do Firebird'
  $depois = ($lost.T3 | Sort-Object | Select-Object -Last 1)
  Assert-Run (Invoke-Script "$sk\Salvage-TableByTable.ps1" @('-Action', 'pump', '-Database', $pumpCorr, '-TargetDatabase', $dst, '-Table', 'T3', '-Window', '100', '-Auto', '-StartKey', $depois, '-ReportFile', (ItPath 'T3b.csv'))) 0 'Tabela concluida'
  Assert-PumpResult $dst 'T3' 'CODIGO' 500 $lost.T3
}
Test-Case 'Salvage-TableByTable list: inventario aponta a tabela ilegivel' { Assert-Run (Invoke-Script "$sk\Salvage-TableByTable.ps1" @('-Action', 'list', '-Database', $corr)) 0 'Ilegiveis: SALES' }

# ---------------- health check, troca, ambiente ----------------
Write-Host "== Integracao: health check, troca em producao, ambiente ==" -ForegroundColor Cyan
Test-Case 'Test-FirebirdHealth: banco saudavel fica verde e gera .md/.json' {
  $h = New-EmpCopy 'EMP_HEALTH.FDB'
  Assert-Run (Invoke-Script "$sk\Test-FirebirdHealth.ps1" @('-Database', $h, '-OutDir', $it)) 0
  Assert-True (@(Get-ChildItem -LiteralPath $it -Filter 'EMP_HEALTH.FDB.health-*.md').Count -eq 1) 'relatorio .md'
  $j = Get-ChildItem -LiteralPath $it -Filter 'EMP_HEALTH.FDB.health-*.json' | Select-Object -First 1
  Assert-True ($null -ne $j -and $null -ne ((Get-Content -LiteralPath $j.FullName -Raw) | ConvertFrom-Json)) 'relatorio .json valido'
}
Test-Case 'Test-FirebirdHealth: pagina zerada da FALHA' { Assert-Run (Invoke-Script "$sk\Test-FirebirdHealth.ps1" @('-Database', $corr, '-OutDir', $it)) 2 'SALES' }
Test-Case 'Test-FirebirdHealth: orfa de FK e indices inativos dao FALHA' { Assert-Run (Invoke-Script "$sk\Test-FirebirdHealth.ps1" @('-Database', $fkInactive, '-OutDir', $it, '-SkipBackup')) 2 'FK' }
Test-Case 'Swap-ProductionDatabase: -WhatIf nao mexe em nada' {
  $script:prod = New-EmpCopy 'PROD.FDB'
  $script:cand = New-EmpCopy 'CAND.FDB'
  Assert-Run (Invoke-Script "$sk\Swap-ProductionDatabase.ps1" @('-Production', $prod, '-Candidate', $cand, '-Isolation', 'Shutdown', '-WhatIf')) 4
  Assert-True ((Test-Path -LiteralPath $cand) -and -not (Get-ChildItem -LiteralPath $it -Filter 'PROD.FDB.antigo.*')) 'arquivos intactos'
}
Test-Case 'Swap-ProductionDatabase: troca com shutdown e guarda o antigo' {
  Assert-Run (Invoke-Script "$sk\Swap-ProductionDatabase.ps1" @('-Production', $prod, '-Candidate', $cand, '-Isolation', 'Shutdown', '-Confirm:$false')) 0 'Troca concluida'
  Assert-True (Test-Path -LiteralPath $prod) 'producao no lugar'
  Assert-True (@(Get-ChildItem -LiteralPath $it -Filter 'PROD.FDB.antigo.*').Count -eq 1) 'antigo guardado'
  Assert-Equal 'none' (Get-FbHeaderInfo -GstatPath (Join-Path $bin 'gstat.exe') -Database $prod).Shutdown 'producao online'
}
Test-Case 'Get-FirebirdEnvironmentReport: gera o relatorio (so leitura)' {
  Assert-Run (Invoke-Script "$sk\Get-FirebirdEnvironmentReport.ps1" @('-Database', $emp, '-OutDir', $it, '-Days', '2')) 0
  Assert-True (@(Get-ChildItem -LiteralPath $it -Filter 'ambiente-firebird-*.md').Count -ge 1) 'relatorio .md'
}

# ---------------- limpeza ----------------
if($script:KeepFixtures){
  Write-Host ("  Bancos de teste mantidos em: {0}" -f $it) -ForegroundColor DarkGray
} else {
  Remove-Item -LiteralPath $it -Recurse -Force -ErrorAction SilentlyContinue
  if(Test-Path -LiteralPath $it){ Write-Host ("  Nao consegui apagar tudo (arquivo em uso?): {0}" -f $it) -ForegroundColor Yellow }
}
