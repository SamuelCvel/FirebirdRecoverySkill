# Mensagens de erro → causa provável → procedure

Tabela de consulta rápida. Para cada mensagem típica que aparece em `gstat`, `gfix`, `gbak`, `isql`, `fbsvcmgr` ou no log do servidor (`firebird.log`), aponta a causa mais provável e a procedure que cobre o caminho.

Use Ctrl+F para localizar a mensagem que você está vendo. Linhas marcadas com ✔ foram reproduzidas no Firebird 2.5.9.

## Sumário

1. [gstat](#mensagens-de-gstat)
2. [gfix](#mensagens-de-gfix)
3. [gbak](#mensagens-de-gbak)
4. [isql / conexão](#mensagens-de-isql--conexão)
5. [fbsvcmgr (validação online)](#mensagens-de-fbsvcmgr-validação-online)
6. [firebird.log](#mensagens-no-firebirdlog-servidor)
7. [Quando a mensagem não está aqui](#quando-a-mensagem-não-está-aqui)
8. [Códigos numéricos](#códigos-de-erro-numéricos-comuns-isc_codes)

## Mensagens de gstat

| Mensagem | Causa | Procedure |
|---|---|---|
| `unable to allocate memory from operating system` (gstat -h) | page_size inválido no header — gstat tentou alocar buffer impossível | **03** (header) |
| `cannot open database file` (gstat) | arquivo inacessível: lock pelo servidor, permissão, caminho errado | **02** (segurança/serviço) |
| `I/O error during "open" operation` (gstat) | arquivo movido, em uso, ou disco com erro | **02** |
| `not a valid database` | página 0 com `pag_type ≠ 1` ou `hdr_sequence ≠ 0` (header destruído) ou arquivo não é Firebird | **03** seção 5 |
| `unsupported on-disk structure` | ODS fora de 11.0–11.2: banco de FB 3+ aberto com ferramentas 2.5, ou campo ODS (`0x12`) corrompido | **03** seção 5.a |

## Mensagens de gfix

| Mensagem | Causa | Procedure |
|---|---|---|
| `Database file appears corrupt` | corrupção genérica detectada | **04** |
| `Wrong page type. Page N. Expected X got Y` | página interna com tipo errado (zerada ou substituída) | **04** |
| `Checksum error on page N` / `checksum error on database page N` | bit-flip ou setor degradado; o FB 2.5 confere o checksum em toda leitura | **04** (`-ignore`) |
| `Page N doubly allocated` | PIP corrompida; risco alto | **04** seção 4 |
| `Orphan page N` | página alocada sem ponteiro de chegada (o `gfix -v` libera) | **04** |
| `Record level errors encountered` | erros em registros (não estrutura) | **04** + considerar **06** |
| `index N is corrupt` | índice corrompido — só recriar resolve | **04**/**05** |
| `transaction X is in limbo` | transação 2PC ou crashada | **07** (limbo) |
| `internal Firebird consistency check (cannot find tip page (N), file: tra.cpp ...)` | TIP corrompida — gfix **não consegue atachar** | **04** (tente `gbak -b -ignore -g` mesmo assim — usa outro caminho de attach) |
| ✔ `bad parameters on attach or create database` + `secondary server attachments cannot validate databases` | `gfix -v` / `-mend` / `-mode` exigem **acesso exclusivo** e há outra conexão aberta | `gfix -shut single -force 0` → validar → `gfix -online`; ou validação online (fbsvcmgr) |
| ✔ `connection lost to database` (ao rodar `gfix -v`) | banco em `full shutdown`: ninguém conecta, nem o gfix | `gfix -online` ou `gfix -online single` (**02**) |
| ✔ `incompatible switch combination` | ordem dos switches: a ação vem primeiro (`gfix -v -full`, não `gfix -full -v`) | `gbak-gfix-gstat-flags.md` |
| `unavailable database` | banco em shutdown ou serviço fora | **02** |
| `lock conflict on no wait transaction` | outro processo segurando o banco | **02** |
| `your user name and password are not defined` | credenciais erradas — SYSDBA/masterkey? | parar, pedir senha |

> **Curioso mas real:** em FB 2.5, `gfix` e `gbak` usam caminhos de attach diferentes no engine. Um pode falhar (`cannot find tip page`) enquanto o outro atacha normalmente. Não desista do `gbak` só porque o `gfix` não atachou.

## Mensagens de gbak

| Mensagem | Causa | Procedure |
|---|---|---|
| `gbak: ERROR: cannot read from database` | corrupção de página durante backup | **04** primeiro, depois **06** |
| `gbak: ERROR: page in page inventory marked as free` | PIP inconsistente | **04** seção 4 |
| `gbak: ERROR: corrupt system metadata` | tabela RDB$ corrompida — grave | **04**/**06** + considerar backup |
| `gbak: ERROR: wrong page type ... expected N got M` (durante dados) | ponteiro de página de dados aponta para página de tipo errado. **`-ignore` não cobre** (só checksum) | **06** ("Caminho FB 2.5"); se persistir em várias tabelas, **04** seção 5b |
| `gbak: ERROR: I/O error during "ReadFile"` + `Final do arquivo alcançado` | leitura passou do fim físico (arquivo **truncado**: confira `tamanho % page_size`) ou setor ilegível | **06**; se múltiplas tabelas, **parar e usar backup** |
| `gbak: ERROR: gds_$receive failed` (depois de erro de leitura) | sintoma de falha de I/O anterior | leia as linhas anteriores no log |
| `gbak: ERROR: attempt to store duplicate value (visible to active transactions) in unique index "X"` | duplicata viola PK/Unique no restore | **05** |
| ✔ `violation of FOREIGN KEY constraint "FK_X" on table "T"` + `Problematic key value is ("COL" = v, ...)` | FK órfã. O 2.5 já mostra a **chave** da órfã — use-a para localizar | **05** seção 4c |
| `cannot commit index FK_X` (restore) | índice da FK ficou pendente (`RDB$INDEX_INACTIVE = 3`) por causa de órfãs | **05** seções 4b/4c |
| `gbak: ERROR: violation of CHECK constraint "CHK_X"` / `validation error for column` | valor viola check/NOT NULL no restore | **05** (`-n` só em último caso: derruba NOT NULL também) |
| `gbak: ERROR: unsuccessful metadata update` | conflito de schema no restore | **05** seção 4 (`-m`) |
| ✔ `"read_only" or "read_write" required` | usou `-mo` achando que era metadata. `-mo` é **MODE**; metadata é `-m` | `gbak-gfix-gstat-flags.md` |
| ✔ `unknown switch "SKIP_DATA"` | `-skip_data` não existe no 2.5 (só 3.0+) | **06** ("Caminho FB 2.5") |
| `expected page size, encountered "..."` | usou `-pa` para senha. No gbak, `-pa` é **page_size**; use `-password` | `gbak-gfix-gstat-flags.md` |
| ✔ `cannot open status and error output file` | `-y <arquivo>` com arquivo que já existe | apague/renomeie o log antes |
| `gbak: ERROR: cannot commit ... database is shutdown` | banco offline | **02** (online) |
| `gbak: warning ...` (massivo) | corrupção espalhada | **04** + **06** |
| `gbak: Exiting before completion due to errors` | gbak abortou; ver linhas acima | conforme erro |

## Mensagens de isql / conexão

| Mensagem | Causa | Procedure |
|---|---|---|
| `Unable to complete network request to host "X"` | servidor fora do ar ou rede | **02** |
| `connection rejected by remote interface` | credenciais ou config errada | **02** |
| `database file specification is invalid` | path errado ou arquivo apagado | **02** |
| `database shutdown` | banco em `gfix -shut` | **02** ou **08** (online) |
| ✔ `SQLSTATE = 08006` / `connection lost to database` | **primeiro confira o `gstat -h`**: banco em `single-user maintenance` com uma conexão já aberta (a 2ª é recusada assim) ou em `full shutdown` (todas recusadas). Acontece depois de restore que falhou. Se o banco está online e o erro persiste num JOIN pesado em `RDB$`, use `SHOW TABLE <nome>;` | **08** seção 0 (`gfix -online`); **05** seção 4c |
| `bad parameters on attach or create database` (gbak/isql) | banco em estado de manutenção/shutdown ou operação que exige exclusividade com outra conexão aberta | `gstat -h`; **08** seção 0 |
| ✔ `Cannot deactivate index used by an integrity constraint` | no 2.5 não dá para desativar índice de PK/FK/UNIQUE por DDL | **05** (use `gbak -c -inactive`) |
| `Implementation limit exceeded` + `Transactions count exceeded. Perform backup and restore to make database operable again` | `Next transaction` atingiu o limite do 2.5 (2³¹−1). Nem o gbak consegue abrir transação | `gfix -mode read_only` (exclusivo) → `gbak -b` → `gbak -c` (contador recomeça) |
| `record from transaction X is stuck in limbo` | limbo | **07** |
| `wrong record length` | metadata diverge do dado (ou RAM ruim) | **05** seção 4 ou **06** |
| `arithmetic exception, numeric overflow, or string truncation` | tipo de dado mudou entre versões ou corrupção | analisar caso a caso |

## Mensagens de fbsvcmgr (validação online)

| Linha | Significado | Procedure |
|---|---|---|
| `Relation N (TABELA) is ok` | tabela e seus índices sem erro | — |
| `Relation N (TABELA) : N ERRORS found` | tabela com páginas/registros/índices ruins (detalhes no `firebird.log`) | **04**; se gbak para nela, **06** |
| `Validation finished` | fim normal; se não aparecer, a validação abortou | ver stderr |

## Mensagens no firebird.log (servidor)

Local em FB 2.5: `C:\Program Files\Firebird\Firebird_2_5\firebird.log`.

| Linha no log | Causa |
|---|---|
| `Record N has bad transaction K in table T (id)` | registro `N` da tabela `T` aponta para transação inválida — aparece nos `record level errors` do gfix; quase sempre cosmético se o `gbak -ignore` passa (**04**) |
| `Page N is an orphan` | página órfã — o `gfix -v` libera |
| `Sweep is started by ...` | sweep automático — normal, mas se trava aqui pode indicar corrupção |
| `Database: <path>, internal gds software consistency check` | corrupção interna grave; geralmente vem com a página identificada |
| `Shutting down the server with active databases` | desligamento sujo — pode causar limbos |
| `bugcheck` | crash do engine; recuperação obrigatória |

## Quando a mensagem não está aqui

Algumas mensagens são genéricas demais para mapear automaticamente. Caminho:

1. Capture a mensagem EXATA com toda a pontuação.
2. Veja em qual ferramenta apareceu (gstat? gbak? aplicação?).
3. Verifique se o `gstat -h` ainda funciona: se sim, dor estrutural no header é improvável; foque na ferramenta que falhou.
4. Se não está claro, vá para **procedure 01** (triagem).

## Códigos de erro numéricos comuns (isc_codes)

| Código | Mnemônico | Causa |
|---|---|---|
| 335544329 | `isc_arith_except` | overflow numérico ou truncamento de string |
| 335544336 | `isc_deadlock` | deadlock entre transações |
| 335544344 | `isc_io_error` | I/O na leitura/escrita do arquivo |
| 335544345 | `isc_lock_conflict` | conflito de lock |
| 335544335 | `isc_db_corrupt` | banco corrupto (genérico) |
| 335544468 | `isc_tra_state` | estado da transação inválido |
| 335544557 | `isc_shutdown` | banco em shutdown |

Para o mapeamento completo: `firebird/include/iberror.h`.
