---
description: gbak falha com pagina corrompida - deve acionar a skill
tags: [gatilho, positivo]
max_turns: 4
timeout_seconds: 240
allowed_tools: [Skill, Read, Glob, Grep]
---

No Firebird 2.5, o gbak -b para no meio com 'database file appears corrupt' e 'wrong page type' lendo uma das tabelas grandes. Preciso salvar o maximo de dados possivel. Por onde comeco?
