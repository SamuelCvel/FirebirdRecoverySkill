<#
  Testes unitarios - nao precisam do Firebird. Rodam no CI.
  Uso: .\tests\Run-Tests.ps1   (ou direto: . .\tests\Unit.Tests.ps1 dentro de um runner)
#>
$root   = Split-Path $PSScriptRoot -Parent
$skill  = Join-Path $root 'skills\firebird-recovery'
. (Join-Path $skill 'scripts\_FirebirdCommon.ps1')
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fbrec-unit-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

function New-FakeDb([string]$Path, [int]$RealPageSize, [int]$ClaimedPageSize, [switch]$NoChecksum, [switch]$BadPip){
  # pagina 0 (header) + pagina 1 (PIP, tipo 2) + pagina 2 (TIP, tipo 3) + pagina 3 vazia
  $b = New-Object byte[] ($RealPageSize * 4)
  $b[0] = 1
  if(-not $NoChecksum){ $b[2] = 0x39; $b[3] = 0x30 }
  [BitConverter]::GetBytes([uint16]$ClaimedPageSize).CopyTo($b, 16)
  [BitConverter]::GetBytes([uint16]0x800B).CopyTo($b, 18)
  foreach($pg in @(@(1, 2), @(2, 3))){
    $off = $RealPageSize * $pg[0]
    if($BadPip -and $pg[0] -eq 1){ continue }
    $b[$off] = $pg[1]
    if(-not $NoChecksum){ $b[$off + 2] = 0x39; $b[$off + 3] = 0x30 }
  }
  [IO.File]::WriteAllBytes($Path, $b)
}

Write-Host "== Unit: header ==" -ForegroundColor Cyan
foreach($ps in 1024, 2048, 4096, 8192, 16384){
  Test-Case "Find-FbRealPageSize acha $ps com page_size corrompido" {
    $f = Join-Path $tmp "fake-$ps.fdb"
    New-FakeDb -Path $f -RealPageSize $ps -ClaimedPageSize ($ps -bor 0x8000)
    Assert-Equal $ps (Find-FbRealPageSize -Path $f) 'page_size real'
  }
}
Test-Case 'Find-FbRealPageSize usa a TIP quando a PIP esta destruida' {
  $f = Join-Path $tmp 'fake-badpip.fdb'
  New-FakeDb -Path $f -RealPageSize 8192 -ClaimedPageSize 49152 -BadPip
  Assert-Equal 8192 (Find-FbRealPageSize -Path $f) 'page_size real via TIP'
}
Test-Case 'Find-FbRealPageSize devolve 0 sem checksum (ODS 12+/nao-Firebird)' {
  $f = Join-Path $tmp 'fake-nochk.fdb'
  New-FakeDb -Path $f -RealPageSize 4096 -ClaimedPageSize 4096 -NoChecksum
  Assert-Equal 0 (Find-FbRealPageSize -Path $f) 'sem checksum'
}
Test-Case 'Read-FbBytes le offset e trata fim de arquivo' {
  $f = Join-Path $tmp 'bytes.bin'
  [IO.File]::WriteAllBytes($f, [byte[]](0..9))
  $b = Read-FbBytes -Path $f -Offset 8 -Count 4
  Assert-Equal 2 $b.Length 'tamanho lido no fim'
  Assert-Equal 8 $b[0] 'primeiro byte'
}

Write-Host "== Unit: gstat e dicas ==" -ForegroundColor Cyan
$gstatOk = @"

Database "C:\x\EMPLOYEE.FDB"
Database header page information:
	Flags			0
	Checksum		12345
	Generation		163
	Page size		4096
	ODS version		11.2
	Oldest transaction	154
	Oldest active		155
	Oldest snapshot		155
	Next transaction	155
	Bumped transaction	1
	Sequence number		0
	Page buffers		0
	Database dialect	3
	Attributes		force write

    Variable header data:
	Sweep interval:		15000
	*END*
"@
Test-Case 'ConvertFrom-FbGstatHeader le os campos' {
  $h = ConvertFrom-FbGstatHeader -Text $gstatOk -Exit 0
  Assert-True $h.Ok 'Ok'
  Assert-Equal 4096 $h.PageSize 'PageSize'
  Assert-Equal '11.2' $h.OdsVersion 'ODS'
  Assert-Equal 3 $h.Dialect 'dialect'
  Assert-Equal 154 $h.OldestTransaction 'OIT'
  Assert-Equal 155 $h.NextTransaction 'Next'
  Assert-Equal 15000 $h.SweepInterval 'sweep'
  Assert-True $h.ForcedWrites 'forced writes'
  Assert-Equal 'none' $h.Shutdown 'shutdown'
}
Test-Case 'ConvertFrom-FbGstatHeader reconhece shutdown e forced writes desligado' {
  $h1 = ConvertFrom-FbGstatHeader -Text ($gstatOk -replace 'force write', 'force write, single-user maintenance') -Exit 0
  Assert-Equal 'single' $h1.Shutdown 'single'
  $h2 = ConvertFrom-FbGstatHeader -Text ($gstatOk -replace 'force write', 'force write, full shutdown') -Exit 0
  Assert-Equal 'full' $h2.Shutdown 'full'
  $h3 = ConvertFrom-FbGstatHeader -Text ($gstatOk -replace 'Attributes\t\tforce write', 'Attributes') -Exit 0
  Assert-True (-not $h3.ForcedWrites) 'sem force write'
  $h4 = ConvertFrom-FbGstatHeader -Text ($gstatOk -replace 'force write', 'force write, backup lock') -Exit 0
  Assert-True $h4.BackupLock 'backup lock'
}
Test-Case 'ConvertFrom-FbGstatHeader: gstat que falhou nao e Ok' {
  $h = ConvertFrom-FbGstatHeader -Text 'unable to allocate memory from operating system' -Exit 1
  Assert-True (-not $h.Ok) 'nao Ok'
}
Test-Case 'Get-FbHeaderHints: forced writes, limite de transacoes, OIT parado' {
  $base = ConvertFrom-FbGstatHeader -Text $gstatOk -Exit 0
  Assert-Equal 0 @(Get-FbHeaderHints -Info $base).Count 'banco sadio sem dicas'
  $fw = ConvertFrom-FbGstatHeader -Text ($gstatOk -replace 'Attributes\t\tforce write', 'Attributes') -Exit 0
  Assert-Match ((Get-FbHeaderHints -Info $fw).Texto -join ' ') 'forced writes' 'dica de forced writes'
  $alto = ConvertFrom-FbGstatHeader -Text ($gstatOk -replace 'Next transaction\t155', 'Next transaction	1800000000' -replace 'Oldest transaction\t154', 'Oldest transaction	1799999990') -Exit 0
  Assert-Equal 'FALHA' (@(Get-FbHeaderHints -Info $alto)[0].Nivel) '>= 80% do limite'
  $gap = ConvertFrom-FbGstatHeader -Text ($gstatOk -replace 'Next transaction\t155', 'Next transaction	900000') -Exit 0
  Assert-Match ((Get-FbHeaderHints -Info $gap).Texto -join ' ') 'Next - OIT' 'OIT parado'
}

Write-Host "== Unit: classificacao de erros ==" -ForegroundColor Cyan
Test-Case 'Test-FbCorruptionError aceita dano fisico' {
  foreach($m in @('database file appears corrupt (X)', 'wrong page type', 'page 245 is of wrong type (expected 5, found 0)',
                  'checksum error on database page 10', 'internal Firebird consistency check (cannot find tip page)',
                  'I/O error during "ReadFile" operation for file "X"')){
    Assert-True (Test-FbCorruptionError $m) $m
  }
}
Test-Case 'Test-FbCorruptionError recusa erro que nao e de pagina' {
  foreach($m in @('Column unknown', 'Your user name and password are not defined',
                  'violation of PRIMARY or UNIQUE KEY constraint "PK_X" on table "X"',
                  'I/O error during "CreateFile (open)" operation for file "X"', 'Token unknown - line 1, column 5')){
    Assert-True (-not (Test-FbCorruptionError $m)) $m
  }
}

Test-Case 'Get-FbErrorSummary tira o ruido do isql e do EDS' {
  $eds = @('C', '====', 'Statement failed, SQLSTATE = 42000', 'Execute statement error at isc_dsql_fetch :',
           '335544335 : database file appears corrupt ()', '335544649 : bad checksum', '335544405 : checksum error on database page 750',
           "Statement : SELECT X FROM T WHERE K > 'A' ROWS 1", 'Data source : Firebird::C:\x\ORIGEM.FDB', '-At block line: 3, col: 3',
           'After line 1 in file C:\tmp\fbrec-1.sql')
  Assert-Equal 'database file appears corrupt () | bad checksum | checksum error on database page 750' (Get-FbErrorSummary $eds) 'EDS'
  $direto = @('Statement failed, SQLSTATE = XX001', 'database file appears corrupt ()', '-wrong page type',
              '-page 245 is of wrong type (expected 5, found 0)', 'After line 2 in file C:\tmp\x.sql')
  Assert-Equal 'database file appears corrupt () | wrong page type | page 245 is of wrong type (expected 5, found 0)' (Get-FbErrorSummary $direto) 'isql direto'
  Assert-Equal 'a | b' (Get-FbErrorSummary @('a', '', 'b') -Max 3) 'sem cabecalho: ultimas linhas'
}

Write-Host "== Unit: validacao online (fbsvcmgr) ==" -ForegroundColor Cyan
$valOk = @('10:00:00.01 Validation started', '', '10:00:00.02 Relation 128 (TABELA_A)', '10:00:00.02   process pointer page    0 of    1',
           '10:00:00.02 Index 1 (PK_TABELA_A)', '10:00:00.03 Relation 128 (TABELA_A) is ok', '',
           '10:00:00.03 Relation 129 (TABELA_B)', '10:00:00.04 Relation 129 (TABELA_B) is ok', '', '10:00:00.05 Validation finished')
Test-Case 'ConvertFrom-FbOnlineValidation: validacao limpa' {
  $p = ConvertFrom-FbOnlineValidation -Lines $valOk -Exit 0
  Assert-True (-not $p.Aborted) 'nao abortou'
  Assert-Equal 2 $p.TablesOk 'tabelas ok'
  Assert-Equal 0 $p.TablesWithErrors.Count 'sem erros'
}
Test-Case 'ConvertFrom-FbOnlineValidation: tabela com ERRORS found' {
  $l = $valOk[0..6] + @('10:00:00.03 Relation 129 (TABELA_B)', '10:00:00.04 Relation 129 (TABELA_B) : 3 ERRORS found', '', '10:00:00.05 Validation finished')
  $p = ConvertFrom-FbOnlineValidation -Lines $l -Exit 0
  Assert-True (-not $p.Aborted) 'erro de registro nao aborta'
  Assert-Equal 'TABELA_B (3 erros)' ($p.TablesWithErrors -join ';') 'tabela com erro'
}
Test-Case 'ConvertFrom-FbOnlineValidation: pagina ilegivel aborta (com e sem Validation finished)' {
  # formato real: a relacao comeca, o servico falha e o resto da saida se perde
  $a = $valOk[0..6] + @('10:00:00.03 Relation 130 (TABELA_C)', '10:00:00.03   process pointer page    0 of   47', '10:00:00.04 Validation finished',
                         'database file appears corrupt ()', '-bad checksum', '-checksum error on database page 1130571')
  $p = ConvertFrom-FbOnlineValidation -Lines $a -Exit 0
  Assert-True $p.Aborted 'abortou mesmo com Validation finished'
  Assert-Equal 1130571 @($p.BadPages)[0] 'pagina do erro'
  Assert-Equal 'TABELA_C' $p.LastRelation 'ultima relacao no log'
  Assert-Match $p.ErrorText 'checksum error on database page 1130571' 'mensagem'
  $b = $valOk[0..6] + @('10:00:00.03 Relation 130 (TABELA_C)', '10:00:00.03 Index 1 (PK_TABELA_C)',
                         'database file appears corrupt ()', '-bad checksum', '-checksum error on database page 245')
  $q = ConvertFrom-FbOnlineValidation -Lines $b -Exit 1
  Assert-True ($q.Aborted -and -not $q.Finished) 'abortou sem Validation finished'
  Assert-Equal 245 @($q.BadPages)[0] 'pagina do erro (saida cortada)'
}
Test-Case 'ConvertTo-FbSimilarLiteral escapa os curingas do SIMILAR TO' {
  Assert-Equal 'TABELA[_]A' (ConvertTo-FbSimilarLiteral 'TABELA_A') 'underscore'
  Assert-Equal 'X[%]Y' (ConvertTo-FbSimilarLiteral 'X%Y') 'percent'
  Assert-Equal 'ABC$1' (ConvertTo-FbSimilarLiteral 'ABC$1') 'cifrao e digitos'
}

Write-Host "== Unit: execucao de .exe ==" -ForegroundColor Cyan
Test-Case 'Invoke-FbNative captura stdout+stderr e exit code sem lancar excecao' {
  $ErrorActionPreference = 'Stop'
  $r = Invoke-FbNative -Exe 'cmd.exe' -Arguments @('/c', 'echo saida & echo erro 1>&2 & exit 3')
  Assert-Equal 3 $r.Exit 'exit code'
  Assert-Match $r.Text 'saida' 'stdout'
  Assert-Match $r.Text 'erro' 'stderr'
}
Test-Case 'Invoke-FbNative passa credenciais pelo ambiente e restaura' {
  $antes = @($env:ISC_USER, $env:ISC_PASSWORD)
  try {
    $env:ISC_USER = 'ANTERIOR'; $env:ISC_PASSWORD = $null
    $r = Invoke-FbNative -Exe 'cmd.exe' -Arguments @('/c', 'echo %ISC_USER%/%ISC_PASSWORD%') -User 'USUARIO_X' -Password 'SENHA_Y'
    Assert-Match $r.Text 'USUARIO_X/SENHA_Y' 'variaveis no filho'
    Assert-True ($env:ISC_USER -eq 'ANTERIOR' -and $null -eq $env:ISC_PASSWORD) 'ambiente restaurado'
  } finally { $env:ISC_USER = $antes[0]; $env:ISC_PASSWORD = $antes[1] }
}

Write-Host "== Unit: ferramentas do repositorio ==" -ForegroundColor Cyan
Test-Case 'Test-Repository passa no repositorio' {
  $r = Invoke-Script -Path (Join-Path $root 'tools\Test-Repository.ps1')
  Assert-Equal 0 $r.Exit ($r.Text -split "`n" | Select-Object -Last 3)
}
Test-Case 'Build-SkillPackage gera o zip com a pasta da skill na raiz e sem evals' {
  $out = Join-Path $tmp 'pkg'
  $r = Invoke-Script -Path (Join-Path $root 'tools\Build-SkillPackage.ps1') -Arguments @('-OutDir', $out)
  Assert-Equal 0 $r.Exit $r.Text
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $z = [IO.Compression.ZipFile]::OpenRead((Join-Path $out 'firebird-recovery.skill'))
  try { $names = @($z.Entries | ForEach-Object FullName) } finally { $z.Dispose() }
  Assert-True ($names -contains 'firebird-recovery/SKILL.md') 'SKILL.md na raiz da pasta'
  Assert-True (-not ($names -match '/evals/')) 'sem evals'
}
Test-Case 'Build-SkillPackage recusa frontmatter invalido' {
  $bad = Join-Path $tmp 'bad\firebird-recovery'
  New-Item -ItemType Directory -Force -Path $bad | Out-Null
  [IO.File]::WriteAllText((Join-Path $bad 'SKILL.md'), "---`nname: firebird-recovery`ndescription: texto com dois pontos: quebra o YAML`nchave_inventada: x`n---`n# x`n")
  $r = Invoke-Script -Path (Join-Path $root 'tools\Build-SkillPackage.ps1') -Arguments @('-SkillDir', $bad, '-OutDir', (Join-Path $tmp 'badout'))
  Assert-Equal 1 $r.Exit 'exit'
  Assert-Match $r.Text 'chave_inventada' 'chave nao permitida'
}
Test-Case 'Test-SensitiveTerms pega caminho de perfil e respeita a lista local' {
  $g = Join-Path $tmp 'repo-sens'
  New-Item -ItemType Directory -Force -Path $g | Out-Null
  & git -C $g init -q 2>$null
  # montado em partes para este arquivo nao disparar a propria checagem
  [IO.File]::WriteAllText((Join-Path $g 'a.md'), ('caminho C:\' + 'Users\fulano\banco.fdb'))
  $r = Invoke-Script -Path (Join-Path $root 'tools\Test-SensitiveTerms.ps1') -Arguments @('-Root', $g)
  Assert-Equal 1 $r.Exit 'caminho de perfil'
  [IO.File]::WriteAllText((Join-Path $g 'a.md'), 'caminho C:\Users\<usuario>\banco.fdb e cliente ACME')
  $r2 = Invoke-Script -Path (Join-Path $root 'tools\Test-SensitiveTerms.ps1') -Arguments @('-Root', $g)
  Assert-Equal 0 $r2.Exit 'placeholder permitido'
  [IO.File]::WriteAllText((Join-Path $g '.git\info\sensitive-terms.txt'), "(?i)acme`n")
  $r3 = Invoke-Script -Path (Join-Path $root 'tools\Test-SensitiveTerms.ps1') -Arguments @('-Root', $g)
  Assert-Equal 1 $r3.Exit 'termo da lista local'
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
