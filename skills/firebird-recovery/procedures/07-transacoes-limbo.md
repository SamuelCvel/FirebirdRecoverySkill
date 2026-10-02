# 07 — Transações em limbo

**Sintoma característico:** `gbak -b` ou conexões reportam:

- `transaction in limbo`
- `record from transaction N is stuck in limbo`
- `outstanding limbo transaction NNNN`

Acontece quando uma transação distribuída (2-phase commit) ou uma transação durante crash do servidor ficou em estado pendente — nem commitada, nem rolled back. As páginas afetadas não conseguem ser lidas normalmente.

**Causa típica:**
- Crash do servidor Firebird durante commit (queda de energia).
- Crash de aplicação 2PC envolvendo Firebird + outro RM.
- Cópia/move do `.fdb` enquanto o servidor o tinha aberto com transação em vôo.

## Sumário

- [Pré-requisitos](#pré-requisitos)
- [1. Listar limbos](#1-listar-limbos)
- [2. Decidir commit vs rollback (por transação)](#2-decidir-commit-vs-rollback-por-transação)
- [3. Executar a decisão](#3-executar-a-decisão)
- [4. Confirmar fim](#4-confirmar-fim)
- [Fallback](#fallback)
- [Prevenção](#prevenção)

## Pré-requisitos

- Servidor Firebird rodando.
- Senha SYSDBA.
- Procedure 02 executada (cópia + sidecar).

## 1. Listar limbos

```powershell
& "C:\Program Files\Firebird\Firebird_2_5\bin\gfix.exe" -list -user SYSDBA -password <senha> "<banco>"
```

Saída típica quando há limbos:

```
Transaction 123456 is in limbo.
Transaction 123457 is in limbo.
```

Sem limbos: saída vazia, exit 0.

## 2. Decidir commit vs rollback (por transação)

Para cada ID listado, você precisa decidir. **Em dúvida, faça rollback.** É a decisão conservadora: rollback descarta a mudança da transação suspensa; commit a confirma.

### Quando commit é razoável

- A transação rodou durante a operação normal, era curta, e o crash foi externo (energia). Provavelmente o usuário viu "salvo com sucesso" no app antes do crash.
- Um sistema 2PC externo (gerenciador de transação distribuída) já confirmou que o outro RM commitou — siga.

### Quando rollback é a escolha

- Você não tem como confirmar que a transação completou.
- A transação é longa (lote, batch) — repetir vale mais que o risco de estado parcial.
- A aplicação não tem visibilidade de qual era a transação.

### Auto-decisão (cuidado): -two_phase

`gfix -two_phase <ID>` tenta resolver consultando o registro de 2PC. Se a transação não era 2PC, gfix pode rejeitar. Útil em ambientes de TM externo (XA), inútil para FB stand-alone — nesse caso decida você mesmo.

## 3. Executar a decisão

Por transação:

```powershell
$gfix = "C:\Program Files\Firebird\Firebird_2_5\bin\gfix.exe"
$db = "<banco>"

# Commitar uma específica
& $gfix -commit 123456 -user SYSDBA -password <senha> $db

# Rolar de volta uma específica
& $gfix -rollback 123457 -user SYSDBA -password <senha> $db

# Modo interativo: lista e pergunta caso a caso (o -prompt só vale junto com o -list)
& $gfix -list -prompt -user SYSDBA -password <senha> $db
```

O `-list -prompt` mostra cada limbo e pergunta o que fazer com ele. Lembre que no gfix a ação vem primeiro (`-list -prompt`, não `-prompt -list`).

### Resolver todos rapidamente (com decisão tomada)

Se você decidiu que TODOS os limbos vão para a mesma direção, o gfix aceita `all`:

```powershell
& $gfix -rollback all -user SYSDBA -password <senha> $db      # todos rollback (mais conservador)
# & $gfix -commit all -user SYSDBA -password <senha> $db       # todos commit
```

Ou um a um, com registro de cada decisão:

```powershell
$ids = & $gfix -list -user SYSDBA -password <senha> $db | Select-String 'Transaction\s+(\d+)' | ForEach-Object { $_.Matches[0].Groups[1].Value }
foreach ($id in $ids) {
  & $gfix -rollback $id -user SYSDBA -password <senha> $db
  "rollback $id -> exit $LASTEXITCODE"
}
```

### Backup sem resolver o limbo

Se o objetivo imediato é só tirar um backup (antes de decidir), o gbak ignora os limbos com `-limbo`: lê a última versão commitada de cada registro.

```powershell
& "C:\Program Files\Firebird\Firebird_2_5\bin\gbak.exe" -b -v -ignore -g -limbo -user SYSDBA -password <senha> $db "<banco>.com-limbo.fbk"
```

## 4. Confirmar fim

```powershell
& $gfix -list -user SYSDBA -password <senha> "<banco>"
# Saída vazia + exit 0 = OK
```

E execute uma validação final (o `gfix -v` exige acesso exclusivo e devolve exit 0 mesmo com erro — o que vale é a saída vazia):

```powershell
& $gfix -v -full -user SYSDBA -password <senha> "<banco>"
& "<SKILL>\scripts\Salvage-Backup.ps1" -Database "<banco>" -BackupFile "<banco>.pos-limbo.fbk"
```

Se o gbak passa limpo, siga para procedure 08. Se ainda quebra, é outro problema sobreposto (página corrupta?) — volte para procedure 04.

## Fallback

| Falha | Ação |
|---|---|
| `gfix -commit` falha com "record from transaction X is stuck in limbo" no commit | dá rollback nessa em vez |
| `gfix -rollback` falha com "transaction is not in limbo" | já foi resolvida (race com outra ferramenta); ignorar |
| Lista de limbos é enorme (>50) | suspeite de crash mais grave; antes de mass-rollback, considere restore de backup |
| gfix recusa conexão (`unavailable database`) | verificar serviço / banco em shutdown — procedure 02 |

## Prevenção

Não faz parte da recuperação, mas vale reportar ao usuário:

- Nobreak/UPS em servidores Firebird é obrigatório.
- Nunca copiar `.fdb` enquanto o servidor o serve. Use `gbak -b` para backup (formato `.fbk`), o `nbackup -L`/`-N` (cópia física com usuários conectados — procedure 02 seção 1) ou `gfix -shut full -force 0` antes de copiar.
- Se a aplicação usa 2PC, configurar o Transaction Manager para limpar limbos automaticamente após X minutos.
