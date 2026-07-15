# Layout do cabeçalho — ODS 11.2 (Firebird 2.5)

Página 0 de qualquer banco Firebird 2.5. Tamanho = `page_size` do banco (tipicamente 8192 ou 16384). Os campos abaixo estão nos primeiros bytes; o resto da página é variable header data + zeros.

Use esta referência **só** quando for fazer leitura/edição binária direta (procedure 03 seção 5). Para corrupções triviais (page_size), os scripts já tratam.

## Cabeçalho da página (struct `pag`) — offsets 0x00 a 0x0F

Todo página Firebird começa com 16 bytes neste formato:

| Offset | Tamanho | Campo | Tipo | Valor esperado |
|---|---|---|---|---|
| `0x00` | 1 | `pag_type` | SCHAR | `0x01` para página 0 (header). Outros tipos: 2=PIP, 3=TIP, 4=pointer, 5=data, 6=index root, 7=index B-tree, 8=blob, 9=generator, 10=SCN |
| `0x01` | 1 | `pag_flags` | SCHAR | normalmente 0 |
| `0x02` | 2 | `pag_checksum` | USHORT (LE) | **`0x3039` = 12345** (constante; serve como assinatura) |
| `0x04` | 4 | `pag_generation` | ULONG (LE) | número da geração da página |
| `0x08` | 4 | `pag_scn` | ULONG (LE) | SCN da página |
| `0x0C` | 4 | `pag_pageno` / reserved | ULONG (LE) | número da página (validação interna) |

**Por que isso importa para diagnóstico:** o checksum `12345` (`0x3039`) é a "impressão digital" do Firebird. Ao escanear bytes para descobrir o `page_size` real, o script procura este valor nos offsets candidatos.

## Header page (struct `header_page`) — começa em 0x10

Após os 16 bytes do `pag`, os campos do header propriamente dito:

| Offset | Tamanho | Campo | Tipo | Significado |
|---|---|---|---|---|
| `0x10` | 2 | `hdr_page_size` | USHORT (LE) | **page_size do banco**. Valores válidos FB 2.5: 1024, 2048, 4096, 8192, 16384 |
| `0x12` | 2 | `hdr_ods_version` | USHORT (LE) | versão ODS. FB 2.5 = `0x800B` (alto bit 0x8000 = ODS Firebird; baixos `0x0B`=11) |
| `0x14` | 4 | `hdr_PAGES` | SLONG (LE) | pageno do pointer page de `RDB$PAGES` (catálogo). Tipicamente 3 |
| `0x18` | 4 | `hdr_next_page` | ULONG (LE) | próxima header page (se header for multi-página) |
| `0x1C` | 4 | `hdr_oldest_transaction` | SLONG (LE) | OAT — oldest interesting transaction |
| `0x20` | 4 | `hdr_oldest_active` | SLONG (LE) | OAT ativa |
| `0x24` | 4 | `hdr_next_transaction` | SLONG (LE) | próximo TID |
| `0x28` | 2 | `hdr_sequence` | USHORT (LE) | número da sequência do arquivo (multi-file DB) |
| `0x2A` | 2 | `hdr_flags` | USHORT (LE) | flags do banco — ver tabela abaixo |
| `0x2C` | 8 | `hdr_creation_date[2]` | SLONG[2] | data/hora de criação (formato `isc_timestamp`) |
| `0x34` | 4 | `hdr_attachment_id` | SLONG | próximo attachment ID |
| `0x38` | 4 | `hdr_shadow_count` | SLONG | número de shadows ativos |
| `0x3C` | 1 | `hdr_implementation` | UCHAR | número de implementação |
| `0x3D` | 1 | `hdr_ods_minor` | UCHAR | versão menor de ODS (2 em FB 2.5) |
| `0x3E` | 1 | `hdr_ods_minor_original` | UCHAR | versão menor original |
| `0x3F` | 2 | `hdr_end` | USHORT (LE) | offset onde termina o header |
| ... | | (variable header data segue) | | sweep interval, dialect, file name etc. — formato CLUMPLET |

## hdr_flags (offset 0x2A) — valores

| Valor | Significado |
|---|---|
| `0x0000` | normal |
| `0x0001` | `hdr_active_shadow` |
| `0x0002` | `hdr_force_write` (FW=ON) |
| `0x0008` | `hdr_no_reserve` (USE_ALL_SPACE) |
| `0x0040` | `hdr_shutdown_mode` (mode shutdown) |
| `0x0100` | `hdr_read_only` (banco read-only) |
| `0x0200` | `hdr_backup_lock` |

Combinações são possíveis (OR).

## Como ler em PowerShell

```powershell
$f = "C:\path\BANCO.FDB"
$fs = [IO.File]::Open($f,'Open','Read',[IO.FileShare]::ReadWrite)
$b = New-Object byte[] 64
[void]$fs.Seek(0,'Begin'); [void]$fs.Read($b,0,64); $fs.Close()

# pag_type
"pag_type = 0x{0:X2}" -f $b[0]
# checksum (esperado 12345)
"checksum = {0}" -f ([BitConverter]::ToUInt16($b,2))
# page_size (offset 0x10)
"page_size = {0}" -f ([BitConverter]::ToUInt16($b,16))
# ods version (offset 0x12)
"ods = 0x{0:X4}" -f ([BitConverter]::ToUInt16($b,18))
# flags (offset 0x2A)
"flags = 0x{0:X4}" -f ([BitConverter]::ToUInt16($b,42))
```

## Endianness

Tudo little-endian no header do Firebird em arquiteturas x86/x64 (Windows, Linux). USHORT/SLONG são lidos com `BitConverter.ToUInt16`/`ToInt32` direto.

## Referência cruzada

- Código-fonte do Firebird 2.5: `src/jrd/ods.h` (definições oficiais).
- Para investigação mais profunda de páginas internas: `references/codigos-erro-firebird.md` lista os pag_types e suas estruturas.

## Cuidado

Editar campos do header é **destrutivo** se errado. Sempre:
1. Crie sidecar com o valor original (`.<campo>bak`).
2. Opere em **cópia** do banco, nunca no original.
3. Após editar, valide com `gstat -h` antes de qualquer outra operação.
