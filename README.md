# firebird-recovery

Skill do Claude Code para diagnóstico, recuperação e validação de bancos **Firebird 2.5**. Cobre desde o sintoma inicial (`gstat -h` retornando erro) até a reintegração em produção, com passo-a-passo e **fallback explícito** para cada ferramenta usada.

Nasceu de um incidente real com um banco Firebird 2.5 (~440 MB) que caiu por corrupção de 1 byte no header. Foi usada depois em um banco de ~11 GB com múltiplos sítios de corrupção (origem do "sinal de parar cedo" da procedure 04) e num health check de um banco de produção de 1,6 GB (6,46 milhões de registros, 0 perda).

A partir da v1.1.1, os comandos, flags e comportamentos documentados foram **verificados no Firebird 2.5.9** — ajuda das ferramentas, código-fonte do 2.5 e testes em cópias do banco de exemplo `EMPLOYEE.FDB`, inclusive com corrupção provocada de propósito.

## Instalação

### Como plugin do Claude Code (recomendado)

Este repositório é também um marketplace de plugins. Dentro do Claude Code:

```
/plugin marketplace add https://github.com/SamuelCvel/FirebirdRecoverySkill.git
/plugin install firebird-recovery@samuelcvel
```

Pelo terminal: `claude plugin marketplace add https://github.com/SamuelCvel/FirebirdRecoverySkill.git` e `claude plugin install firebird-recovery@samuelcvel`. O atalho `SamuelCvel/FirebirdRecoverySkill` também funciona, mas clona por **SSH** (precisa de chave SSH cadastrada no GitHub); a URL HTTPS funciona em qualquer máquina.

Como plugin, a skill aparece como `/firebird-recovery:firebird-recovery` e aciona sozinha pelos sintomas (custo fixo ~260 tokens por sessão; ~3,5k quando acionada). Atualizações: `claude plugin update firebird-recovery@samuelcvel`.

### Como skill pessoal (cópia)

```powershell
git clone https://github.com/SamuelCvel/FirebirdRecoverySkill.git
Copy-Item -Recurse FirebirdRecoverySkill\skills\firebird-recovery "$HOME\.claude\skills\" -Force
```

Use **uma** forma só (plugin **ou** cópia): com as duas, a skill carrega duas vezes.

### Como `.skill` (claude.ai / compartilhamento)

Cada [Release](https://github.com/SamuelCvel/FirebirdRecoverySkill/releases) traz o `firebird-recovery.skill` (a pasta da skill em zip, gerado pelo CI). Para gerar localmente: `.\tools\Build-SkillPackage.ps1` (saída em `dist/`).

### Para desenvolver

```powershell
.\tools\Install-DevLink.ps1          # ~/.claude/skills/firebird-recovery vira junction para skills/firebird-recovery
git config core.hooksPath .githooks  # trava de termos sensíveis no commit
```

## Estrutura

```
.claude-plugin/          plugin.json + marketplace.json (o repositório é plugin e marketplace)
skills/firebird-recovery/
├── SKILL.md                              porta de entrada + triagem por sintoma
├── procedures/  (8 arquivos 01..08)      passo-a-passo por classe de corrupção
├── scripts/     (10 .ps1 + módulo comum) diagnóstico, reparo, salvamento, restore, health check,
│                                         troca em produção, evidências de ambiente, serviço, demo
├── sql/         (5 helpers)              contagens, sonda de tabelas, FK órfãs, cópia via EDS
├── templates/   (2)                      relatório técnico e mensagem para o cliente
├── references/  (4 docs)                 header ODS 11.2, códigos de erro, cheatsheet, checklist
└── evals/       (evals.json)             casos de teste com assertions
tools/                   empacotador, junction de desenvolvimento, trava de termos sensíveis
.github/workflows/       CI: verificações + pacote .skill nas Releases
```

## Cenários cobertos

| Sintoma observado | Procedure |
|---|---|
| Banco funciona, quero validar (health check) | **08** — `Test-FirebirdHealth.ps1` (4 lentes + relatório; `-SnapshotCopy` com usuários conectados) |
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
3. PRs com correções, novas procedures, ou casos de teste em `skills/firebird-recovery/evals/evals.json` são bem-vindos.
4. **Nunca** inclua nomes reais de clientes, sistemas, tabelas ou caminhos de produção — use nomes genéricos (`BANCO.FDB`, `PEDIDO`, `TABELA_A`). O repositório tem uma trava opcional:

   ```powershell
   git config core.hooksPath .githooks
   # termos proibidos (um regex por linha) ficam em .git/info/sensitive-terms.txt — arquivo local, nunca commitado
   ```

## Roadmap

- [x] Health check automatizado (`Test-FirebirdHealth.ps1`) — v1.2.0
- [x] Troca segura em produção (`Swap-ProductionDatabase.ps1`) e evidências de causa raiz (`Get-FirebirdEnvironmentReport.ps1`) — v1.2.0
- [x] Distribuição como plugin/marketplace do Claude Code e CI com pacote nas Releases — v1.2.0
- [ ] Pump automático por chave com bissecção e salto de faixas ruins (hoje: uma janela por execução).
- [ ] Testes automatizados (Pester), lint (PSScriptAnalyzer) e evals de gatilho (`claude plugin eval`).
- [ ] Adaptar para Firebird 3.0+ (ODS 12/13).

## Licença

MIT — veja [`LICENSE`](LICENSE).
