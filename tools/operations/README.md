# Operação Windows

Estes procedimentos são para o **LARGeo** e exigem separação entre preparação
de código e mutações administrativas no Windows.

## Pré-requisitos

1. Repositório atualizado em `D:\AI-Shared\neruds-control-center`.
2. Ambiente Python criado com:

```powershell
cd D:\AI-Shared\neruds-control-center\bridge
uv sync
```

No Windows, o `uv sync` instala `pywin32` por marcador de plataforma.

3. Tailscale Serve deve continuar apontando:

```text
largeo.tail2faed0.ts.net:8443 -> http://127.0.0.1:8787
```

## Serviço Windows

Abra **PowerShell como Administrador** somente após autorização operacional e
execute:

```powershell
.\tools\operations\install_bridge_service.ps1
```

O script:

- instala/atualiza o serviço `NERUDS-Control-Bridge` no Service Control Manager;
- usa a identidade `LocalSystem`;
- inicia automaticamente no boot;
- configura recovery com até três reinícios;
- executa Uvicorn apenas em `127.0.0.1:8787`;
- valida `/ready` antes de declarar sucesso;
- remove automaticamente uma instalação recém-criada se o primeiro readiness falhar.

Depois valide:

```powershell
Get-Service NERUDS-Control-Bridge
Invoke-RestMethod http://127.0.0.1:8787/health
Invoke-RestMethod http://127.0.0.1:8787/ready
tailscale serve status --json
```

O launcher legado em Startup só deve ser removido **depois** de o serviço e o
Tailscale Serve estarem comprovadamente saudáveis.

Para remover o serviço:

```powershell
.\tools\operations\remove_bridge_service.ps1
```

## Backup automático

O backup usa a API de backup online do SQLite, valida
`PRAGMA integrity_check` e gera um SHA-256 ao lado do arquivo.

Para criar um backup manual:

```powershell
.\tools\operations\backup_mission_store.ps1
```

Para registrar a tarefa diária das 02:00 como SYSTEM, abra PowerShell elevado e
execute:

```powershell
.\tools\operations\install_maintenance_tasks.ps1
```

Destino padrão:

`D:\NERUDS-Backups`

A cópia para armazenamento externo e a política de retenção devem seguir a
política institucional; o script não envia arquivos a terceiros.

## Ensaio de restauração

A restauração é fail-closed: o script recusa substituir o banco enquanto o
serviço `NERUDS-Control-Bridge` estiver em execução.

Procedimento:

1. escolha uma janela de manutenção ou uma cópia isolada;
2. pare o serviço;
3. restaure;
4. inicie o serviço;
5. confirme `/ready`;
6. confirme o dashboard da missão.

Exemplo:

```powershell
Stop-Service NERUDS-Control-Bridge
.\tools\operations\restore_mission_store.ps1 -BackupFile D:\NERUDS-Backups\missions-AAAAmmddTHHMMSSZ.sqlite3
Start-Service NERUDS-Control-Bridge
Invoke-RestMethod http://127.0.0.1:8787/ready
```

O restaurador valida a integridade do backup e cria uma cópia
`before-restore` do banco anterior.

## Observabilidade

Endpoints públicos de liveness/readiness:

- `GET /health`
- `GET /ready`

Endpoints técnicos restritos a sessão com `can_publish`:

- `GET /infra/status`
- `GET /mail/status`
- `GET /operations/incidents`

O painel Administração do Flutter é somente leitura e também exige
`can_publish`.

O monitor de Tailscale Serve considera saudável apenas o proxy configurado em
`NERUDS_TAILSCALE_SERVE_HOST` apontando exatamente para
`NERUDS_TAILSCALE_SERVE_TARGET`.

## Logs

O logger operacional grava JSONL rotacionado em `logs/bridge.jsonl` por
padrão:

- 5 MiB por arquivo;
- 10 backups;
- sem cookies, tokens, passwords, CSRF ou Authorization em campos estruturados.

Não registrar payloads de autenticação, headers ou conteúdo de sessão em
mensagens de log.
