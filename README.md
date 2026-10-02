# firebird-recovery

Skill do Claude Code para diagnóstico, recuperação e validação de bancos **Firebird 2.5**. Cobre desde o sintoma inicial (`gstat -h` retornando erro) até a reintegração em produção, com passo-a-passo e **fallback explícito** para cada ferramenta usada.

Nasceu de um incidente real com um banco Firebird 2.5 (~440 MB) que caiu por corrupção de 1 byte no header. Foi usada depois em um banco de ~11 GB com múltiplos sítios de corrupção (origem do "sinal de parar cedo" da procedure 04) e num health check de um banco de produção de 1,6 GB (6,46 milhões de registros, 0 perda).

A partir da v1.1.1, os comandos, flags e comportamentos documentados foram **verificados no Firebird 2.5.9** — ajuda das ferramentas, código-fonte do 2.5 e testes em cópias do banco de exemplo `EMPLOYEE.FDB`, inclusive com corrupção provocada de propósito.

## Instalação

### Como skill do Claude Code (uso local)

Copie a pasta `skill/` para `~/.claude/skills/firebird-recovery/`:

```powershell
Copy-Item -Recurse skill\* "$HOME\.claude\skills\firebird-recovery\" -Force
```

O Claude Code detecta e a skill fica ativa automaticamente. Verifique invocando `/firebird-recovery` ou apenas descrevendo um problema Firebird — ela aciona sozinha pelos sintomas.

### Como `.skill` portável (compartilhamento)

`dist/firebird-recovery.skill` é a pasta da skill compactada em zip (sem assinatura), pronta para enviar a colegas — upload no claude.ai ou cópia para a pasta de skills do Claude Code de destino.

## Estrutura

```
skill/
├── SKILL.md                              porta de entrada + triagem por sintoma
├── procedures/  (8 arquivos 01..08)      passo-a-passo por classe de corrupção
├── scripts/     (7 .ps1 + módulo comum)  Diagnose/Repair/Salvage/Restore/TableByTable/Service/Demo
├── sql/         (5 helpers)              contagens, sonda de tabelas, FK órfãs, cópia via EDS
├── references/  (4 docs)                 header ODS 11.2, códigos de erro, cheatsheet, checklist
└── evals/       (evals.json)             casos de teste com assertions

dist/
└── firebird-recovery.skill               a pasta skill/ em zip
```

## Cenários cobertos

| Sintoma observado | Procedure |
|---|---|
| Banco funciona, quero validar (health check) | **08** — 4 lentes |
| `gstat -h`: `unable to allocate memory from operating system` | **03** — header corrompido (page_size) |
| `wrong page type`, `checksum error` em página específica | **04** — páginas corrompidas |
| `gfix -v` com centenas de erros, mas o sistema funciona | **04** seção 2 — quase sempre cosmético |
| Restore quebra em índice único, FK ou check constraint | **05** — índices e restrições |
| `connection lost to database` / `bad parameters on attach` depois de restore | **08** seção 0 — banco em `single-user maintenance` |
| `gbak -b` para numa tabela específica | **06** — salvamento tabela-a-tabela (por chave, via EDS) |
| `transaction in limbo` após crash | **07** — transações em limbo |
| 3+ sítios de corrupção independentes (hardware falhando) | **04 seção 5b** — sinal de parar cedo |
| Sintoma ambíguo | **01** — triagem |

## Como funciona

Todo procedimento segue este contrato:

1. **Sintoma → procedimento** decidido pela tabela em `SKILL.md` (sem chute).
2. **Comandos concretos** (PowerShell, gstat, gfix, gbak, isql, fbsvcmgr, nbackup) — copie e cole.
3. **Fallback explícito por ferramenta** — se um comando falha, o próximo passo é claro.
4. **Verificação 4-lentes** antes de declarar sucesso: `gstat -h`, `gfix -v -full`, `gbak -b` limpo, `isql` (contagens e órfãs conferem).
5. **Reversibilidade**: toda escrita binária grava sidecar (`.hdrbak`) antes; nada é sobrescrito sem chave explícita.

## Compatibilidade

- **Firebird 2.5 SuperServer, Windows 11** — verificado no 2.5.9 e em casos reais.
- **Windows PowerShell 5.1 e PowerShell 7** — scripts testados nos dois.
- Firebird 2.0/2.1 — a maior parte funciona (mesmo ODS 11.x). Validação online exige 2.5.4+.
- Firebird 3.0+ — on-disk diferente (ODS 12/13, sem checksum de página), `-skip_data` nativo (3.0+) e `-include_data` (4.0+). Fora do escopo por enquanto.
- InterBase 7.x — arquitetura similar mas comandos podem diferir.

## Uso rápido no Claude Code

```
"Meu banco Firebird não abre. gstat -h retorna 'unable to allocate memory'.
 Arquivo em C:\Dados\banco.fdb"
```

A skill aciona sozinha, roda a triagem (procedure 01), identifica como caso de header corrompido (procedure 03), roda `scripts/Diagnose-FirebirdHeader.ps1` e conduz até o restore final com o `Restore-Clean.ps1`.

Ou invoque explicitamente: `/firebird-recovery C:\caminho\banco.fdb`.

## Contribuindo

Bugs, novos casos, ou correções são bem-vindos.

1. Abra issue descrevendo o **sintoma exato** (mensagem literal do gstat/gfix/gbak).
2. Se possível, informe qual procedure/script foi acionada e onde falhou.
3. PRs com correções, novas procedures, ou casos de teste em `skill/evals/evals.json` são bem-vindos.
4. **Nunca** inclua nomes reais de clientes, sistemas, tabelas ou caminhos de produção — use nomes genéricos (`BANCO.FDB`, `PEDIDO`, `TABELA_A`). O repositório tem uma trava opcional:

   ```powershell
   git config core.hooksPath .githooks
   # termos proibidos (um regex por linha) ficam em .git/info/sensitive-terms.txt — arquivo local, nunca commitado
   ```

## Roadmap

- [ ] Health check automatizado (`Test-FirebirdHealth.ps1`: 4 lentes + diff de contagens + relatório).
- [ ] Pump automático por chave com bissecção e salto de faixas ruins (hoje: uma janela por execução).
- [ ] Troca segura em produção (`Swap-ProductionDatabase.ps1`) e coleta de evidências de causa raiz.
- [ ] Distribuição como plugin/marketplace do Claude Code, testes (Pester) e CI.
- [ ] Adaptar para Firebird 3.0+ (ODS 12/13).

## Licença

MIT — veja [`LICENSE`](LICENSE).
