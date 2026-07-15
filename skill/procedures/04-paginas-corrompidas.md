# 04 — Páginas corrompidas (checksum / wrong page type / I/O error)

**Sintomas característicos** (qualquer um):

- `gfix -v` relata `Wrong page type ... should be X but is Y`.
- `Checksum error on page N`.
- `Page N doubly allocated` ou `orphan page N`.
- `gbak -b` para num ponto específico com `Checksum verification failed`.
- `I/O error during read of database` em um offset/página específica (disco com setor ruim).

**Diferença em relação à procedure 03:** o header está OK (`gstat -h` lê). O problema está em uma ou mais páginas internas (dados, índices, PIP, TIP, pointer pages).

## Pré-requisitos

- Procedure 02 executada.
- Header confirmado válido (`Diagnose-FirebirdHeader.ps1` mostra page_size válido).

## 1. Mapear o estrago com gfix -v -full

```powershell
& "C:\Program Files\Firebird\Firebird_2_5\bin\gfix.exe" -v -full -user SYSDBA -password masterkey "<cópia>" 2>&1 | Tee-Object -FilePath "<cópia>.gfix.log"
$LASTEXITCODE
```

> **Caso especial — `gfix` não atacha:** se `gfix -v` retornar só `internal Firebird consistency check (cannot find tip page (N), file: tra.cpp line: ...)` e exit 1 em poucos segundos, o engine recusa atachar via gfix por causa da TIP corrompida. **Não desista** — `gbak` usa um caminho de attach diferente e pode funcionar mesmo assim. Pule direto para a seção 2 (`gbak -b -ignore -g`) e veja se passa. Se passar, restore para banco novo (recria TIPs do zero).

O log é o seu raio-x. Exemplos de leitura:

| Linha do gfix | Interpretação |
|---|---|
| (vazio + exit 0) | sem corrupção estrutural — siga para Salvage-Backup direto |
| `Page 1234 wrong type. Expected 5 got 0` | página de dados zerada (provavelmente setor ruim) |
| `Checksum error on page 2345` | bit-flip ou setor degradado; gbak `-ignore` pode contornar |
| `Page 3456 doubly allocated` | PIP corrompida — risco alto, ler seção 4 antes de prosseguir |
| `Database file appears corrupt` em loop | corrupção generalizada; considere procedure 06 |
| `Index N is corrupt on page M` | índice corrupto — só recriar no restore resolve; não bloqueia |

Anote as páginas afetadas (ou as 5-10 primeiras se forem muitas). Se forem todas índices, é caso fácil.

## 2. Tentativa não-destrutiva: gbak com -ignore

`gbak -b -ignore -g` instrui o backup a ignorar erros de **checksum** e não rodar GC. Se a corrupção é em poucas páginas com checksum ruim e os dados subjacentes estão íntegros, o backup atravessa.

> **Limite do `-ignore`:** essa flag cobre **checksum errado**, não cobre `wrong page type` nem `I/O error / Final do arquivo alcançado`. Esses são erros estruturais — `gbak` aborta e você precisa **dropar a tabela** que disparou o erro (procedure 06) antes de tentar de novo.

```powershell
.\scripts\Salvage-Backup.ps1 -Database "<cópia>" -BackupFile "<basename>.salvage.fbk"
```

(O script aciona `-ignore -g` por padrão e loga tudo.)

Sucesso esperado: log termina com `closing file, committing, and finishing. NNN bytes written`. Pode haver linhas `gbak: warning ...` no meio — toleráveis. **Linhas com `gbak: ERROR:` indicam onde travou** — anote a tabela.

### Resultados possíveis e o que fazer

| Resultado do gbak | Próximo passo |
|---|---|
| Sucesso completo | siga para **Restore-Clean** → procedure 08 |
| Para em tabela X | **procedure 06** (extrair tabela-a-tabela) |
| Para com erro genérico de página | seção 3 (gfix -mend) ou procedure 06 |
| Loop infinito / trava | seção 4 (caso grave) |

## 3. Tentativa destrutiva controlada: gfix -mend -ignore

`gfix -mend` marca como deletadas as páginas/registros que não consegue ler e tenta deixar o banco consistente. É **destrutivo**: você perde os dados das páginas marcadas. Use só depois que `gbak -ignore` falhou.

```powershell
& "C:\Program Files\Firebird\Firebird_2_5\bin\gfix.exe" -mend -ignore -user SYSDBA -password masterkey "<cópia>" 2>&1 | Tee-Object -FilePath "<cópia>.mend.log"
```

Antes:

- Confirme que a procedure 02 fez cópia: você vai aplicar `-mend` na **cópia da cópia**, mantendo a primeira cópia intocada.
- Estime o impacto: rode `Salvage-TableByTable.ps1 -CountOnly` antes e depois para comparar; veja quanto registro o `-mend` "comeu".

Depois:

```powershell
# revalidar
& "...\gfix.exe" -v -full -user SYSDBA -password masterkey "<cópia>"
# retentar o salvage backup
.\scripts\Salvage-Backup.ps1 -Database "<cópia>" -BackupFile "<basename>.salvage-pos-mend.fbk"
```

Se o `gbak` agora completa, restore e siga para procedure 08. Se ainda falha, vá para procedure 06 (extração tabela-a-tabela).

### Fallback do -mend

- **`-mend` reporta "no errors found" mas o gbak continua falhando:** o erro está em índice/constraint (não em página de dados). Vá para procedure 05.
- **`-mend` reporta erros mas exit code ≠ 0:** rode 2-3 vezes (alguns problemas precisam de passes sucessivos). Se não evoluir, procedure 06.
- **Pós `-mend` o banco "fica menor" subitamente:** apague essa cópia, refaça do original, e parta para procedure 06 — `-mend` agressivo demais para o caso.

## 4. Caso grave: corrupção em PIP / TIP

PIP (Page Inventory Page) é o mapa de páginas livres/usadas. Se ela corrompe (`page doubly allocated` espalhado, contagens malucas), nem o `-mend` resolve direito. Sintoma: gfix fica em loop ou reporta dezenas de erros novos a cada execução.

Caminho de melhor esforço:

1. Restaurar de backup recente se houver — sempre melhor.
2. Sem backup: ir direto para procedure 06 (tabela-a-tabela). A PIP só é necessária para o engine alocar — extraindo via SELECT, você lê pelo catálogo de tabelas, não pela PIP.
3. Após extrair, recriar banco do zero e popular. Aceitar perda de registros em páginas verdadeiramente ilegíveis.

## 5. I/O error: suspeite do hardware antes de continuar

Se o erro é `I/O error during read` em offsets fixos:

```powershell
# Cheque o disco
Get-PhysicalDisk | Select FriendlyName, HealthStatus, OperationalStatus
chkdsk C: /r       # PRECISA de reboot e tempo; só com autorização do usuário
```

Se o disco já está reportando warning/unhealthy, **mover o arquivo para outro disco antes de continuar** — caso contrário, novas leituras podem corromper mais.

Detalhes: se o setor é fisicamente ruim, copiar `Copy-Item` falha. Tente:

```bash
# git-bash, com dd
dd if="origem.fdb" of="destino.fdb" bs=4M conv=noerror,sync
```

`conv=noerror,sync` preenche blocos ilegíveis com zeros, mantendo offsets. Os blocos zerados vão virar páginas zeradas (pag_type 0) que o gfix/gbak vão reportar como wrong page type — mas o resto do arquivo passa. A partir daí, voltar ao passo 1.

## 5b. Sinal de parar cedo — corrupção massiva

Antes de gastar horas em drop+recreate iterativo, faça um sanity check honesto. Pare e mude de estratégia (restaurar de backup) quando algum destes acontece:

- **3+ sítios independentes de corrupção** (ex.: TIP page X + checksum ruim em tabela Y + wrong page type em tabela Z, em offsets distantes do arquivo). É assinatura de falha de hardware (RAM/disco) — recuperar in-place vai vazar mais perdas à medida que avança.
- **Tentativa de salvar uma tabela em chunks** mostra: chunks 0-N passam, **todos** os chunks N+1 em diante falham consecutivamente. Significa que a partir daquele ponto, o índice da PK toca uma região grande de páginas ruins — perda > 90% do conteúdo daquela tabela.
- **gbak para repetidamente em tabelas críticas diferentes** (cadastro de produto, clientes, financeiro). Cada drop+recreate dessas tabelas críticas perde dados primários e gera órfãs em dezenas de FKs.

Nesses casos, o caminho mais barato e seguro é:
1. **Parar** a recuperação in-place.
2. Procurar o `.fbk` automatizado mais recente (pasta de backup do servidor, agendamento Windows).
3. Restaurar dele + reentrar manualmente os dados perdidos entre o backup e o incidente.
4. Investigar/trocar o hardware antes de devolver qualquer DB para esse servidor.

Documente a decisão e os 3+ sítios de corrupção identificados — fica como evidência para o suporte e para auditoria.

## 6. Verificação final (sempre)

Independente do caminho, antes de chamar de "ok":

```powershell
# 4 lentes
& "...\gstat.exe" -h "<cópia-final>"
& "...\gfix.exe" -v -full -user SYSDBA -password masterkey "<cópia-final>"
.\scripts\Salvage-Backup.ps1 -Database "<cópia-final>" -BackupFile "<final>.fbk"
.\scripts\Restore-Clean.ps1 -BackupFile "<final>.fbk" -TargetDatabase "<RECUPERADO>.fdb"
```

E então procedure 08 para contagens e reintegração.
