# Operação Windows

Execute os scripts elevados, no LARGeo, a partir da raiz do repositório.

1. Execute `uv sync` em `bridge/` para criar `bridge\.venv`.
2. Instale a tarefa de serviço: `.\tools\operations\install_bridge_service.ps1`.
   Ela roda como `SYSTEM`, inicia no boot, reinicia até três vezes e mantém o
   Uvicorn limitado a `127.0.0.1:8787`; não depende de login de usuário.
3. Instale o backup diário: `.\tools\operations\install_maintenance_tasks.ps1`.
4. Verifique localmente `http://127.0.0.1:8787/health` e
   `http://127.0.0.1:8787/ready`, e pela tailnet o endpoint `/health`.

## Ensaio de restauração

Pare a tarefa `NERUDS-Control-Bridge`, escolha um arquivo `.sqlite3` em
`D:\NERUDS-Backups` e execute:

```powershell
.\tools\operations\restore_mission_store.ps1 -BackupFile D:\NERUDS-Backups\missions-AAAAmmddTHHMMSSZ.sqlite3
```

O restaurador valida a integridade do backup, cria uma cópia do banco atual com
`before-restore` e só então substitui o arquivo. Inicie a tarefa novamente e
confirme `/ready`. Faça esse ensaio em cópia ou janela de manutenção.

## Incidentes

`GET /operations/incidents` exige sessão do Control Center e expõe somente
nomes de serviços e códigos estáveis: Tailscale/Tailscale Serve, Drupal e
Poste.io. Não inclui cookies, tokens, senhas, conteúdo de requisições ou dados
de usuários.
