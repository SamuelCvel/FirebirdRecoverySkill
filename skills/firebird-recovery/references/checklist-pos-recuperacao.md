# Checklist pós-recuperação

Template para usar antes de devolver o banco recuperado para produção. Copie, marque cada item, anexe ao relatório técnico do incidente.

## 1. Validação técnica (4 lentes)

- [ ] `gstat -h` lê o cabeçalho completo (page_size válido, ODS 11.2)
- [ ] `Attributes` mostra `force write` e **nada** de `shutdown`/`maintenance`/`read only`/`backup lock`
- [ ] `Database dialect` igual ao do banco original (normalmente 3)
- [ ] `gfix -v -full` sem **nenhuma** linha de saída (o exit code é 0 mesmo com erro — não basta)
- [ ] `gbak -b -v` (round-trip) completa com "closing file, committing, and finishing"
- [ ] `sql/contagem-objetos.sql`: `INDICES_INATIVOS = 0`, `INDICES_PENDENTES = 0`, demais números iguais ao original
- [ ] `sql/validar-fk-orfas.sql`: todas as FKs com `|0`
- [ ] Nenhum trigger ou constraint desabilitado sem documentação

## 2. Comparação com referência

- [ ] Contagem de tabelas confere com o esperado (anote: esperado __ / obtido __)
- [ ] Contagem de procedures, views e generators confere
- [ ] Contagens de registros das 10 tabelas mais críticas comparadas com backup anterior ou estimativa do usuário
- [ ] Discrepância identificada (se houver) e aceita pelo usuário

## 3. Smoke test funcional

- [ ] Aplicação cliente aponta para o banco recuperado em ambiente isolado (não produção)
- [ ] Login com 2+ usuários representativos funciona
- [ ] Tela de listagem (ex.: pedidos do mês) carrega sem erro
- [ ] Operação de escrita (criar/editar/cancelar registro) funciona e persiste
- [ ] Telas críticas específicas do negócio testadas (anote quais)

## 4. Preparação para deploy

- [ ] Janela de manutenção combinada e comunicada
- [ ] Backup do banco corrompido atual em produção feito (ponto de retorno)
- [ ] Tamanho do recuperado vs produção comparado e diferença explicada
- [ ] Logs de salvamento (.salvage.fbk.log, .restore.log) guardados
- [ ] Sidecars (.hdrbak, .pre-repair.hdrbak) guardados
- [ ] Original corrompido guardado (NÃO apagar)

## 5. Execução do deploy

- [ ] Aplicação parada (todas as instâncias)
- [ ] Serviço Firebird parado OU banco ativo em shutdown
- [ ] Arquivo corrompido renomeado (não apagado): `<nome>.corrompido.<data>`
- [ ] Recuperado movido para o caminho de produção
- [ ] Serviço/banco voltam online
- [ ] Smoke test executado novamente, agora com a aplicação real
- [ ] Liberação dos usuários

## 6. Acompanhamento (24h–48h)

- [ ] `firebird.log` monitorado por mensagens de erro
- [ ] Feedback dos usuários coletado (telas que não abrem, lentidão)
- [ ] Métricas comparadas: throughput, tempo de resposta de query típica
- [ ] Decisão registrada: rollback (e quando), ou manutenção do recuperado

## 7. Retenção de artefatos (≥ 30 dias)

- [ ] Original (renomeado `<nome>.antigo.<data>`, nunca apagado)
- [ ] Cópia de trabalho (`<nome>.work.fdb`) e sidecars (`.hdrbak`, `.pre-repair.hdrbak`, `.flagsbak`)
- [ ] Backup de salvamento `<nome>.salvage.fbk` e o `.fbk` do round-trip
- [ ] Recuperado restaurado `<nome>_RECUPERADO.FDB` (se não virou produção)
- [ ] Logs (`*.fbk.log`, `*.restore.log`, `*.gfix.log`, contagens, sonda, órfãs)
- [ ] Dump forense de linhas apagadas (órfãs/duplicatas), se houve limpeza
- [ ] Relatório técnico do incidente

## 8. Documentação do incidente

- [ ] Sintoma observado registrado
- [ ] Causa raiz identificada e registrada
- [ ] Procedimento executado documentado (procedures usadas, ordem)
- [ ] Perdas (registros, índices recriados, FK órfãs) quantificadas
- [ ] Recomendações para evitar repetição:
  - [ ] UPS/nobreak no servidor
  - [ ] Backup automatizado (`gbak` periódico)
  - [ ] Verificação de hardware (SMART do disco, ECC da RAM)
  - [ ] Monitoramento de `firebird.log` para detecção precoce

## 9. Comunicação

- [ ] Usuário/cliente recebeu relatório técnico
- [ ] Equipe interna comunicada com detalhes técnicos
- [ ] Lições aprendidas registradas em base de conhecimento

---

**Critério de fechamento:** todos os itens das seções 1, 4, 5 e 7 marcados. Seções 3 e 6 fortemente recomendadas. Seção 2 obrigatória se houve uso de `gfix -mend` ou extração tabela-a-tabela.
