---
description: Restore quebra em FOREIGN KEY - deve acionar a skill
tags: [gatilho, positivo]
max_turns: 4
timeout_seconds: 240
allowed_tools: [Skill, Read, Glob, Grep]
---

O restore (gbak -c) de um backup Firebird 2.5 termina com 'violation of FOREIGN KEY constraint' ao ativar um indice e o banco novo ficou meio inutilizavel. Como faco o restore completar e descubro os registros culpados?
