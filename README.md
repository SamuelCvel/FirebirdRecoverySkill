# firebird-recovery

Skill do Claude Code para diagnóstico e recuperação de bancos **Firebird 2.5** corrompidos. Cobre desde o sintoma inicial (`gstat -h` retornando erro) até a reintegração em produção, com passo-a-passo e **fallback explícito** para cada ferramenta usada.

Nasceu de um incidente real com um banco Firebird 2.5 (~440 MB) que caiu por corrupção de 1 byte no header. Foi validada em outro incidente real de escala maior (banco de ~11 GB com múltiplos sítios de corrupção) — o segundo caso, aliás, foi o motivo do surgimento do "sinal de parar cedo" documentado na procedure 04.

## Instalação

### Como skill do Claude Code (uso local)

Copie a pasta `skill/` para `~/.claude/skills/firebird-recovery/`:

```powershell
Copy-Item -Recurse skill\* "$HOME\.claude\skills\firebird-recovery\" -Force
```

O Claude Code detecta e a skill fica ativa automaticamente. Verifica invocando `/firebird-recovery` ou apenas descrevendo um problema Firebird — ela aciona sozinha pelos sintomas.

### Como `.skill` portável (compartilhamento)

Envie `dist/firebird-recovery.skill` para colegas — instalação por drag-and-drop no claude.ai ou copiando para a pasta de skills do Claude Code de destino.

## Estrutura

```
skill/
├── SKILL.md                              porta de entrada + tabela de triagem
├── procedures/  (8 arquivos 01..08)      passo-a-passo por classe de corrupção
├── scripts/     (7 .ps1)                 Diagnose/Repair/Salvage/Restore/Service/Demo
├── sql/         (4 helpers)              contagem, FK órfãs, páginas ruins, salvage
├── references/  (4 docs)                 ODS 11.2 layout, códigos de erro, cheatsheet, checklist
└── evals/       (evals.json)             casos de teste automatizados

dist/
└── firebird-recovery.skill               pacote assinado, pronto para distribuir
```

## Cenários cobertos

| Sintoma observado | Procedure |
|---|---|
| `gstat -h`: `unable to allocate memory from operating system` | **03** — header corrompido (page_size) |
| `wrong page type`, `checksum error` em página específica | **04** — páginas corrompidas |
| Restore quebra em índice único, FK ou check constraint | **05** — índices e restrições |
| `gbak -b` para numa tabela específica | **06** — salvamento tabela-a-tabela |
| `transaction in limbo` após crash | **07** — transações em limbo |
| 3+ sítios de corrupção independentes (hardware failing) | **04 seção 5b** — sinal de parar cedo |
| Sintoma ambíguo | **01** — triagem |

## Como funciona

Todo procedimento segue este contrato:

1. **Sintoma → procedimento** decidido pela tabela em `SKILL.md` (sem chute).
2. **Comandos concretos** (PowerShell, gstat, gfix, gbak, isql) — copie e cole.
3. **Fallback explícito por ferramenta** — se um comando falha, o próximo passo é claro.
4. **Verificação 4-lentes** antes de declarar sucesso: `gstat -h`, `gfix -v -full`, `gbak -b` limpo, `isql` (contagens conferem).
5. **Reversibilidade**: toda escrita binária grava sidecar (`.hdrbak`) antes.

## Compatibilidade

- **Firebird 2.5 SuperServer, Windows 11** — validado com casos reais.
- Firebird 2.0/2.1 — a maior parte funciona (mesmo ODS 11.x).
- Firebird 3.0+ — trate como base; ajustes: `-shut` mudou sintaxe de modos, `-skip_data` só existe a partir do 3.0 (documentado nos scripts).
- InterBase 7.x — arquitetura similar mas comandos podem diferir.

## Uso rápido no Claude Code

```
"Meu banco Firebird não abre. gstat -h retorna 'unable to allocate memory'.
 Arquivo em C:\Dados\banco.fdb"
```

A skill aciona sozinha, roda a triagem (procedure 01), identifica como caso de header corrompido (procedure 03), sugere `scripts/Diagnose-FirebirdHeader.ps1` e conduz até o restore final com o `Restore-Clean.ps1`.

Ou invoque explicitamente: `/firebird-recovery C:\caminho\banco.fdb`.

## Contribuindo

Bugs, novos casos, ou correções são bem-vindos.

1. Abra issue descrevendo o **sintoma exato** (mensagem literal do gstat/gfix/gbak).
2. Se possível, informe qual procedure/script foi acionada e onde falhou.
3. PRs com correções, novas procedures, ou casos de teste em `skill/evals/evals.json` são bem-vindos.

## Roadmap

- [ ] Adaptar para Firebird 3.0+ (ODS 12, `-skip_data` nativo, `gbak -restore-multi-file`).
- [ ] Suportar InterBase 7.x (páginas similares, comandos diferentes).
- [ ] Script auxiliar de agendamento de backup (evitar cair no cenário "não tenho .fbk recente").
- [ ] Detecção de hardware failing pelos padrões de log (`chkdsk`, SMART, WHEA-Logger).

## Licença

MIT — veja [`LICENSE`](LICENSE).
