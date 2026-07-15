# 03 — Header corrompido

**Sintoma característico:** `gstat -h` retorna `unable to allocate memory from operating system`. Nenhuma ferramenta (`gfix`, `gbak`, `isql`) consegue atachar. O arquivo existe e tem o tamanho esperado.

**Causa subjacente:** o campo `page_size` (offset `0x10`, 2 bytes, little-endian) da página 0 (header) está com um valor inválido — tipicamente um bit invertido por queda de energia, setor defeituoso ou RAM com erro. Em FB 2.5 o page_size válido é 1024, 2048, 4096, 8192 ou 16384.

Um caso real teve: byte `0x11` lido como `0xC0` em vez de `0x40` (bit `0x80` ligado indevidamente). page_size virou `0xC000` (49152), inválido → tools abortam.

## Pré-requisitos

- **Procedure 02 já executada** (cópia + sidecar + isolamento).
- A cópia de trabalho deve abrir em modo exclusivo (FileShare.None).

## 1. Diagnóstico (somente leitura)

```powershell
.\scripts\Diagnose-FirebirdHeader.ps1 -Database "<cópia>"
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

A linha "page_size REAL (varredura)" vem de uma técnica importante: o script tenta ler a página 1 (PIP) em cada candidate de page_size e procura o checksum `0x3039` (12345, constante do Firebird) e um `pag_type` válido (1-12). O primeiro offset que casa **é** o page_size real.

### O que olhar no resultado

| Caso | Decisão |
|---|---|
| page_size REAL detectado (1024/2048/4096/8192/16384) | tem alvo certo → siga para passo 2 (reparo) |
| page_size REAL não detectado | corrupção pode ser maior que só 1 byte; pule para a seção **5 - Quando vai além do page_size** |
| page_size REAL detectado mas é diferente do esperado pela aplicação | suspeite de aplicação errada (banco veio de outro deploy); confirme com o usuário antes de prosseguir |

## 2. Reparo (reversível)

```powershell
.\scripts\Repair-FirebirdHeader.ps1 -Database "<cópia>"
```

O script:
1. Lê o `.hdrbak` (se existir) — fonte mais confiável.
2. Se não houver, usa o resultado do scan para determinar o page_size correto.
3. Sobrescreve os bytes `0x10` e `0x11` (low/high do USHORT little-endian).
4. Roda `gstat -h` para confirmar.

Saída esperada de sucesso:

```
  page_size regravado: 16384 (bytes 0x00 0x40)
  gstat -h: Database header page information ... Page size: 16384 ...
  >> CORRIGIDO com sucesso.
```

### Fallback se Repair-FirebirdHeader falha

| Falha | Causa | Ação |
|---|---|---|
| "Não consegui abrir em modo exclusivo" | servidor ainda com o banco aberto | volte para procedure 02 seção 3 e isole/pare |
| "Não consegui determinar um page_size válido" | sidecar ausente E scan falhou | pule para seção **5** abaixo |
| `gstat -h` ainda falha depois do patch | corrupção em outro campo do header (ODS, hdr_PAGES, flags) | seção **5** |

## 3. Validação completa

Mesmo com `gstat -h` lendo, valide as 4 lentes:

```powershell
# Lente 2: gfix
& "C:\Program Files\Firebird\Firebird_2_5\bin\gfix.exe" -v -full -user SYSDBA -password masterkey "<cópia>"
# Exit 0 + sem output = OK

# Lente 3: gbak backup completo
.\scripts\Salvage-Backup.ps1 -Database "<cópia>" -BackupFile "<basename>.salvage.fbk"
# Procurar "closing file, committing, and finishing" no log

# Lente 4: restore + contagens
.\scripts\Restore-Clean.ps1 -BackupFile "<basename>.salvage.fbk" -TargetDatabase "<basename>.recuperado.fdb"
```

Se as 4 passam → siga para **procedure 08** (verificação de objetos/contagens e reintegração).

Se alguma falhar, o tipo de erro indica a próxima procedure (use a tabela de triagem do SKILL.md).

## 4. Reverter (se o reparo piorou alguma coisa)

```powershell
# 1) Apagar a cópia atual
Remove-Item -LiteralPath "<cópia>" -Force

# 2) Refazer a cópia a partir do ORIGINAL (que foi preservado pela procedure 02)
Copy-Item -LiteralPath "<original>" -Destination "<cópia>" -Force
```

Como o original nunca foi tocado, voltar ao ponto zero é trivial. É exatamente por isso que a procedure 02 é obrigatória.

## 5. Quando vai além do page_size

Se o sintoma é igual mas o page_size **lido** parece válido, ou se o scan não encontra page 1, então a corrupção pegou outros campos:

### 5.a) ODS version inválido (offset 0x12, USHORT)

Esperado em FB 2.5: `0x800B` (`0x0B`=11, alto bit set). Se virou outra coisa:

- Confira em `references/ods11-header-layout.md` o offset exato.
- Se o page_size está ok mas o ODS leu errado, *experimente* gravar `0x0B 0x80` em `0x12-0x13` na cópia (com `.odsbak` antes!). Depois `gstat -h`.
- Se o scan da página 1 confirma ODS 11 (pelo `hdr_ods_version` indireto), o patch é razoável. Senão, pare e considere backup mais antigo.

### 5.b) Flags do header (offset 0x2A, USHORT)

Valores comuns: 0 (normal), 0x100 (force write off), 0x80 (shutdown). Se virou um valor enorme, o gfix pode recusar atachar.

Patch reversível: leia, grave `.flagsbak`, e zere o campo (`0x00 0x00`). Teste `gstat -h`.

### 5.c) hdr_PAGES (offset 0x14, SLONG)

Aponta para o pointer page de `RDB$PAGES`. Normalmente 3. Se virou aleatório, gfix não acha o catálogo.

Patch reversível: `.pagesbak`, gravar `03 00 00 00` no offset `0x14`. Se mesmo assim falhar, a corrupção é estrutural e o caminho é gbak/restore a partir de um backup.

### 5.d) Mais de um campo bagunçado

Provavelmente a página 0 inteira foi atingida (setor de disco ruim, página zerada por bug). Caminho:

1. Veja se existe backup `.fbk` recente (a primeira pergunta da entrevista).
2. Se sim: restaure direto do `.fbk`. Procedure 08 confirma resultado.
3. Se não: tente reconstruir uma página 0 sintética a partir de uma página 0 de um banco "irmão" (mesmo schema, mesmo page_size) — risco alto, considere a procedure 06 (tabela-a-tabela) como alternativa: ela bypass o header inteiramente lendo o arquivo via outro caminho? **Não funciona em FB sem header — o engine precisa de page 0 para tudo.** Nesse cenário extremo, o ferramental é forense/manual (hex editor + cópia de campo a campo). Pare e peça apoio.

## 6. Observações finais

- O `force write` aparecendo em `Attributes` é normal (configuração de I/O, não problema).
- Após o patch + restore, o banco resultante tem transações resetadas (próxima transação ~1). Isso é esperado: o `gbak -c` recria o catálogo de transações.
- Mantenha o original, a cópia patcheada, o `.fbk` e o restaurado **por pelo menos 30 dias** antes de descartar.
