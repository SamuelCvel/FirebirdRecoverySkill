# 04 — Páginas corrompidas (checksum / wrong page type / I/O error)

**Sintomas característicos** (qualquer um):

- `gfix -v` relata `Wrong page type ... should be X but is Y`.
- `Checksum error on page N`.
- `Page N doubly allocated` ou `orphan page N`.
- `gbak -b` para num ponto específico com `Checksum verification failed`.
- `I/O error during read of database` em um offset/página específica (disco com setor ruim).

**Diferença em relação à procedure 03:** o header está OK (`gstat -h` lê). O problema está em uma ou mais páginas internas (dados, índices, PIP, TIP, pointer pages).

## Sumário

- [Pré-requisitos](#pré-requisitos)
- [1. Mapear o estrago](#1-mapear-o-estrago)
- [2. Tentativa não-destrutiva: gbak com -ignore](#2-tentativa-não-destrutiva-gbak-com--ignore)
- [3. Tentativa destrutiva controlada: gfix -mend -full -ignore](#3-tentativa-destrutiva-controlada-gfix--mend--full--ignore)
- [4. Caso grave: corrupção em PIP / TIP](#4-caso-grave-corrupção-em-pip--tip)
- [5. I/O error: suspeite do hardware antes de continuar](#5-io-error-suspeite-do-hardware-antes-de-continuar)
- [5b. Sinal de parar cedo — corrupção massiva](#5b-sinal-de-parar-cedo--corrupção-massiva)
- [6. Verificação final (sempre)](#6-verificação-final-sempre)

## Pré-requisitos

- Procedure 02 executada.
- Header confirmado válido (`Diagnose-FirebirdHeader.ps1` mostra page_size válido).

## 1. Mapear o estrago

### 1.a Quais tabelas estão ruins (todas de uma vez)

O gbak para na **primeira** tabela ruim; para decidir o caminho você precisa saber **quantas** existem. Duas formas, ambas só leitura:

```powershell
# Varre todas as tabelas (todas as colunas e BLOBs); não para na primeira ruim
Remove-Item "<cópia>.sonda.txt" -ErrorAction SilentlyContinue
& "C:\Program Files\Firebird\Firebird_2_5\bin\isql.exe" -q -user SYSDBA -password <senha> -i "<SKILL>\sql\sondar-tabelas.sql" -o "<cópia>.sonda.txt" "<cópia>"

# Ou a validação online (FB 2.5.4+): por tabela, com detalhe da página
& "C:\Program Files\Firebird\Firebird_2_5\bin\fbsvcmgr.exe" service_mgr user SYSDBA password <senha> action_validate dbname "<cópia>"
```

Exemplo real da validação online numa página de dados zerada: `Page 245 wrong type (expected 5 encountered 0)` e `Relation 138 (SALES) : 1 ERRORS found`. Conte os **sítios independentes** — 3 ou mais é sinal de parar (seção 5b).

### 1.b Visão estrutural com gfix -v -full

O gfix de validação exige **acesso exclusivo** (na cópia de trabalho, ninguém mais conecta) e **devolve exit 0 mesmo quando acha erro** — o que conta é a saída.

```powershell
& "C:\Program Files\Firebird\Firebird_2_5\bin\gfix.exe" -v -full -user SYSDBA -password <senha> "<cópia>" 2>&1 | Tee-Object -FilePath "<cópia>.gfix.log"
```

> **Caso especial — `gfix` não atacha:** se `gfix -v` retornar só `internal Firebird consistency check (cannot find tip page (N), file: tra.cpp line: ...)` e exit 1 em poucos segundos, o engine recusa atachar via gfix por causa da TIP corrompida. **Não desista** — `gbak` usa um caminho de attach diferente e pode funcionar mesmo assim. Pule direto para a seção 2 (`gbak -b -ignore -g`) e veja se passa. Se passar, restore para banco novo (recria TIPs do zero).

O gfix imprime só o **sumário** (`Summary of validation errors` / `Number of database page errors : N`, `record level errors`, `index page errors`…); os detalhes vão para o `firebird.log` (abaixo). Leitura:

| Sumário do gfix / linha do firebird.log | Interpretação |
|---|---|
| (saída vazia) | sem corrupção estrutural — siga para Salvage-Backup direto |
| `Page 1234 wrong type (expected 5 encountered 0)` | página de dados zerada (provavelmente setor ruim) |
| `Checksum error on page 2345` | bit-flip ou setor degradado; gbak `-ignore` pode contornar |
| `Page 3456 doubly allocated` | PIP corrompida — risco alto, ler seção 4 antes de prosseguir |
| `Database file appears corrupt` em loop | corrupção generalizada; considere procedure 06 |
| `Index N is corrupt on page M` | índice corrupto — só recriar no restore resolve; não bloqueia |

Anote as páginas afetadas (ou as 5-10 primeiras se forem muitas). Se forem todas índices, é caso fácil.

### O que o `firebird.log` diz em paralelo

Enquanto o `gfix -v -full` roda, ele escreve detalhes por-registro/por-página em `C:\Program Files\Firebird\Firebird_2_5\firebird.log`. Padrões úteis para identificar **qual tabela** tem cada erro:

```
Record 82097 has bad transaction 240102052 in table TABELA_A (1009)
Record 113309 has bad transaction 240112913 in table TABELA_B (1021)
Page 196167 is an orphan
```

Casando: `Record N has bad transaction K` = registro `N` na tabela nomeada é o que aparece nos `record level errors` do sumário. Anotar essas tabelas ajuda a priorizar. Em banco de produção maduro é comum ter esses registros — quase sempre são **cosméticos** (ver observação na seção 2).

## 2. Tentativa não-destrutiva: gbak com -ignore

`gbak -b -ignore -g` instrui o backup a ignorar erros de **checksum** e não rodar GC. Se a corrupção é em poucas páginas com checksum ruim e os dados subjacentes estão íntegros, o backup atravessa.

> **Limite do `-ignore`:** essa flag cobre **checksum errado**, não cobre `wrong page type` nem `I/O error / Final do arquivo alcançado`. Esses são erros estruturais — o `gbak` aborta (verificado: `page 245 is of wrong type (expected 5, found 0)` com `-ignore`) e o caminho é a procedure 06 (Caminho A: salvar e dropar a tabela; ou Caminho B: copiar tudo por fora do gbak).

> **Achado empírico importante (caso real):** um banco de 1,6 GB apresentou no `gfix -v -full` um sumário de **170 erros** (116 record + 53 index + 1 database page), mas o `gbak -b -v -ignore -g` completou em **68 segundos com 0 erros e 0 warnings**. Após restore + limpeza de 6 FKs órfãs, o `gfix -v -full` no recuperado voltou **completamente limpo (0 bytes de log)**, sem perda de registro (delta 0 em 6,46 milhões). Ou seja: **centenas de erros no gfix não são necessariamente perda de dado**. Se o `gbak -ignore` passa limpo, os erros do gfix eram checksum cosmético (bit-flip na área de checksum, dados subjacentes íntegros) e o restore recompõe tudo. **Sempre teste a lente 3 antes de escalar para procedures destrutivas.**

```powershell
& "<SKILL>\scripts\Salvage-Backup.ps1" -Database "<cópia>" -BackupFile "<basename>.salvage.fbk"
```

(O script aciona `-ignore -g` por padrão e loga tudo.)

Sucesso esperado: log termina com `closing file, committing, and finishing. NNN bytes written`. Pode haver linhas `gbak: warning ...` no meio — toleráveis. **Linhas com `gbak: ERROR:` indicam onde travou** — a tabela é a da **última** linha `writing table X` / `writing data for table X` antes do primeiro `ERROR` (o erro pode aparecer antes do "writing data").

### Resultados possíveis e o que fazer

| Resultado do gbak | Próximo passo |
|---|---|
| Sucesso completo | siga para **Restore-Clean** → procedure 08 |
| Para em tabela X | **procedure 06** (extrair tabela-a-tabela) |
| Para com erro genérico de página | seção 3 (gfix -mend) ou procedure 06 |
| Loop infinito / trava | seção 4 (caso grave) |

## 3. Tentativa destrutiva controlada: gfix -mend -full -ignore

`gfix -mend` ("prepara banco corrompido para backup") marca como apagados os registros/páginas que não consegue ler e tenta deixar o banco consistente. Implica `-v -full`. É **destrutivo**: você perde os dados das páginas marcadas. Use só depois que `gbak -ignore` falhou — e prefira antes a procedure 06, que salva o que é legível sem apagar nada.

```powershell
& "C:\Program Files\Firebird\Firebird_2_5\bin\gfix.exe" -mend -full -ignore -user SYSDBA -password <senha> "<cópia-da-cópia>" 2>&1 | Tee-Object -FilePath "<cópia-da-cópia>.mend.log"
```

> No gfix 2.5, `-m` abreviado **é `-mend`** (não `-mode`). Escreva sempre por extenso e com a ação primeiro.

Antes:

- Confirme que a procedure 02 fez cópia: você vai aplicar `-mend` na **cópia da cópia**, mantendo a primeira cópia intocada.
- Estime o impacto: rode `sql/contagem-registros-por-tabela.sql` antes e depois (arquivos de saída diferentes — o `-o` anexa) e compare; veja quanto registro o `-mend` "comeu".

Depois:

```powershell
# revalidar (saída vazia = ok; o exit code é 0 mesmo com erro)
& "C:\Program Files\Firebird\Firebird_2_5\bin\gfix.exe" -v -full -user SYSDBA -password <senha> "<cópia-da-cópia>"
# retentar o salvage backup
& "<SKILL>\scripts\Salvage-Backup.ps1" -Database "<cópia-da-cópia>" -BackupFile "<basename>.salvage-pos-mend.fbk"
```

Se o `gbak` agora completa, restore e siga para procedure 08. Se ainda falha, vá para procedure 06 (extração tabela-a-tabela).

### Fallback do -mend

- **`-mend` reporta "no errors found" mas o gbak continua falhando:** o erro está em índice/constraint (não em página de dados). Vá para procedure 05.
- **`-mend` continua reportando erros:** rode 2-3 vezes (alguns problemas precisam de passes sucessivos). Se não evoluir, procedure 06.
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
# Cheque o disco (somente leitura)
Get-PhysicalDisk | Select FriendlyName, HealthStatus, OperationalStatus
Get-PhysicalDisk | Get-StorageReliabilityCounter | Select DeviceId, ReadErrorsUncorrected, Wear, Temperature   # precisa de Administrador
Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='disk','Ntfs','Microsoft-Windows-Ntfs','stornvme','storahci'; StartTime=(Get-Date).AddDays(-30) } -ErrorAction SilentlyContinue |
  Where-Object Level -le 3 | Select TimeCreated, Id, ProviderName, Message -First 20                             # erros/avisos de disco e NTFS
Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power','EventLog'; Id=41,6008; StartTime=(Get-Date).AddDays(-30) } -ErrorAction SilentlyContinue |
  Select TimeCreated, Id, Message -First 20                                                                      # desligamentos inesperados
# chkdsk C: /r     # PRECISA de reboot e tempo; só com autorização do usuário
```

Desligamento inesperado + `gstat -h` **sem** `force write` em `Attributes` é a combinação clássica de corrupção no Windows: ligue com `gfix -write sync` no banco que voltar para produção.

Tudo isso (e mais: banco em compartilhamento de rede, espaço livre, exclusões do antivírus, bugchecks no `firebird.log`) sai num relatório só, sem alterar nada:

```powershell
& "<SKILL>\scripts\Get-FirebirdEnvironmentReport.ps1" -Database "<banco>" -Days 60
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

- **3+ sítios independentes de corrupção** (ex.: TIP page X + checksum ruim em tabela Y + wrong page type em tabela Z, em offsets distantes do arquivo). É assinatura de falha de hardware (RAM/disco) — recuperar in-place vai vazar mais perdas à medida que avança. Conte os sítios numa passada só com `sql/sondar-tabelas.sql` ou a validação online (seção 1.a).
- **A extração POR CHAVE (procedure 06 seção 3.a) falha numa faixa longa** de chaves, mesmo pulando com saltos grandes. Aí a perda daquela tabela é real e grande.
  > **Atenção:** se você usou `FIRST/SKIP`, o padrão "janelas 0..N passam e **todas** as seguintes falham" é **artefato do SKIP** (ele relê as linhas puladas e bate sempre na mesma página ruim) — não prova perda grande. Refaça pela chave antes de concluir.
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
& "C:\Program Files\Firebird\Firebird_2_5\bin\gstat.exe" -h "<cópia-final>"
& "C:\Program Files\Firebird\Firebird_2_5\bin\gfix.exe" -v -full -user SYSDBA -password <senha> "<cópia-final>"   # saída vazia = ok
& "<SKILL>\scripts\Salvage-Backup.ps1" -Database "<cópia-final>" -BackupFile "<final>.fbk"
& "<SKILL>\scripts\Restore-Clean.ps1" -BackupFile "<final>.fbk" -TargetDatabase "<RECUPERADO>.fdb"
```

E então procedure 08 para contagens e reintegração.
