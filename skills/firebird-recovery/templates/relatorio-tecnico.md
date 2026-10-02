# Relatório técnico — {{TITULO}} ({{DATA}})

> Template da skill firebird-recovery. Troque os `{{...}}` e apague as seções que não se aplicam.
> Use números dos logs e dos relatórios do `Test-FirebirdHealth` — nada de estimativa sem dizer que é estimativa.
> Não coloque senhas no relatório.

## 1. Resumo

- **Situação:** {{uma frase: o que estava acontecendo para o usuário}}
- **Resultado:** {{recuperado sem perda / recuperado com perda de N registros / não recuperável — restaurado do backup de DD/MM}}
- **Banco em produção agora:** {{arquivo e origem: recuperado em DD/MM HH:MM}}
- **Pendências:** {{ex.: janela de troca, conferência pelos usuários, hardware}}

## 2. Ambiente

| Item | Valor |
|---|---|
| Servidor / SO | {{máquina, Windows}} |
| Firebird | {{versão do servidor (fbsvcmgr info_server_version), arquitetura}} |
| Banco | {{caminho, tamanho, page size, ODS, dialect}} |
| Forced writes | {{ligado/desligado (gstat -h → Attributes)}} |
| Evidências de ambiente | {{resumo do Get-FirebirdEnvironmentReport: disco, eventos, desligamentos, antivírus}} |

## 3. Sintoma

- Mensagem exata: `{{erro}}`
- Quando começou / o que aconteceu antes: {{queda de energia, cópia com o serviço no ar, disco cheio...}}
- Backup disponível: {{sim — data/local / não}}

## 4. Diagnóstico (antes da intervenção)

| Lente | Resultado |
|---|---|
| gstat -h | {{ok / page_size inválido / ...}} |
| Validação (online ou gfix -v -full) | {{N erros; tabelas afetadas}} |
| gbak -b | {{ok / quebra na tabela X: mensagem}} |
| Contagens / órfãs | {{tabelas ilegíveis, FKs órfãs}} |

Classe da corrupção: {{header / páginas / índices e constraints / tabela específica / limbo}} — procedure {{NN}}.

## 5. Causa provável

{{o que as evidências indicam e com que grau de certeza; ex.: desligamento inesperado em DD/MM HH:MM + forced writes desligado}}

## 6. Procedimento executado

| Quando | O que | Resultado |
|---|---|---|
| {{DD/MM HH:MM}} | Cópia de trabalho (procedure 02) | {{tamanho conferido}} |
| {{...}} | {{procedure / script / comando}} | {{saída relevante}} |

## 7. Resultado (depois)

| Lente | Resultado |
|---|---|
| gstat -h | {{Attributes: force write; dialect igual ao original}} |
| gfix -v -full | {{saída vazia}} |
| gbak round-trip | {{ok, N bytes, T s}} |
| Objetos | {{tabelas/views/procedures/triggers/generators/índices — iguais ao original}} |
| Registros | {{total antes x depois; diferença por tabela}} |
| FKs órfãs | {{0}} |

## 8. Perdas e alterações nos dados

- {{nenhuma}} — ou, por tabela: {{tabela, quantidade, faixa de chaves, motivo}}
- Linhas apagadas na limpeza de órfãs/duplicatas: {{N}} — dump forense em `{{arquivo}}`
- Constraints/índices recriados ou alterados: {{lista}}

## 9. Recomendações

- [ ] Forced writes ligado em produção (`gfix -write sync`).
- [ ] Nobreak (UPS) com desligamento automático do servidor.
- [ ] Backup diário com `gbak` (fora do horário de uso) **e restauração de teste** periódica.
- [ ] Health check periódico (`Test-FirebirdHealth.ps1`).
- [ ] Antivírus: exclusão da pasta dos bancos, das extensões e do executável do Firebird.
- [ ] Espaço livre no volume do banco (≥ 3× o tamanho do banco).
- [ ] {{hardware: disco/RAM, se as evidências apontarem}}

## 10. Anexos e retenção (≥ 30 dias)

- Relatórios `*.health-*.md` / `.json`, `ambiente-firebird-*.md`
- Logs: `*.fbk.log`, `*.restore.log`, `*.gfix.log`, contagens, dumps forenses
- Arquivos guardados: original (`*.antigo.<data>`), cópia de trabalho, `.fbk` de salvamento
