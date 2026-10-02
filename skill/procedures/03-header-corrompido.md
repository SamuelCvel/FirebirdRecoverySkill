# 03 — Header corrompido

**Sintoma característico:** `gstat -h` retorna `unable to allocate memory from operating system`. Nenhuma ferramenta (`gfix`, `gbak`, `isql`) consegue atachar. O arquivo existe e tem o tamanho esperado.

**Causa subjacente:** o campo `page_size` (offset `0x10`, 2 bytes, little-endian) da página 0 (header) está com um valor inválido — tipicamente um bit invertido por queda de energia, setor defeituoso ou RAM com erro. Em FB 2.5 o page_size válido é 1024, 2048, 4096, 8192 ou 16384.

Um caso real teve: byte `0x11` lido como `0xC0` em vez de `0x40` (bit `0x80` ligado indevidamente). page_size virou `0xC000` (49152), inválido → tools abortam.

> `<SKILL>` nos comandos abaixo = pasta da skill (informada no SKILL.md). `<cópia>` = cópia de trabalho criada na procedure 02.

## Sumário

1. [Diagnóstico](#1-diagnóstico-somente-leitura)
2. [Reparo](#2-reparo-reversível)
3. [Validação completa](#3-validação-completa)
4. [Reverter](#4-reverter-se-o-reparo-piorou-alguma-coisa)
5. [Quando vai além do page_size](#5-quando-vai-além-do-page_size)
6. [Observações finais](#6-observações-finais)

## Pré-requisitos

- **Procedure 02 já executada** (cópia + sidecar + isolamento).
- A cópia de trabalho deve abrir em modo exclusivo (FileShare.None).

## 1. Diagnóstico (somente leitura)

```powershell
& "<SKILL>\scripts\Diagnose-FirebirdHeader.ps1" -Database "<cópia>"
```

Saída esperada para corrupção de page_size:

```
  page_size no header : 49152   (bytes 0x00 0xC0)   ← lido do header
  -> INVALIDO
  page_size REAL (varredura) : 16384                ← detectado via PIP em offset 16384
  gstat -h: unable to allocate memory from operating system
  >> SINTOMA classico de header corrompido.
  >> Correcao: gravar page_size=16384 (bytes 0x00 0x40) no offset 0x10.
```

A linha "page_size REAL (varredura)" vem de uma técnica importante: toda página ODS 11 tem o checksum constante `0x3039` (12345) no offset 2. O script lê o começo da página 1 (PIP) em cada page_size candidato; o primeiro offset em que aparece uma página com esse checksum e `pag_type` válido **é** o page_size real.

> **Banco de Firebird 3+ (ODS 12/13)?** O ODS 12+ não tem mais esse checksum, então a varredura não encontra nada. Confira o ODS no offset `0x12` (`0x800C`/`0x800D`) antes de concluir que a corrupção é maior.

### O que olhar no resultado

| Caso | Decisão |
|---|---|
| page_size REAL detectado (1024/2048/4096/8192/16384) | tem alvo certo → siga para passo 2 (reparo) |
| page_size REAL não detectado | corrupção pode ser maior que só 1 byte; pule para a seção **5** |
| page_size REAL detectado mas é diferente do esperado pela aplicação | suspeite de arquivo errado (banco veio de outro deploy); confirme com o usuário antes de prosseguir |
| tamanho do arquivo não é múltiplo do page_size real | arquivo **truncado** (cópia interrompida, disco cheio) — o reparo do header não resolve o fim do arquivo; avise o usuário e siga com cuidado (procedure 04) |

## 2. Reparo (reversível)

```powershell
& "<SKILL>\scripts\Repair-FirebirdHeader.ps1" -Database "<cópia>"
```

O script:
1. Lê o `.hdrbak` (se existir) — fonte mais confiável.
2. Se não houver, usa o resultado do scan para determinar o page_size correto.
3. Sobrescreve os bytes `0x10` e `0x11` (low/high do USHORT little-endian).
4. Roda `gstat -h` para confirmar.

> Com o header corrompido o servidor **não consegue abrir** esse arquivo, então normalmente não é preciso isolar nada: a cópia de trabalho já abre em modo exclusivo. `-Isolate`/`-StopService` só servem se algum processo estiver segurando o arquivo.

Saída esperada de sucesso:

```
  page_size regravado: 16384 (bytes 0x00 0x40)
  gstat -h: Database header page information ... Page size: 16384 ...
  >> CORRIGIDO com sucesso.
```

### Fallback se Repair-FirebirdHeader falha

| Falha | Causa | Ação |
|---|---|---|
| "Não consegui abrir em modo exclusivo" | algum processo (servidor, antivírus, cópia) segura o arquivo | volte para procedure 02 seção 4 (detecção de lock) |
| "Não consegui determinar um page_size válido" | sidecar ausente E scan falhou | pule para seção **5** abaixo |
| `gstat -h` ainda falha depois do patch | corrupção em outro campo do header (ODS, sequence, flags) | seção **5** |

## 3. Validação completa

Mesmo com `gstat -h` lendo, valide as 4 lentes (procedure 08). Resumo:

```powershell
# Lente 2: gfix (exige acesso exclusivo — ninguém mais conectado na cópia)
& "C:\Program Files\Firebird\Firebird_2_5\bin\gfix.exe" -v -full -user SYSDBA -password <senha> "<cópia>"
# Exit 0 + sem output = OK

# Lente 3: gbak backup completo
& "<SKILL>\scripts\Salvage-Backup.ps1" -Database "<cópia>" -BackupFile "<basename>.salvage.fbk"
# Procurar "closing file, committing, and finishing" no log

# Lente 4: restore + contagens
& "<SKILL>\scripts\Restore-Clean.ps1" -BackupFile "<basename>.salvage.fbk" -TargetDatabase "<basename>.recuperado.fdb"
```

Se as 4 passam → siga para **procedure 08** (verificação de objetos/contagens e reintegração).

Se alguma falhar, o tipo de erro indica a próxima procedure (use a tabela de triagem do SKILL.md).

## 4. Reverter (se o reparo piorou alguma coisa)

```powershell
# Refazer a cópia de trabalho a partir do ORIGINAL (que foi preservado pela procedure 02)
Copy-Item -LiteralPath "<original>" -Destination "<cópia>" -Force
```

Como o original nunca foi tocado, voltar ao ponto zero é trivial. É exatamente por isso que a procedure 02 é obrigatória.

## 5. Quando vai além do page_size

Se o sintoma é igual mas o page_size **lido** parece válido, ou se o scan não encontra a página 1, a corrupção pegou outros campos. Layout completo em `references/ods11-header-layout.md`.

### 5.a) ODS version inválido (offset 0x12, USHORT)

Esperado em FB 2.5: `0x800B` (bytes `0B 80`), com ODS menor `2` no offset `0x3E`. Se virou outra coisa:

- Se a página 1 tem o checksum `12345` (toda página ODS 11 tem), o banco **é** ODS 11 → o patch é razoável: grave `0B 80` em `0x12-0x13` na cópia (com `.odsbak` antes!) e rode `gstat -h`.
- Se `0x12` mostra `0x800C`/`0x800D`, o banco é de **Firebird 3+**: não é corrupção, use as ferramentas da versão certa.
- Se nada bate, pare e considere backup mais antigo.

### 5.b) Flags do header (offset 0x2A, USHORT)

Bits relevantes (medidos no 2.5.9):

| Bit | Significado |
|---|---|
| `0x0002` | forced writes |
| `0x0020` | no reserve |
| `0x0080` / `0x1000` / `0x1080` | shutdown multi / full / single (máscara `0x1080`) |
| `0x0100` | **SQL dialect 3** |
| `0x0200` | read-only |
| `0x0400` / `0x0800` | estado do nbackup (lock / merge) |

Valor sadio típico: **`0x0102`** (forced writes + dialect 3).

> **Nunca zere o campo inteiro.** Isso transforma um banco dialect 3 em **dialect 1** e desliga forced writes — a aplicação quebra (aspas duplas, tipos DATE/NUMERIC mudam de semântica).

Se o banco atacha, saia de shutdown com `gfix -online` (não precisa de patch). Patch binário só quando o gfix não consegue atachar por causa de bits de shutdown/backup lixo — e **preservando** o resto:

```powershell
$f = "<cópia>"
$fs = [IO.File]::Open($f,'Open','ReadWrite',[IO.FileShare]::None)
try {
  $b = New-Object byte[] 2; [void]$fs.Seek(0x2A,'Begin'); [void]$fs.Read($b,0,2)
  $atual = [BitConverter]::ToUInt16($b,0)
  "FLAGS=0x{0:X4}" -f $atual | Set-Content -LiteralPath "$f.flagsbak" -Encoding ASCII   # sidecar ANTES
  $novo = $atual -band (-bnot 0x1C80) -band 0xFFFF     # limpa shutdown (0x1080) e estado do nbackup (0x0C00)
  $nb = [BitConverter]::GetBytes([uint16]$novo)
  [void]$fs.Seek(0x2A,'Begin'); $fs.Write($nb,0,2)
  "flags: 0x{0:X4} -> 0x{1:X4}" -f $atual, $novo
} finally { $fs.Dispose() }
```

Teste com `gstat -h`. Para limpar só o estado do nbackup numa **cópia**, o caminho oficial é `nbackup -F <cópia>`.

### 5.c) hdr_PAGES (offset 0x14, SLONG)

Aponta para o 1º pointer page de `RDB$PAGES`. Normalmente 3. Se virou aleatório, o engine não acha o catálogo.

Patch reversível: `.pagesbak`, gravar `03 00 00 00` no offset `0x14`. Se mesmo assim falhar, a corrupção é estrutural e o caminho é gbak/restore a partir de um backup.

### 5.d) hdr_sequence (offset 0x28, USHORT)

Tem que ser `0` na página 0; qualquer outro valor dá `not a valid database`. Patch reversível: `.seqbak`, gravar `00 00`.

### 5.e) Mais de um campo bagunçado

Provavelmente a página 0 inteira foi atingida (setor de disco ruim, página zerada por bug). Caminho:

1. Veja se existe backup `.fbk` recente (a primeira pergunta da entrevista).
2. Se sim: restaure direto do `.fbk`. Procedure 08 confirma resultado.
3. Se não: o engine precisa da página 0 para tudo — não há extração tabela-a-tabela sem header. Uma tentativa de alto risco é reconstruir a página 0 a partir de um banco "irmão" (mesmo page_size, mesma versão), campo a campo, numa cópia. **Pare e peça apoio** antes: isso é trabalho forense.

## 6. Observações finais

- O `force write` aparecendo em `Attributes` é o esperado em produção (configuração de I/O, não problema). A **ausência** dele é que merece alerta.
- Após o patch + restore, o banco resultante tem transações resetadas (próxima transação ~1). Isso é esperado: o `gbak -c` recria o catálogo de transações.
- Mantenha o original, a cópia patcheada, o `.fbk` e o restaurado **por pelo menos 30 dias** antes de descartar.
