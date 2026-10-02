---
description: Transacoes em limbo apos queda de energia - deve acionar a skill
tags: [gatilho, positivo]
max_turns: 4
timeout_seconds: 240
allowed_tools: [Skill, Read, Glob, Grep]
---

Depois de uma queda de energia, o gfix -list no nosso Firebird mostra 3 transacoes em limbo e algumas telas do sistema travam. Como resolvo isso com seguranca?
