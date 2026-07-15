---
name: firebird-recovery
description: Diagnostica e recupera bancos Firebird/InterBase 2.x (.fdb, .gdb, .ib) corrompidos ou inacessíveis. ACIONAR quando (a) o usuário pedir para recuperar/consertar/diagnosticar banco Firebird; (b) sintomas como "unable to allocate memory", "wrong page type", "checksum error", "I/O error", "database shutdown", "transaction in limbo", "wrong record length", "cannot find tip page"; (c) falha de gstat/gfix/gbak/isql; (d) suspeita de corrupção em .fdb/.gdb/.ib mesmo sem pedir skill explicitamente. Cobre header corrompido (page_size, ODS), páginas com checksum/page type inválido, índices/constraints quebrando restore, salvamento tabela-a-tabela quando gbak para (drop+recreate em FB 2.5 já que -skip_data é FB 3.0+), transações em limbo, sinal de parar cedo em corrupção massiva, checklist pós-recuperação. Cada procedure traz passo-a-passo com fallback explícito. Use também para diagnóstico ("por que gstat retorna unable to allocate?") e treinamento/demo sobre corrupção em Firebird.
---

# Firebird Recovery (Firebird 2.5 / ODS 11.2)

Esta skill orquestra a recuperação de bancos Firebird/InterBase corrompidos. Cobre desde a corrupção de 1 byte no header (caso real) até falhas que exigem extração tabela-a-tabela. Todo procedimento tem **fallback explícito** para quando a ferramenta principal falha.

Foco: **Firebird 2.5 (ODS 11.2)**. Muito da técnica vale para FB 2.0/2.1; FB 3.0+ tem on-disk diferente — confirme ODS antes de aplicar.

Resposta sempre em **pt-BR** (preferência do usuário).

---

## Princípios não-negociáveis

Estes 5 princípios precedem qualquer comando. Quebrá-los já piorou recuperações antes.

1. **Nunca opere sobre o original.** Primeiro ato é sempre uma cópia de segurança. O arquivo corrompido é evidência forense — você pode precisar dele de novo se o primeiro caminho de recuperação falhar.
2. **Diagnostique antes de tocar.** Identifique a *classe* da corrupção (header? página? índice? metadata?) antes de escolher a ferramenta. Aplicar `gfix -mend` num header corrompido, por exemplo, não funciona porque o `gfix` nem consegue atachar.
3. **Reversibilidade.** Toda alteração binária direta no arquivo grava um sidecar (`.hdrbak`, `.bytesbak`) com os bytes originais. Se a correção for pior que o problema, dá para voltar.
4. **Quatro lentes na verificação.** Sucesso só é declarado quando `gstat -h`, `gfix -v -full`, `gbak -b` (backup completo) e `isql` (contagens conferem) **todos** passam. Cada um detecta um tipo diferente de problema; um sozinho não basta.
5. **Menos invasivo primeiro.** Esta ordem é deliberada: `gfix -shut` (banco) antes de `Stop-Service` (servidor); `-ignore` antes de `-mend`; `gbak` backup+restore antes de patch binário; extração via `isql` antes de mexer em bytes.

---

## Triagem rápida (sintoma → procedure)

Use esta tabela ANTES de qualquer comando. O sintoma decide o caminho.

| Sintoma observado | Causa típica | Procedure |
|---|---|---|
| `gstat -h` retorna *"unable to allocate memory from operating system"* | page_size inválido no header | **03-header-corrompido** |
| ODS version inválido / banco "não é Firebird" | header destruído | **03-header-corrompido** |
| `wrong page type`, `checksum error`, `page X is of wrong type` | corrupção em página de dados/índice/PIP | **04-paginas-corrompidas** |
| `consistency check` em página específica | mesma — corrupção de página | **04-paginas-corrompidas** |
| `gbak -c` (restore) falha em índice/constraint/FK | dado inconsistente impede recriar índice único / FK | **05-indices-restricoes** |
| `record format not found` durante restore | metadata vs dados divergiram | **05-indices-restricoes** |
| `gbak -b` para numa tabela específica com erro | uma tabela tem páginas ruins; outras estão ok | **06-tabelas-individuais** |
| `transaction is in limbo`, `outstanding limbo transaction` | crash de servidor durante 2PC ou cópia indevida | **07-transacoes-limbo** |
| `database shutdown`, `not available`, `lock conflict on no wait transaction` | banco offline ou serviço/estado, não corrupção | **02-protocolo-seguranca** (seção "estado do serviço") |
| `I/O error during read/write` em offset específico | disco com setor ruim ou arquivo truncado | **02-protocolo-seguranca** → **04-paginas-corrompidas** |
| Sintoma ambíguo ou múltiplos erros misturados | precisa entrevistar | **01-triagem** |

Se houver dúvida, **sempre comece por 01-triagem** para conduzir a entrevista e levantar artefatos antes de escolher o caminho.

---

## Fluxo padrão de recuperação

Independente do tipo de corrupção, o fluxo macro é o mesmo:

```
01-triagem (se sintoma incerto)
    ↓
02-protocolo-seguranca       (cópia, isolamento, servico/estado)
    ↓
03 ou 04 ou 05 ou 06 ou 07   (procedimento específico)
    ↓
Salvage-Backup (gbak -b -ignore -g)        ← scripts/Salvage-Backup.ps1
    ↓
Restore-Clean (gbak -c)                    ← scripts/Restore-Clean.ps1
    ↓
08-pos-recuperacao            (4 lentes + reintegração)
```

Cada procedure abaixo detalha o que muda no meio dessa linha geral.

---

## Procedures (procedures/)

Carregue **apenas a procedure** correspondente ao sintoma — não leia todas. Cada uma é independente.

| Arquivo | Quando usar | O que entrega |
|---|---|---|
| `procedures/01-triagem.md` | sintoma ambíguo / múltiplos erros | roteiro de entrevista, leitura inicial do header, decisão da próxima procedure |
| `procedures/02-protocolo-seguranca.md` | **sempre, antes de qualquer escrita** | cópia, sidecars de backup, gestão do serviço/isolamento, prevenção de retrabalho |
| `procedures/03-header-corrompido.md` | sintoma clássico de page_size inválido ("unable to allocate") | inspeção hex, scan de page_size real, patch reversível |
| `procedures/04-paginas-corrompidas.md` | checksum/page type errados, I/O errors | `gfix -v -full`, `-mend -ignore`, gbak com `-ignore` |
| `procedures/05-indices-restricoes.md` | restore para por FK/PK/unique | restore em 2 fases (`-i`/`-o`), limpeza de duplicatas, rebuild manual |
| `procedures/06-tabelas-individuais.md` | gbak para numa tabela específica | salvamento tabela-a-tabela via isql com FIRST/SKIP, criação de DB destino |
| `procedures/07-transacoes-limbo.md` | "transaction in limbo" | `gfix -list -limbo`, `-commit`/`-rollback`, prevenção |
| `procedures/08-pos-recuperacao.md` | depois que o restore voltou | verificação 4-lentes, comparação de contagens, plano de reintegração em produção |

---

## Scripts (scripts/)

Scripts PowerShell prontos. Todos têm `-WhatIf`/confirmação onde fazem escrita e geram log na pasta do banco.

| Script | Função | Quando chamar |
|---|---|---|
| `scripts/Diagnose-FirebirdHeader.ps1` | leitura RO do header + scan de page_size real + `gstat -h` | sempre, primeiro passo de qualquer suspeita |
| `scripts/Repair-FirebirdHeader.ps1` | corrige page_size por sidecar `.hdrbak` ou por scan; reversível | procedure 03 |
| `scripts/Salvage-Backup.ps1` | `gbak -b -v -ignore -g` com log, grep de erros, resumo | depois do diagnóstico |
| `scripts/Restore-Clean.ps1` | `gbak -c -v` com log + verificação 4-lentes pós-restore | depois do salvage backup |
| `scripts/Salvage-TableByTable.ps1` | extrai dados tabela-a-tabela via isql com FIRST/SKIP | procedure 06, quando gbak falha em uma tabela |
| `scripts/Firebird-Service.ps1` | start/stop do serviço; `gfix -shut`/`-online` para isolar 1 banco | qualquer escrita binária no arquivo |
| `scripts/Demo-CorrupcaoHeader.ps1` | demonstração reversível: corrupta, diagnostica, corrige | treinamento de equipe |

Todos os scripts aceitam `-User`/`-Password` (padrão SYSDBA/masterkey) e `-GstatPath`/`-GfixPath`/`-GbakPath`/`-IsqlPath` (padrões em `C:\Program Files\Firebird\Firebird_2_5\bin\`).

### Convenção comum entre os scripts

- **Logs**: `<basename>.<script>.log` ao lado do banco.
- **Sidecars de backup binário**: `<basename>.<campo>.bak` (ex.: `BANCO.FDB.hdrbak`).
- **Saídas coloridas**: vermelho para corrupção, verde para sucesso, amarelo para próximo passo recomendado.
- **Exit codes**: 0 sucesso; 1 erro previsto/parametrizável; 2 ferramenta externa falhou; 3 estado de serviço/lock impede continuar.

---

## SQL helpers (sql/)

| Script | Para que serve |
|---|---|
| `sql/contagem-objetos.sql` | conta tabelas/views/procedures/generators — comparar antes/depois |
| `sql/encontrar-paginas-ruins.sql` | usa `MON$RECORD_STATS` e `MON$IO_STATS` (FB 2.5+) para apontar suspeitos |
| `sql/validar-fk-orfas.sql` | encontra registros que vão quebrar FK no `gbak -c` |
| `sql/gerar-script-salvage.sql` | gera comandos `INSERT INTO destino SELECT ...` para salvamento tabela-a-tabela |

---

## Referências (references/)

Consulta passiva. Carregue só quando o procedure pedir.

- `references/ods11-header-layout.md` — layout byte-a-byte da página 0 (ODS 11.2). Necessário para edição manual do header.
- `references/codigos-erro-firebird.md` — tabela: mensagem de erro → causa provável → procedure indicada.
- `references/gbak-gfix-gstat-flags.md` — cheatsheet das flags importantes (`-ignore`, `-g`, `-mend`, `-shut`, etc.).
- `references/checklist-pos-recuperacao.md` — lista de verificação antes de devolver o banco para produção.

---

## Quando pedir ajuda humana (parar e perguntar)

Não automatize por automatizar. Pare e converse com o usuário quando:

1. **Não tem backup recente.** Antes de aplicar `-mend` ou patch binário, confirme que o usuário tem outra cópia. Se for o único arquivo, redobre o cuidado.
2. **Banco está em produção ativa.** Confirme janela de manutenção; ofereça `gfix -shut` por DB em vez de parar o serviço inteiro.
3. **Sintomas de hardware** (`I/O error`, setores ruins, RAM ECC reportando). Pode ser inútil recuperar sem trocar o hardware primeiro.
4. **Restore mostra perda de registros (>0,1%)**. Reporte ao usuário e pergunte se aceita ou quer tentar caminho alternativo (extração tabela-a-tabela).
5. **Senha do SYSDBA não é masterkey**. Não force; peça.

---

## Compatibilidade

Validado em: **Firebird 2.5 SuperServer, Windows 11**. Boa parte funciona em 2.0/2.1 (mesmo ODS 11.x); para FB 3.0+ confirme ODS e ajuste comandos `gfix -shut` (mudou a sintaxe de modos).

InterBase 7.x compartilha boa parte da arquitetura de página, mas comandos podem diferir — trate como semelhante, não idêntico.
