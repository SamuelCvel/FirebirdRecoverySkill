# Layout do cabeçalho — ODS 11.2 (Firebird 2.5)

Página 0 de qualquer banco Firebird 2.5. Os offsets abaixo foram **medidos** no banco de exemplo `examples\empbuild\EMPLOYEE.FDB` do Firebird 2.5.9 e cruzados com `gstat -h`. Os bits de `hdr_flags` foram medidos aplicando cada `gfix`/`nbackup` numa cópia descartável.

Use esta referência **só** quando for fazer leitura/edição binária direta (procedure 03 seção 5). Para o caso clássico (page_size), os scripts já tratam.

## Sumário

1. [Cabeçalho comum de página (`pag`)](#cabeçalho-comum-de-página-pag--0x00-a-0x0f)
2. [Header page (`header_page`)](#header-page-header_page--a-partir-de-0x10)
3. [`hdr_flags` (0x2A)](#hdr_flags-0x2a--bits-verificados)
4. [O que o engine confere ao abrir](#o-que-o-engine-25-confere-ao-abrir-o-arquivo)
5. [Diferenças no ODS 12/13 (FB 3+)](#diferenças-no-ods-1213-firebird-3-4-e-5)
6. [Como ler em PowerShell](#como-ler-em-powershell)
7. [Cuidado](#cuidado)

## Cabeçalho comum de página (`pag`) — 0x00 a 0x0F

Toda página Firebird começa com 16 bytes neste formato:

| Offset | Tamanho | Campo | Valor esperado / observação |
|---|---|---|---|
| `0x00` | 1 | `pag_type` | `0x01` na página 0. Tipos: 1 header, 2 PIP, 3 TIP, 4 pointer, 5 data, 6 index root, 7 index B-tree, 8 blob, 9 generators, 10 log (obsoleto no 2.5) |
| `0x01` | 1 | `pag_flags` | normalmente 0 — é a linha **`Flags`** do `gstat -h` |
| `0x02` | 2 | `pag_checksum` | **`0x3039` = 12345** (constante em toda página ODS 11). O FB 2.5 no Windows confere em **toda leitura** (`checksum error on database page N`), a menos que se use `gfix -ignore` / `gbak -ignore` |
| `0x04` | 4 | `pag_generation` | linha `Generation` do gstat |
| `0x08` | 4 | `pag_scn` | usado pelo nbackup |
| `0x0C` | 4 | reservado | (no ODS 12+ guarda o número da página) |

**Por que isso importa para diagnóstico:** o `12345` é a "impressão digital" de página ODS 11. Para descobrir o `page_size` real, o script procura a página 1 (PIP, `pag_type = 2`) com esse checksum nos offsets candidatos.

## Header page (`header_page`) — a partir de 0x10

| Offset | Tamanho | Campo | Linha do `gstat -h` / observação |
|---|---|---|---|
| `0x10` | 2 | `hdr_page_size` | `Page size`. Válidos: 1024, 2048, 4096, 8192, 16384 |
| `0x12` | 2 | `hdr_ods_version` | `ODS version` (maior). `0x800B` = 11 com o bit Firebird `0x8000`. ODS 12 = `0x800C`, ODS 13 = `0x800D` |
| `0x14` | 4 | `hdr_PAGES` | 1º pointer page de `RDB$PAGES` (tipicamente 3) |
| `0x18` | 4 | `hdr_next_page` | `Next header page` (banco multi-arquivo); normalmente 0 |
| `0x1C` | 4 | `hdr_oldest_transaction` | `Oldest transaction` (**OIT**) |
| `0x20` | 4 | `hdr_oldest_active` | `Oldest active` (**OAT**) |
| `0x24` | 4 | `hdr_next_transaction` | `Next transaction` — limite do 2.5: 2.147.483.647 (2³¹−1) |
| `0x28` | 2 | `hdr_sequence` | `Sequence number` — **tem que ser 0** na página 0 |
| `0x2A` | 2 | `hdr_flags` | decodificado em `Attributes` e `Database dialect` (tabela abaixo) |
| `0x2C` | 8 | `hdr_creation_date` | `Creation date` (ISC_TIMESTAMP: dias desde 17/11/1858 + décimos de milésimo de segundo) |
| `0x34` | 4 | `hdr_attachment_id` | `Next attachment ID` |
| `0x38` | 4 | `hdr_shadow_count` | `Shadow count` |
| `0x3C` | 2 | `hdr_implementation` | `Implementation ID` — precisa ser compatível com a plataforma |
| `0x3E` | 2 | `hdr_ods_minor` | parte menor do ODS (`2` no FB 2.5 → "11.2") |
| `0x40` | 2 | `hdr_ods_minor_original` | ODS menor da criação |
| `0x42` | 2 | `hdr_end` | fim dos dados variáveis (`0x60` = 96 quando não há nenhum) |
| `0x44` | 4 | `hdr_page_buffers` | `Page buffers` (0 = usa o `firebird.conf`) |
| `0x48` | 4 | `hdr_bumped_transaction` | `Bumped transaction` |
| `0x4C` | 4 | `hdr_oldest_snapshot` | `Oldest snapshot` (**OST**) |
| `0x50` | 4 | `hdr_backup_pages` | uso do nbackup |
| `0x54` | 12 | `hdr_misc[3]` | reservado |
| `0x60` | variável | `hdr_data` | "clumplets": `Variable header data` do gstat (ex.: `Sweep interval`, arquivos secundários), até `hdr_end` |

## `hdr_flags` (0x2A) — bits verificados

| Bit | Significado | Aparece no `gstat -h` como | Como liga/desliga |
|---|---|---|---|
| `0x0001` | arquivo é shadow ativo | — | shadows |
| `0x0002` | **forced writes** | `Attributes: force write` | `gfix -write sync` / `async` |
| `0x0020` | não reserva espaço para versões | `Attributes: no reserve` | `gfix -use full` / `reserve` |
| `0x0080` | shutdown **multi** | `multi-user maintenance` | `gfix -shut [multi] -force 0` |
| `0x0100` | **SQL dialect 3** (ausente = dialect 1) | `Database dialect 3` | definido na criação |
| `0x0200` | read-only | `Attributes: read only` | `gfix -mode read_only` / `read_write` |
| `0x0400` | nbackup: arquivo travado | `Attributes: backup lock` | `nbackup -L` / `-N` (na cópia: `-F`) |
| `0x0800` | nbackup: mesclando delta | — | durante o `nbackup -N` |
| `0x1000` | shutdown **full** | `full shutdown` | `gfix -shut full -force 0` |
| `0x1080` | shutdown **single** (`0x1000` + `0x0080`) | `single-user maintenance` | `gfix -shut single -force 0` |

- **Máscara de shutdown = `0x1080`.** Para tirar um banco de shutdown, o caminho normal é `gfix -online`; nunca zere o campo inteiro.
- **Valor sadio típico de produção: `0x0102`** (forced writes + dialect 3). Zerar o campo transforma o banco em **dialect 1** e desliga forced writes — quebra a aplicação.
- Combinações são possíveis (OR): `0x1182` = single-user maintenance + dialect 3 + forced writes.

## O que o engine 2.5 confere ao abrir o arquivo

| Condição | Erro se falhar |
|---|---|
| `pag_type = 1` e `hdr_sequence = 0` | `not a valid database` |
| ODS entre 11.0 e 11.2 | `unsupported on-disk structure` |
| `hdr_implementation` compatível com a plataforma | erro de estrutura incompatível ao atachar |
| `hdr_page_size` entre 1024 e 16384 (o engine não checa potência de 2) | fora da faixa, nenhuma ferramenta atacha e o `gstat -h` falha (ex.: `unable to allocate memory from operating system`) |

## Diferenças no ODS 12/13 (Firebird 3, 4 e 5)

Esta skill é para ODS 11. Num banco FB 3+:

- o campo de checksum (`0x02`) **não é usado** → a varredura por `12345` não encontra nada;
- `0x0C` guarda o número da página;
- `0x3C`–`0x3F` são 4 bytes (cpu, os, cc, compat); o ODS menor fica em `0x40`;
- `0x48` = OST, `0x4C` = backup pages, `0x50` = página de criptografia; clumplets começam em `0x80`;
- contadores de transação são de 48 bits.

`page_size` (`0x10`), ODS maior (`0x12`), `hdr_PAGES`/OIT/OAT/Next (`0x14`–`0x24`) e `hdr_flags` (`0x2A`) ficam nos mesmos lugares.

## Como ler em PowerShell

```powershell
$f  = "C:\path\BANCO.FDB"
$fs = [IO.File]::Open($f,'Open','Read',[IO.FileShare]::ReadWrite)
try { $b = New-Object byte[] 96; [void]$fs.Read($b,0,96) } finally { $fs.Dispose() }

"pag_type   = 0x{0:X2}"  -f $b[0]                                   # 0x01
"checksum   = {0}"       -f [BitConverter]::ToUInt16($b,2)          # 12345
"page_size  = {0}"       -f [BitConverter]::ToUInt16($b,16)
"ods        = 0x{0:X4}.{1}" -f [BitConverter]::ToUInt16($b,18), [BitConverter]::ToUInt16($b,62)   # 0x800B.2
"OIT/OAT/Next = {0} / {1} / {2}" -f [BitConverter]::ToInt32($b,28), [BitConverter]::ToInt32($b,32), [BitConverter]::ToInt32($b,36)
"sequence   = {0}"       -f [BitConverter]::ToUInt16($b,40)         # 0
"hdr_flags  = 0x{0:X4}"  -f [BitConverter]::ToUInt16($b,42)         # 0x0102 típico
"tamanho % page_size = {0}" -f ((Get-Item $f).Length % [BitConverter]::ToUInt16($b,16))   # 0 = sem truncamento
```

Tudo é little-endian em x86/x64 (Windows e Linux).

## Cuidado

Editar campos do header é **destrutivo** se errado. Sempre:

1. Crie sidecar com o valor original (`.<campo>bak`).
2. Opere em **cópia** do banco, nunca no original.
3. Preserve os bits que você não pretende mudar (ver `hdr_flags`).
4. Após editar, valide com `gstat -h` antes de qualquer outra operação.

Fonte oficial: `src/jrd/ods.h` do Firebird 2.5 (branch `B2_5_Release`).
