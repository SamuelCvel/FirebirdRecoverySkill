# Cheatsheet — flags importantes de gbak, gfix, gstat

Foco em recuperação. Lista as flags que **realmente** importam neste contexto; flags de operação rotineira foram omitidas para reduzir ruído.

Convenção em todos os comandos: `-user SYSDBA -password <senha>`.

## gstat

`gstat <db>` — abre o arquivo direto, não conecta no servidor. Não precisa de credenciais.

| Flag | O que faz | Quando usar |
|---|---|---|
| `-h` | mostra header da página 0 | sempre, primeiro passo |
| `-a` | analisa todas as páginas; mostra distribuição por tabela/índice | inventário pós-recuperação |
| `-d` | análise de páginas de dados | profiling de fragmentação |
| `-i` | análise de índices | detectar índices inchados |
| `-r` | estatísticas de registros | comparações antes/depois |
| `-s` | inclui tabelas de sistema | raramente útil |
| `-t <table>` | restringe a uma tabela | quando suspeita de tabela específica |
| `-z` | mostra versão do gstat | sanity check |

Exemplo: `gstat -h C:\path\BANCO.FDB` → cabeçalho.

## gfix

`gfix <flags> <db>` — conecta via servidor. Precisa do server no ar e credenciais.

### Validação / reparo

| Flag | O que faz | Risco |
|---|---|---|
| `-v` | validação read-only (relatório) | baixo |
| `-v -full` | validação completa incluindo páginas órfãs | baixo (só lê) |
| `-mend` | tenta marcar páginas corruptas como deletadas | **destrutivo** — usa cópia |
| `-mend -ignore` | mend ignorando checksums | **destrutivo** |
| `-mend -full -ignore` | mend agressivo | **destrutivo** — último recurso |
| `-no_update` | só relata, não corrige | reforça que é read-only |
| `-i[gnore]` | ignora erros de checksum durante outras operações | seguro |

### Estado do banco

| Flag | O que faz | Uso típico |
|---|---|---|
| `-shut -force <n>` | shutdown forçado em N segundos (0 = imediato) | isolar banco para escrita binária |
| `-shut single -force <n>` | shutdown em modo single-user | só dono pode conectar |
| `-shut multi -force <n>` | shutdown em modo multi-user (lock parcial) | manutenção limitada |
| `-online` | devolve banco para produção (limpa shutdown) | depois de patch/repair |
| `-online normal` | igual `-online` | idem |
| `-online single` | só single-user | manutenção |

### Transações em limbo

| Flag | O que faz | Quando |
|---|---|---|
| `-list` | lista todas as transações em limbo | sempre antes de decidir |
| `-list -limbo` | mesmo que `-list` (limbo é default) | idem |
| `-commit <ID>` | commita uma transação em limbo | quando confirmado |
| `-rollback <ID>` | rolla back uma | escolha conservadora |
| `-prompt` | percorre os limbos perguntando c/r/g | listas longas |
| `-two_phase <ID>` | tenta resolver via protocolo 2PC | em ambiente XA |

### Outras úteis

| Flag | O que faz |
|---|---|
| `-write sync` | liga force write (recomendado em produção) |
| `-write async` | desliga force write (NÃO recomendado) |
| `-buffers <n>` | ajusta page buffers do cache |
| `-sweep` | dispara sweep manualmente |
| `-housekeeping <n>` | define intervalo de sweep automático |

## gbak

`gbak <flags> <origem> <destino>` — conecta via servidor.

### Backup (`-b`)

| Flag | O que faz | Quando usar |
|---|---|---|
| `-b` | modo backup (gera .fbk) | sempre |
| `-v` | verbose (uma linha por tabela/etapa) | em recuperação, **sempre** (log) |
| `-ignore` | ignora erros de checksum | suspeita de corrupção (procedure 04) |
| `-g` | desliga garbage collection durante o backup | suspeita ou banco grande lento |
| `-l` | inclui shadows no backup | raro |
| `-t` | inclui transactions in limbo no backup | raro |
| `-mo` (`-metadata`) | backup só de metadata (sem dados) | recriar banco vazio com schema |
| `-co` | converte external para internal | raro |
| `-nt` | non-transportable (binário, mais rápido) | só intra-versão |
| `-skip_data <regex>` | exclui dados das tabelas que casam (**FB 3.0+ APENAS** — não existe em 2.5) | procedure 06 (FB 3.0+) |
| `-include_data <regex>` | inclui só dados das tabelas que casam (**FB 3.0+ APENAS**) | seletivo (FB 3.0+) |

> **Atenção FB 2.5:** o `gbak` do 2.5.9 **não** aceita `-skip_data` nem `-include_data` (testado). Se você precisa pular uma tabela problemática no 2.5, o caminho é **dropá-la** antes do backup — veja procedure 06.
| `-y <log>` | redireciona verbose para arquivo | alternativa a `*> log` no shell |

Combinação canônica para salvamento: `gbak -b -v -ignore -g`.

### Restore (`-c`)

| Flag | O que faz | Quando usar |
|---|---|---|
| `-c` | modo restore — cria novo banco | sempre |
| `-r` | replace — sobrescreve destino existente | cuidado |
| `-v` | verbose | sempre em recuperação |
| `-i` (`-inactive`) | indices ficam inactive no destino | procedure 05 |
| `-o` (`-one_at_a_time`) | commit por tabela | quando 1 tabela falha, salva o resto |
| `-mo` (`-metadata`) | só estrutura, sem dados | criar destino vazio |
| `-n` (`-no_validity`) | ignora check constraints | quando há dado violando check |
| `-bu <n>` | page buffers (cache) | bancos grandes — usar `-bu 10000` |
| `-p <size>` | page_size do destino | se quer mudar (ex.: 8192→16384) |
| `-k` (`-kill`) | mata shadows antes | raro |
| `-fix_fss_data <CHARSET>` | corrige UTF8 corrompido (raro) | só se sabe que precisa |
| `-fix_fss_metadata <CHARSET>` | idem para metadata | idem |

Combinação canônica para restore problemático: `gbak -c -v -i -o`.

### Comuns a backup e restore

| Flag | O que faz |
|---|---|
| `-user <U>` | usuário (SYSDBA tipicamente) |
| `-password <P>` | senha |
| `-role <R>` | role |
| `-se <host:service>` | conecta via service manager (admin) |
| `-z` | versão do gbak |

## Exit codes

Todos retornam 0 = sucesso, ≠ 0 = falha. Mas a "falha" pode ser parcial:

- **gbak**: exit 0 com warnings no log ainda é considerado sucesso. ERROR + Exit ≠ 0 = falha real.
- **gfix**: exit 0 + nenhuma saída = limpo. Exit ≠ 0 ou saída com mensagens = problema.
- **gstat**: exit 0 + saída lida = ok.

## Caminho-padrão no shell PowerShell

```powershell
$gstat = "C:\Program Files\Firebird\Firebird_2_5\bin\gstat.exe"
$gfix  = "C:\Program Files\Firebird\Firebird_2_5\bin\gfix.exe"
$gbak  = "C:\Program Files\Firebird\Firebird_2_5\bin\gbak.exe"
$isql  = "C:\Program Files\Firebird\Firebird_2_5\bin\isql.exe"
```
