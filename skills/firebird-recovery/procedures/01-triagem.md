# 01 — Triagem

Use esta procedure **quando os sintomas estão ambíguos** ou o usuário só disse "o banco quebrou" sem detalhes. Objetivo: levantar dados suficientes em ≤ 5 minutos para escolher a procedure correta sem chutar.

A triagem nunca grava nada no banco — é toda leitura.

## 1. Entrevista (4 perguntas essenciais)

Faça nesta ordem; não pule:

1. **Qual o caminho completo do arquivo do banco?** (precisa do path absoluto, incluindo extensão real — `.fdb`, `.gdb`, `.ib`).
2. **Qual a mensagem de erro exata?** Peça a frase completa, com aspas. Vagueza ("não abre") atrasa a triagem.
3. **Quando começou e o que aconteceu antes?** (queda de energia? backup mal feito? cópia com o serviço ligado? upgrade? disco cheio?). A causa do incidente orienta o tipo de corrupção esperado.
4. **Existe backup recente?** Se sim, em que data e onde está. Saber disso **antes** muda o apetite por risco.

Se o usuário não souber alguma, prossiga mesmo assim — a leitura do header (passo 2) geralmente esclarece. Para a pergunta 3, o `Get-FirebirdEnvironmentReport.ps1` levanta as evidências sozinho (desligamentos inesperados, erros de disco, forced writes, banco em rede).

> **O banco funciona e o pedido é só validar?** Não precisa de triagem: rode o `Test-FirebirdHealth.ps1` (procedure 08) — com `-SnapshotCopy` se houver usuários conectados.

## 2. Leitura inicial segura

Rode o diagnóstico **somente leitura**:

```powershell
& "<SKILL>\scripts\Diagnose-FirebirdHeader.ps1" -Database "<caminho>"
```

(`<SKILL>` = pasta da skill, informada no SKILL.md.)

Saída esperada (interpretação):

| O que aparece | Significa | Vá para |
|---|---|---|
| `page_size: 16384` válido + gstat lê tudo | header ok, problema é em outro lugar | passo 3 (descer ao gfix) |
| `page_size: inválido` + gstat `unable to allocate memory` | header com page_size corrompido | **procedure 03** |
| `ODS version` lê algo absurdo (0, 65535) | header destruído / arquivo não é FB | **procedure 03** + considerar restauração por backup |
| `ODS version` 12 ou 13 (`0x800C`/`0x800D`) | banco de **Firebird 3+**, não de 2.5 | use as ferramentas da versão certa — esta skill é para ODS 11 |
| `Attributes` com `shutdown` / `maintenance` / `read only` / `backup lock` | estado do banco, não corrupção | **procedure 02** seção 3 (ou `gfix -online`) |
| `Attributes` **sem** `force write` | forced writes desligado — principal causa de corrupção depois de queda de energia | anote como causa provável; seguir o diagnóstico |
| tamanho do arquivo não é múltiplo do page_size | arquivo **truncado** (cópia interrompida, disco cheio) | **procedure 04** (o fim do arquivo vai dar `I/O error`/EOF) |
| `I/O error` ao ler o header | disco/setor ruim | **procedure 02** (hardware) → tentar `dd` + reanalisar |

## 3. Descida ao gfix (se o header estava ok)

```powershell
& "C:\Program Files\Firebird\Firebird_2_5\bin\gfix.exe" -v -full -user SYSDBA -password <senha> "<caminho>"
```

O `gfix -v -full` é seu *raio-x* das páginas. Ele exige **acesso exclusivo** (com alguém conectado: `secondary server attachments cannot validate databases` — rode numa cópia, ou use a validação online do fbsvcmgr) e devolve **exit 0 mesmo quando acha erro**: limpo = exit 0 **e** nada na tela. O que ele diz:

| Mensagem do gfix | Procedure |
|---|---|
| `Wrong page type` em página X | **04** (página) |
| `Checksum error on page X` | **04** |
| `Page X doubly allocated` / `orphan page` | **04** |
| `index N is corrupt` | **04** (índice — também resolvido por reconstrução no restore) |
| `Record level errors encountered` | **04** + considerar **06** (tabela-a-tabela) se persistir |
| Erro de conexão (`unavailable database`, `lock conflict`) | **02** (serviço/estado), não corrupção |

## 4. Descida ao gbak (último teste antes de decidir)

Mesmo com gfix limpo, pode ter algo que só aparece no backup:

```powershell
& "<SKILL>\scripts\Salvage-Backup.ps1" -Database "<caminho>" -BackupFile "<caminho>.triagem.fbk"
```

- Sucesso ("closing file, committing, and finishing") → corrupção é muito leve ou foi resolvida; siga para **procedure 08** (verificação pós).
- Para numa tabela específica → **procedure 06** (tabela-a-tabela).
- Para com mensagem genérica de página → **procedure 04**.

## 5. Quando ainda assim não está claro

Junte e relate ao usuário:

- Saída completa do `Diagnose-FirebirdHeader.ps1`.
- Saída completa do `gfix -v -full`.
- Primeira linha de erro do `gbak` (se rodou).
- Tamanho do arquivo (em bytes) e data de modificação.
- Estado do serviço (`Get-Service Firebird*`).

Mostre tudo isso e peça orientação. Não chute — recuperação é demorada o suficiente sem precisar refazer porque foi pelo caminho errado.

## Fallback (esta procedure)

Se mesmo o `Diagnose-FirebirdHeader.ps1` quebra (ex.: arquivo não é Firebird de fato, é texto truncado, é outro formato):

1. Veja os primeiros 64 bytes em hex: `xxd -l 64 "<arquivo>"` (git-bash) ou `Format-Hex "<arquivo>" -Count 64` (PowerShell).
2. O 1º byte deve ser `0x01` (pag_type=header). Se for outro, o arquivo provavelmente não é mais um banco Firebird válido — pode ter sido sobrescrito (vírus de macro, ransomware, cópia para o nome errado).
3. Nesse caso: pare, busque o backup mais recente, e considere recuperação por software forense fora do escopo do Firebird.
