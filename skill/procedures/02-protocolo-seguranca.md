# 02 — Protocolo de segurança

Esta procedure é **obrigatória antes de qualquer escrita** no arquivo do banco — ela cobre cópia de evidência, sidecar de backup, gestão do serviço e detecção de locks. Se você pular, vai descobrir tarde que perdeu a única cópia.

## 1. Cópia de evidência (sempre primeiro)

O arquivo corrompido é evidência forense. Manter intacto permite:
- Tentar outro caminho de recuperação se o primeiro falhar.
- Comparar antes/depois para entender a corrupção.
- Análise externa se for o caso.

```powershell
$src = "<caminho do arquivo corrompido>"
$work = ($src + ".work.fdb")   # cópia de trabalho
Copy-Item -LiteralPath $src -Destination $work -Force
(Get-Item $work).Length -eq (Get-Item $src).Length   # deve ser True
```

**Regra:** todas as ações de escrita (patch binário, gfix -mend, gbak -b, gbak -c) operam **na cópia**, nunca no original. Só renomeie/substitua o original na etapa final, depois de tudo verificado.

### Fallback

- **Disco sem espaço para a cópia:** identifique outro disco/pasta, e use-o como destino. Se não houver, ofereça compactar com 7-Zip (`7z a archive.7z arquivo`) ou usar disco externo.
- **Cópia falha com "arquivo em uso":** o servidor Firebird está com o banco aberto. Vá para a seção 3 (estado do serviço).

## 2. Sidecar de backup binário

Antes de **qualquer** escrita binária no header (offset 0x10-0x11, flags, etc.), grave os bytes originais em um sidecar de texto ASCII:

```
<arquivo.fdb>.hdrbak     ← formato: PAGESIZE=16384
<arquivo.fdb>.flagsbak   ← formato: FLAGS=0
```

Os scripts `Repair-FirebirdHeader.ps1` e `Demo-CorrupcaoHeader.ps1` já fazem isso automaticamente. Se for editar manualmente com hex editor, faça antes do edit:

```powershell
$f = "C:\path\BANCO.FDB"
$fs = [IO.File]::Open($f,'Open','Read'); $b = New-Object byte[] 2
[void]$fs.Seek(16,'Begin'); [void]$fs.Read($b,0,2); $fs.Close()
$ps = [BitConverter]::ToUInt16($b,0)
"PAGESIZE=$ps" | Set-Content "$f.hdrbak"
```

## 3. Estado do serviço Firebird

Confirme o que está rodando:

```powershell
Get-Service | Where-Object Name -like 'Firebird*' | Format-Table Name, Status -AutoSize
```

Você precisa entender 3 cenários:

### 3.a) Servidor está rodando e o banco corrompido NÃO é servido por ele

Cenário típico: banco em uma pasta de trabalho `\Recuperar\`. Nesse caso **não pare o serviço**. Você pode operar diretamente na cópia: ler com `gstat`, gravar com FileStream exclusivo (FileShare.None), tudo sem afetar produção.

### 3.b) Servidor está rodando e o banco corrompido É a produção ativa

Duas opções, da menos para a mais disruptiva:

**Preferida — isolar só este banco (`gfix -shut`):**

```powershell
# Tira só este banco de linha. Os outros bancos do servidor continuam atendendo.
.\scripts\Firebird-Service.ps1 -Database "<caminho>" -Action shutdown
```

Internamente: `gfix -shut -force 0 -user SYSDBA -password <senha> <db>`. Para devolver depois: `-Action online` (`gfix -online`).

Por que essa é a preferida: produção segue no ar; pedaços de aplicação que usam outros bancos não param.

**Alternativa — parar o serviço inteiro:**

```powershell
.\scripts\Firebird-Service.ps1 -Action stop    # requer Administrador
# ... operar no arquivo ...
.\scripts\Firebird-Service.ps1 -Action start
```

Use somente em janela de manutenção. Para a Guardian primeiro (senão ela reinicia o server em 10s).

### 3.c) Servidor não está rodando

Pode operar à vontade no arquivo. Lembre que `gfix`, `gbak` e `isql` precisam do servidor no ar para conectar — vai precisar subi-lo para essas etapas.

```powershell
.\scripts\Firebird-Service.ps1 -Action start
```

## 4. Detecção de lock antes de gravar

Tente abrir o arquivo em modo exclusivo. Se levantar exceção, é lock:

```powershell
try {
  $fs = [IO.File]::Open("<arquivo>", 'Open', 'ReadWrite', [IO.FileShare]::None)
  $fs.Close()
  Write-Host "OK: arquivo livre para escrita exclusiva." -ForegroundColor Green
} catch {
  Write-Warning "Arquivo em uso. Volte para a seção 3 e escolha isolamento."
}
```

Se travar mesmo com serviço parado: pode ser outro processo (cópia em andamento, antivírus indexando, IBExpert aberto). Use `Get-Process` ou `handle.exe` (Sysinternals) para identificar.

## 5. Verificações ambientais

Antes de seguir para a procedure específica, confirme:

| Item | Comando | OK se |
|---|---|---|
| Espaço em disco | `Get-PSDrive C \| Select Free` | livre ≥ 3× o tamanho do banco (cópia + .fbk + restaurado) |
| Versão do Firebird | `& "C:\Program Files\Firebird\Firebird_2_5\bin\gstat.exe" -z` | retorna 2.5.x |
| Senha do SYSDBA | tentar `gstat` com `-user SYSDBA -password masterkey` | exit 0 (se falhar, pedir senha real ao usuário) |
| Permissões na pasta | `Get-Acl "<pasta>" \| Format-List` | usuário tem Read+Write |

### Fallback

- **Disco apertado:** ofereça gravar `.fbk` e o banco restaurado em outro volume; aceita-se rodar `gbak -b` direto para outro disco passando o caminho destino completo.
- **Versão diferente (2.0/2.1):** maior parte funciona; use `-Z` para confirmar e cite na conversa com o usuário que estamos em modo de melhor esforço.
- **Senha SYSDBA desconhecida:** PARE. Não tente força bruta. Pergunte ao usuário; se nem ele souber, leve para reset do `security2.fdb` (fora do escopo desta procedure — outro caminho, mais arriscado).
- **Sem permissão de escrita:** rode o terminal como Administrador ou peça acesso; não modifique ACLs sem autorização.

## 6. Estado pronto para a próxima procedure

Antes de chamar a próxima procedure, você deveria ter:

- ✅ Cópia de trabalho criada e tamanho conferido.
- ✅ Sidecar `.hdrbak` (se for tocar no header).
- ✅ Decisão consciente sobre isolamento (gfix -shut, Stop-Service, ou nenhum).
- ✅ Arquivo abre em modo exclusivo (ou explicação por que não precisa).
- ✅ Espaço, versão, credenciais e permissões confirmadas.

Se faltar qualquer um, volte aqui e resolva. Esta procedure existe justamente para evitar que correções "rápidas" virem incidentes em cascata.
