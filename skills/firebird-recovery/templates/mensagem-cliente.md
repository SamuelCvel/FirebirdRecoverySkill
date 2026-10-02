# Mensagem para o cliente (WhatsApp / e-mail curto)

> Template da skill firebird-recovery. Linguagem de negócio, sem termos técnicos. Troque os `{{...}}`.
> Escolha UM dos blocos de resultado. Números têm que vir dos relatórios — não arredonde para melhor.

---

Olá, {{nome}}! Tudo bem?

Passando o resultado da verificação do banco de dados do sistema {{da empresa / da unidade X}}.

*O que aconteceu*
{{Ex.: Depois da queda de energia do dia DD/MM, o banco de dados ficou com uma parte danificada, o que causava {{erro/lentidão que o usuário via}}.}}

*O que fizemos*
{{Ex.: Fizemos uma cópia de segurança do banco como estava, analisamos o arquivo e reconstruímos um banco novo a partir dessa cópia, conferindo tudo antes de usar.}}

*Resultado* — escolha um:

- ✅ *Nenhum dado foi perdido.* Conferimos as {{N}} tabelas e os {{X milhões de}} registros: o banco novo tem exatamente o mesmo conteúdo do original.
- ⚠️ *Recuperamos {{P}}% dos dados.* Ficaram faltando {{descrição simples: ex. "itens de {{N}} pedidos de DD/MM a DD/MM"}}. Guardamos a lista para conferência.
- ❌ *O arquivo não pôde ser recuperado com segurança.* Vamos restaurar o backup de {{DD/MM}}; o que foi lançado depois disso precisará ser digitado novamente.

*O que precisamos de vocês*
- Uma janela de {{N}} minutos sem ninguém usando o sistema para colocar o banco recuperado em uso: {{sugestão de dia/horário}}.
- {{Ex.: Conferir amanhã cedo os lançamentos de {{área}} e nos avisar se algo estiver diferente.}}

*Para não acontecer de novo*
- {{Ex.: Nobreak no servidor.}}
- {{Ex.: Ajustamos uma configuração de gravação do banco que reduz o risco em quedas de energia.}}
- {{Ex.: Backup automático diário com teste de restauração.}}

Qualquer dúvida, estou à disposição. 👍
