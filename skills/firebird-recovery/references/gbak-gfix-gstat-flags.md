# Cheatsheet — gbak, gfix, gstat, isql, nbackup, fbsvcmgr (Firebird 2.5)

Foco em recuperação. Verificado contra o `-?` do Firebird **2.5.9** (WI-V2.5.9.27139), contra o código-fonte do 2.5 (`burpswi.h`, `aliceswi.h`) e por teste em banco descartável. Flags de operação rotineira foram omitidas.

## Sumário

1. [Regra de ouro: abreviações e ordem](#regra-de-ouro-abreviações-e-ordem)
2. [gstat](#gstat)
3. [gfix](#gfix)
4. [gbak](#gbak)
5. [isql](#isql)
6. [nbackup](#nbackup)
7. [fbsvcmgr (Services API)](#fbsvcmgr-services-api)
8. [Credenciais sem expor senha](#credenciais-sem-expor-senha)
9. [Exit codes](#exit-codes)
10. [Caminhos padrão](#caminhos-padrão)

## Regra de ouro: abreviações e ordem

O gbak e o gfix aceitam abreviações, mas resolvem para o **primeiro** switch da tabela interna que começa com aquelas letras — os parênteses do `-?` não garantem nada. Armadilhas reais:

| Escreveu | gbak entende | gfix entende |
|---|---|---|
| `-m` | `-meta_data` (só metadata) | **`-mend`** (destrutivo!) |
| `-mo` | `-mode` (`read_only`/`read_write`, **exige valor**) | `-mode` |
| `-i` | `-inactive` (restore) | `-ignore` |
| `-n` | `-no_validity` (restore; também derruba NOT NULL) | `-no_update` |
| `-o` | `-one_at_a_time` | `-online` |
| `-l` | `-limbo` (backup ignora limbo) | `-list` |
| `-r` | `-recreate_database` | `-rollback` |
| `-t` | `-transportable` (padrão) | `-two_phase` |
| `-s` | switch oculto de restore (não use) | `-sql_dialect` |
| `-pa` | **`-page_size`** | `-password` |
| `-u` / `-use` | `-use_all_space` | `-use` |
| `-f` | — | `-full` (`-fo` = `-force`) |

**Regras práticas:**

- Em script, escreva por extenso: `-user`, `-password`, `-ignore`, `-limbo`, `-meta_data`, `-inactive`, `-one_at_a_time`, `-shut`, `-force`, `-online`.
- No **gfix, o switch de ação vem primeiro**: `gfix -v -full -ignore` funciona; `gfix -full -v` falha com `incompatible switch combination`. O `-mend` também vai primeiro (só `-user`/`-password`/`-no_update` podem vir antes).
- `-user` sempre por extenso: `-u` é outro switch nas duas ferramentas.

## gstat

`gstat <banco> <flags>`.

| Flag | O que faz | Observação |
|---|---|---|
| `-h` | só a página 0 (header) | **lê o arquivo direto, não conecta**, não precisa de credenciais, funciona com banco em shutdown e com o servidor no ar |
| `-a` / `-d` / `-i` | análise de páginas de dados/índices | imprime o header e depois **conecta** (precisa de `-u`/`-p` ou `ISC_USER`/`ISC_PASSWORD`) |
| `-r` | tamanho médio de registro e de versões | idem |
| `-s` | inclui tabelas de sistema | idem |
| `-t <T1> [T2...]` | restringe a tabelas | nomes case-sensitive, **depois** do banco |
| `-u` / `-p` / `-fetch` / `-tr` | usuário / senha / senha de arquivo / trusted | |
| `-z` | versão do **gstat** | não é a versão do servidor (ver fbsvcmgr) |

Exemplo: `gstat -h C:\path\BANCO.FDB`.

### Como ler o `gstat -h`

- A linha **`Flags`** é o `pag_flags` da página 0 (normalmente `0`). **Não** é o `hdr_flags`.
- O `hdr_flags` aparece decodificado em **`Attributes`** e **`Database dialect`** (tabela completa de bits em `ods11-header-layout.md`):

| `Attributes` mostra | Significa |
|---|---|
| `force write` | forced writes ligado (bit `0x2`) — **obrigatório em produção no Windows** |
| (vazio / sem `force write`) | forced writes **desligado** — causa nº 1 de corrupção após queda de energia |
| `multi-user maintenance` | `gfix -shut multi` (ou `-shut` sem modo) |
| `single-user maintenance` | `gfix -shut single` (comum depois de restore que falhou) |
| `full shutdown` | `gfix -shut full` |
| `read only` | `gfix -mode read_only` |
| `backup lock` | `nbackup -L` ativo (ou cópia ainda não "fixada" com `nbackup -F`) |

- **`Next transaction`** perto de 2.147.483.647 (2³¹−1) = limite do 2.5. Backup + restore zera o contador (ver `codigos-erro-firebird.md`).
- **`Next transaction` − `Oldest transaction`** muito maior que o `Sweep interval` = transação travada/sweep não acontecendo (performance, não corrupção).

## gfix

`gfix <ação> [modificadores] <banco>` — conecta via servidor; precisa do servidor no ar e de credenciais.

### Validação e reparo

| Comando | O que faz | Risco |
|---|---|---|
| `gfix -v` | validação de páginas; **libera páginas órfãs** | baixo (pode escrever!) |
| `gfix -v -full` | + verificação por registro | baixo |
| `gfix -v -full -no_update` | só relata, não corrige nada | nenhum |
| `gfix -v -full -ignore` | idem, ignorando checksum ruim | baixo |
| `gfix -mend -full -ignore` | marca registros/páginas ilegíveis como apagados ("prepara para backup"); implica `-v -full` | **destrutivo** — só em cópia |

- **Exige acesso exclusivo.** Com outra conexão aberta: `bad parameters on attach or create database` + `secondary server attachments cannot validate databases`. Caminho: `gfix -shut single -force 0` → `gfix -v -full` → `gfix -online`. Ou use a **validação online** (fbsvcmgr, abaixo), que roda com usuários conectados.
- O gfix imprime só o **sumário**; os detalhes (tabela, página, registro) vão para o `firebird.log`.

### Shutdown e estado (verificado no 2.5.9)

| Comando | `hdr_flags` | `gstat -h` Attributes | Quem conecta |
|---|---|---|---|
| `gfix -shut -force 0` (sem modo) = `-shut multi` | `+0x80` | multi-user maintenance | SYSDBA e dono, várias conexões — **aplicação que usa SYSDBA continua entrando** |
| `gfix -shut single -force 0` | `+0x1080` | single-user maintenance | **uma** conexão SYSDBA/dono; a segunda recebe `connection lost to database` |
| `gfix -shut full -force 0` | `+0x1000` | full shutdown | ninguém — nem `gfix -v`; só `gfix -online` |
| `gfix -online` | volta | — | normal (`-online single`/`multi` também existem) |

- Em vez de `-force N` (derruba após N s), dá para usar `-attach N` (espera as conexões saírem) ou `-tran N` (espera as transações terminarem). N = 0..32767.
- **Isolar para mexer no arquivo** (patch binário, cópia, troca): `-shut full`. **Manutenção com 1 conexão** (validar, limpar órfãs): `-shut single`.

### Outras

| Comando | O que faz |
|---|---|
| `gfix -write sync` / `async` | liga/desliga forced writes (bit `0x2`); funciona com usuários conectados |
| `gfix -mode read_only` / `read_write` | bit `0x200`; exige acesso exclusivo (no 2.5 **não** abrevie para `-m` = mend) |
| `gfix -sweep` | sweep manual |
| `gfix -housekeeping N` | intervalo de sweep automático (0 = desliga) |
| `gfix -buffers N` | page buffers gravados no header |
| `gfix -sql_dialect N` | troca o dialect (raro; cuidado) |

### Transações em limbo

| Comando | O que faz |
|---|---|
| `gfix -list` | lista limbos |
| `gfix -list -prompt` | percorre perguntando commit/rollback (`-prompt` só vale depois de `-list`) |
| `gfix -commit {N \| all}` | commita uma ou todas |
| `gfix -rollback {N \| all}` | desfaz uma ou todas |
| `gfix -two_phase {N \| all}` | recuperação 2PC automática (só faz sentido com coordenador externo) |

## gbak

`gbak <modo> [flags] <origem> <destino>` — conecta via servidor.

### Backup (`-b`)

| Flag | O que faz | Quando |
|---|---|---|
| `-v` (`-verify`) | uma linha por etapa/tabela | sempre em recuperação |
| `-ignore` (`-ig`) | ignora erro de **checksum** de página | banco suspeito. **Não** passa por `wrong page type` nem por I/O/EOF |
| `-g` | não faz garbage collection | banco suspeito ou grande |
| `-limbo` (`-l`) | ignora transações em limbo (lê a última versão commitada) | backup travando em `stuck in limbo` |
| `-meta_data` (`-m`) | só metadata | criar destino vazio para pump |
| `-nodbtriggers` (`-nod`) | não dispara triggers de banco | trigger ON CONNECT atrapalhando |
| `-transportable` (`-t`) | formato XDR | é o padrão |
| `-nt` | formato não-transportável | só mesma plataforma |
| `-convert` (`-co`) | external tables viram tabelas | raro |
| `-expand` (`-e`) | sem compressão | raro |
| `-skip_data` / `-include_data` | pular/selecionar dados de tabelas | **não existem no 2.5** (`-skip_data` é 3.0+, `-include_data` é 4.0+) |

> **FB 2.5 não tem como pular tabela no backup.** O caminho é salvar as linhas legíveis e **dropar** a tabela problemática numa cópia antes do `gbak -b` — ver procedure 06, "Caminho FB 2.5".

### Restore (`-c` e variantes)

| Flag | O que faz | Quando |
|---|---|---|
| `-c` (`-create_database`) | cria banco novo; **falha se o arquivo existe** | padrão |
| `-r` (`-recreate_database`) | igual ao `-c`; com `-r o` (`overwrite`) substitui | cuidado |
| `-rep` (`-replace_database`) | substitui banco existente | cuidado |
| `-inactive` (`-i`) | **todos** os índices inativos, inclusive PK/FK/UNIQUE — constraints não são aplicadas | restore que quebra em índice/FK (procedure 05) |
| `-one_at_a_time` (`-o`) | commit por tabela | uma tabela quebra, salva o resto |
| `-meta_data` (`-m`) | só estrutura | destino vazio |
| `-no_validity` (`-n`) | não restaura CHECK de domínio **nem os NOT NULL** | último caso; documente |
| `-buffers N` (`-bu`) | page buffers do destino | bancos grandes: `-bu 10000` |
| `-page_size N` (`-p`) | page size do destino | mudar page size |
| `-mode read_only` (`-mo`) | modo de acesso do destino | raro |
| `-kill` (`-k`) | não recria shadows | raro |
| `-use_all_space` | não reserva espaço para versões | bancos só-leitura |
| `-fix_fss_data` / `-fix_fss_metadata <charset>` | corrige UNICODE_FSS malformado | só se souber que precisa |

> Índice de PK/FK/UNIQUE **não pode** ser desativado por DDL no 2.5 (`Cannot deactivate index used by an integrity constraint`). O `gbak -c -i` é o único jeito de ter essas constraints desligadas — útil para tratar órfãs/duplicatas antes de reativar.

### Comuns a backup e restore

| Flag | O que faz |
|---|---|
| `-user <U>` | usuário (**por extenso**) |
| `-password <P>` | senha (`-pas` também serve; **`-pa` é page_size**) |
| `-fetch_password <arquivo>` (`-fe`) | lê a senha de arquivo |
| `-role <R>` | role |
| `-se <host>:service_mgr` | roda **no servidor** via Services API (mais rápido; caminhos são os do servidor) |
| `-st TDRW` | estatísticas: T tempo, D delta, R leituras, W escritas (a partir do **2.5.5**) |
| `-y <arquivo>` | grava a saída em arquivo — **recusa arquivo existente**; `-y suppress` silencia |
| `-z` | versão do gbak |

### Combinações canônicas

```text
Salvamento:          gbak -b -v -ignore -g [-limbo] <banco> <saida.fbk>
Rápido (servidor):   gbak -b -v -ignore -g -se localhost:service_mgr <banco> <saida.fbk>
Restore difícil:     gbak -c -v -inactive -one_at_a_time <entrada.fbk> <novo.fdb>
Destino vazio:       gbak -b -v -m -ignore -g <banco> <meta.fbk>
                     gbak -c -v -m -inactive <meta.fbk> <destino.fdb>
```

## isql

| Flag | O que faz | Observação |
|---|---|---|
| `-i <arquivo>` | executa o script | |
| `-b` (`-bail`) | para no primeiro erro | **só funciona com `-i arquivo`**. Com o script chegando por pipe/stdin o isql **continua** depois do erro (verificado no 2.5.9) |
| `-e` | ecoa cada comando | ajuda a ver o que de fato rodou |
| `-o <arquivo>` | saída em arquivo | dumps forenses. **Anexa** ao arquivo existente (o comando `OUTPUT` também) — apague antes ou use nome novo, senão contagens e scripts gerados saem duplicados |
| `-m` / `-m2` | junta stderr / diagnósticos na saída | logs completos |
| `-q` | silencioso | |
| `-x` / `-ex` (`-a` inclui legado) | extrai a DDL do banco | schema para recriar destino |
| `-ch <charset>` | charset da conexão | use o charset do banco (acentos); afeta EDS |
| `-t <term>` | terminador inicial | alternativa a `SET TERM` |
| `-n` | `SET AUTODDL OFF` | |
| `-nod` | não dispara triggers de banco | |
| `-z` | versão do isql **e do servidor** | |

### `SET TERM` sem armadilha

O último caractere do comando é o terminador **atual**. Forma explícita e segura:

```sql
SET TERM ^ ;      -- entra no modo ^ (o ; final é o terminador atual)
EXECUTE BLOCK AS BEGIN ... END^
SET TERM ; ^      -- volta para ; (o ^ final é o terminador atual)
```

`SET TERM ;^` é válido **para sair** do modo `^`. Usado para **entrar** (terminador atual ainda é `;`), o isql passa a engolir os comandos seguintes **sem erro nenhum** (prompt `CON>`), e por isso nem `-b` pega. Use sempre a forma com espaço e confira com `-e`.

## nbackup

Cópia física consistente de banco **em uso**, sem parar o serviço:

```text
1. nbackup -L <banco>        congela o arquivo principal (writes vão para <banco>.delta); usuários seguem conectados
2. copiar o arquivo          Copy-Item / robocopy
3. nbackup -N <banco>        destrava e mescla o delta
4. nbackup -F <cópia>        SÓ NA CÓPIA: tira o estado "backup lock" (0x400) para ela abrir
```

- **Nunca** rode `-F` no banco vivo.
- Não esqueça o `-N`: o `.delta` cresce sem limite.
- `-L` precisa conseguir conectar (não serve para banco com header quebrado).
- `-S` (com `-L`) imprime o tamanho em páginas. `-U`/`-P` = usuário/senha.

## fbsvcmgr (Services API)

| Uso | Comando |
|---|---|
| Testar credencial + versão do **servidor** | `fbsvcmgr service_mgr user SYSDBA password *** info_server_version` |
| Header via servidor | `fbsvcmgr service_mgr user SYSDBA password *** action_db_stats dbname <banco> sts_hdr_pages` |
| **Validação online** (2.5.4+) | `fbsvcmgr service_mgr user SYSDBA password *** action_validate dbname <banco> [val_tab_incl "T1\|T2"] [val_tab_excl <pad>] [val_idx_incl <pad>] [val_idx_excl <pad>] [val_lock_timeout N]` |

**Validação online** (`action_validate`):

- Roda **com usuários conectados**. Leituras da tabela em validação seguem; escritas nela esperam até `val_lock_timeout` (padrão 10 s; 0 = não espera; −1 = espera sempre). Tabela que não consegue o lock é pulada.
- Faz, por tabela de usuário, a mesma checagem do `gfix -v -full` (páginas, registros e índices daquela tabela).
- **Não** checa: tabelas de sistema, header, PIP, TIP, generators, páginas compartilhadas entre tabelas, nem libera órfãs. Não conserta nada.
- Padrões são `SIMILAR TO`, **case-sensitive**, separados por `|` sem espaço. `_` e `%` são curingas: nome com `_` vai como `[_]` (`TABELA[_]A`).
- Saída no stdout, por tabela: `Relation N (TABELA) is ok` ou `Relation N (TABELA) : N ERRORS found`, terminando em `Validation finished`. Erros também vão para o `firebird.log`.
- **Página 100% zerada aborta tudo** (checksum 0): exit 1, `database file appears corrupt () / bad checksum / checksum error on database page N` no fim, e as tabelas seguintes ficam sem validar. O fim da saída se perde, então a última `Relation` do log pode ser anterior à culpada. Ache a tabela pelo número da página nas pointer pages (`RDB$PAGES`, tipo 4: `ppg_count` em `0x18`, `ppg_relation` em `0x1A`, lista de páginas em `0x20`) e revalide com `val_tab_excl`. Página com lixo mas checksum `12345` não aborta: sai `Page N wrong type ...` e `ERRORS found`.
- Boa para **achar todas as tabelas ruins**, sem janela de manutenção — contando com os abortos acima (o `Test-FirebirdHealth.ps1` repete a validação excluindo cada tabela que abortou).

## Credenciais sem expor senha

- `ISC_USER` / `ISC_PASSWORD` no ambiente do processo: gbak, gfix, isql, gstat (`-a`/`-r`), nbackup e fbsvcmgr usam quando a linha de comando não traz usuário/senha (verificado no 2.5.9). `-user`/`-password` explícitos têm prioridade.
- Ou `-fetch_password <arquivo>` (gbak/gfix), `-fetch` (gstat), `-f` (isql), `-FE` (nbackup).
- Evita a senha na lista de processos e nos logs. Não grave a senha em log nem em relatório.

## Exit codes

Todos retornam 0 = sucesso, ≠ 0 = falha. Mas a "falha" pode ser parcial:

- **gbak**: exit 0 com warnings no log ainda é sucesso. `gbak: ERROR` + exit ≠ 0 = falha real. Backup ok termina com `closing file, committing, and finishing`; restore ok, com `finishing, closing, and going home`. A tabela que quebrou é a da **última** linha `writing table X` / `writing data for table X` antes do primeiro `ERROR` (o erro pode vir antes do "writing data").
- **gfix -v**: **retorna exit 0 mesmo quando acha erros** (imprime `Summary of validation errors` / `Number of ... errors : N`). Limpo = exit 0 **e** saída vazia.
- **gstat**: exit 0 + saída lida = ok.
- **fbsvcmgr action_validate**: **exit 0 mesmo com erros** — leia as linhas `ERRORS found` (e as de página, ex.: `Page 245 wrong type (expected 5 encountered 0)`). Exit 1 ou qualquer linha depois de `Validation finished` = a validação **abortou** (página zerada) e não cobriu o banco todo.

## Caminhos padrão

```powershell
$fb = "C:\Program Files\Firebird\Firebird_2_5\bin"
$gstat = "$fb\gstat.exe"; $gfix = "$fb\gfix.exe"; $gbak = "$fb\gbak.exe"
$isql  = "$fb\isql.exe";  $nbackup = "$fb\nbackup.exe"; $fbsvcmgr = "$fb\fbsvcmgr.exe"
```

O `firebird.log` fica na raiz da instalação (`C:\Program Files\Firebird\Firebird_2_5\firebird.log`).
