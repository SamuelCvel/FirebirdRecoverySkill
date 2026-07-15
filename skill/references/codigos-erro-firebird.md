# Mensagens de erro → causa provável → procedure

Tabela de consulta rápida. Para cada mensagem típica que aparece em `gstat`, `gfix`, `gbak`, `isql` ou no log do servidor (`firebird.log`), aponta para a causa mais provável e a procedure que cobre o caminho.

Use Ctrl+F para localizar a mensagem que você está vendo.

## Mensagens de gstat

| Mensagem | Causa | Procedure |
|---|---|---|
| `unable to allocate memory from operating system` (gstat -h) | page_size inválido no header — gstat tentou alocar buffer impossível | **03** (header) |
| `cannot open database file` (gstat) | arquivo inacessível: lock pelo servidor, permissão, caminho errado | **02** (segurança/serviço) |
| `I/O error during "open" operation` (gstat) | arquivo movido, em uso, ou disco com erro | **02** |
| `not a valid database` / `wrong page type` na pag 0 | header destruído ou arquivo não é Firebird | **03** seção 5 |

## Mensagens de gfix

| Mensagem | Causa | Procedure |
|---|---|---|
| `Database file appears corrupt` | corrupção genérica detectada | **04** |
| `Wrong page type. Page N. Expected X got Y` | página interna com tipo errado (zerada ou substituída) | **04** |
| `Checksum error on page N` | bit-flip ou setor degradado naquela página | **04** |
| `Page N doubly allocated` | PIP corrompida; risco alto | **04** seção 4 |
| `Orphan page N` | página alocada sem ponteiro de chegada | **04** |
| `Record level errors encountered` | erros em registros (não estrutura) | **04** + considerar **06** |
| `index N is corrupt` | índice corrompido — só recriar resolve | **04**/**05** |
| `transaction X is in limbo` | transação 2PC ou crashada | **07** (limbo) |
| `internal Firebird consistency check (cannot find tip page (N), file: tra.cpp ...)` | TIP (Transaction Inventory Page) corrompida — gfix **não consegue atachar** | **04** (mas: tente `gbak -b -ignore -g` mesmo assim — `gbak` usa caminho de attach diferente e às vezes funciona quando `gfix` falha) |
| `unavailable database` | banco em shutdown ou serviço fora | **02** |
| `lock conflict on no wait transaction` | outro processo segurando o banco | **02** |
| `your username and password are not defined` | credenciais erradas — SYSDBA/masterkey? | parar, pedir senha |

> **Curioso mas real:** em FB 2.5, `gfix` e `gbak` usam caminhos de attach diferentes no engine. Um pode falhar (`cannot find tip page`) enquanto o outro atacha normalmente. Não desista do `gbak` só porque `gfix` não atachou.

## Mensagens de gbak

| Mensagem | Causa | Procedure |
|---|---|---|
| `gbak: ERROR: cannot read from database` | corrupção de página durante backup | **04** primeiro, depois **06** |
| `gbak: ERROR: page in page inventory marked as free` | PIP inconsistente | **04** seção 4 |
| `gbak: ERROR: corrupt system metadata` | RDB$ table corrompida — grave | **04**/**06** + considerar backup |
| `gbak: ERROR: wrong page type ... expected N got M` (durante backup de dados) | ponteiro de página de dados aponta para página de tipo errado. **`-ignore` NÃO cobre este erro** (cobre só checksum) | **04** + **06** drop+recreate; se persistir em tabela grande, considerar parar |
| `gbak: ERROR: I/O error during "ReadFile"` + `Final do arquivo alcançado` durante leitura de uma tabela | leitura passou do EOF físico OU setor ilegível dentro do range de uma tabela | **06** drop+recreate a tabela; se múltiplas tabelas afetadas, **parar e usar backup** |
| `gbak: ERROR: gds_$receive failed` (depois de erro de leitura) | erro interno após qualquer falha de I/O — sintoma, não causa | leia as linhas anteriores no log para a causa raiz |
| `gbak: ERROR: attempt to store duplicate value (visible to active transactions) in unique index "X"` | duplicata viola PK/Unique no restore | **05** (índices) |
| `gbak: ERROR: violation of FOREIGN KEY constraint "FK_X"` | FK órfã no restore | **05** |
| `gbak: ERROR: violation of CHECK constraint "CHK_X"` | valor viola check no restore | **05** + limpar dado |
| `gbak: ERROR: unsuccessful metadata update` | conflito de schema no restore | **05** seção 4 (-mo) |
| `gbak: ERROR: cannot commit ... database is shutdown` | banco offline | **02** (online) |
| `gbak: warning ... gbak: warning ... gbak: warning` (massivo) | corrupção espalhada | **04** + **06** |
| `gbak: Exiting before completion due to errors` | gbak abortou; ver linhas acima para identificar | conforme erro |

## Mensagens de isql / conexão

| Mensagem | Causa | Procedure |
|---|---|---|
| `Unable to complete network request to host "X"` | servidor fora do ar ou rede | **02** |
| `connection rejected by remote interface` | credenciais ou config errada | **02** |
| `database file specification is invalid` | path errado ou arquivo apagado | **02** |
| `database shutdown` | banco em `gfix -shut` | **02** ou **08** (online) |
| `record from transaction X is stuck in limbo` | limbo | **07** |
| `wrong record length` | metadata diverge do dado | **05** seção 4 ou **06** |
| `arithmetic exception, numeric overflow, or string truncation` | tipo de dado mudou entre versions ou corrupção | analisar caso a caso |

## Mensagens no firebird.log (servidor)

Local em FB 2.5: `C:\Program Files\Firebird\Firebird_2_5\firebird.log` (ou `interbase.log` em IB).

| Linha no log | Causa |
|---|---|
| `Sweep is started by ...` | sweep automático — normal, mas se trava aqui pode indicar corrupção |
| `Database: <path>, internal gds software consistency check` | corrupção interna grave; geralmente vem com page X identificada |
| `Shutting down the server with active databases` | desligamento sujo — pode causar limbos |
| `bugcheck` | crash do engine; recuperação obrigatória |

## Quando a mensagem não está aqui

Algumas mensagens são genéricas demais para mapear automaticamente. Caminho:

1. Capture a mensagem EXATA com toda a pontuação.
2. Veja em qual ferramenta apareceu (gstat? gbak? aplicação?).
3. Verifique se o `gstat -h` ainda funciona: se sim, dor estrutural é improvável; foque na ferramenta que falhou.
4. Se não está claro, vá para **procedure 01** (triagem).

## Códigos de erro numéricos comuns (isc_codes)

| Código | Mnemônico | Causa |
|---|---|---|
| 335544329 | `isc_arith_except` | overflow numérico ou truncamento de string |
| 335544336 | `isc_deadlock` | deadlock entre transações |
| 335544344 | `isc_io_error` | I/O na leitura/escrita do arquivo |
| 335544345 | `isc_lock_conflict` | conflito de lock |
| 335544347 | `isc_corrupt_log_rec` | log corrompido (raro em FB) |
| 335544335 | `isc_db_corrupt` | banco corrupto (genérico) |
| 335544468 | `isc_tra_state` | estado da transação inválido |
| 335544557 | `isc_shutdown` | banco em shutdown |

Para o mapeamento completo: `firebird/include/iberror.h`.
