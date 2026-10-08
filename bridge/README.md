# NERUDS Control Bridge

API FastAPI usada pelo Control Center para integrar o app Flutter ao Drupal,
às missões e à curadoria de oportunidades.

## Desenvolvimento

```bash
uv run fastapi dev
uv run pytest -q
```

Os testes locais do repositório usam:

```bash
bridge/.venv/bin/python -m pytest -q bridge/tests
```

## Missão operacional

O Controle Master preserva as 205 verificações principais e as 73 atividades
complementares da planilha de origem. A API da missão permite filtrar tarefas
atrasadas (`due_status=overdue`) ou previstas para os próximos sete dias
(`due_status=upcoming`), salvar filtros por usuário e consultar o relatório
semanal em `GET /missions/{mission_id}/weekly-report`.

`GET /missions/{mission_id}/export.xlsx` exporta o Controle Master em XLSX,
incluindo responsáveis, revisão cruzada, prazo, evidências e rastreabilidade.

A reatribuição é controlada no backend: apenas sessões com `can_review` podem
alterar `primary_owner`, `cross_reviewer` ou `internal_deadline`. Extensionistas
continuam autorizados a atualizar evidências, fontes, observações, checklists e
etapas operacionais.

### Evidência por arquivo

Além do texto/URL, tarefas aceitam arquivos anexados:

- `POST /mission-tasks/{task_id}/evidence-files` recebe `multipart/form-data`
  com `file` (obrigatório, até 10 MB) e `note` (opcional). O conteúdo vai para
  `data/evidence/{task_id}/`, com sha256 e metadados em `task_evidence_file`,
  e gera evento `evidence_registered` na trilha da tarefa.
- `GET /mission-tasks/{task_id}/evidence-files` lista os anexos (também
  expostos em `GET /mission-tasks/{task_id}` como `evidence_files`).
- `GET /mission-evidence/{id}` devolve o arquivo com `FileResponse`.

## Automação da missão

`GET /missions/{mission_id}/automation` consolida os sinais automáticos da
missão. Tudo é consultivo: nenhuma automação altera etapa, status ou conclui
tarefa sozinha.

- `suggested_tasks`: próximas tarefas P0/P1 abertas, ordenadas por prioridade,
  prazo vencido, responsável e etapa, cada uma com `reason` explicável.
- `missing_evidence`: tarefas a partir de `Evidência registrada` sem texto de
  evidência nem evento com `evidence_url`.
- `possible_duplicates`: grupos internos com mesma URL pública ou título
  normalizado, e tarefas cujo título coincide com rascunho já registrado no
  Drupal (fila de revisão).
- `url_check`: último estado da verificação de URLs públicas, com `issues`
  listando as quebradas e `pending` as ainda não verificadas.

`POST /missions/{mission_id}/url-check?limit=N` verifica um lote de URLs
públicas (padrão 25, máximo 100), priorizando as nunca verificadas e as mais
antigas. A validação reutiliza a proteção SSRF do módulo de fontes RSS e o
resultado fica persistido em `task_url_check`.

`GET /mission-tasks/{task_id}/drupal-duplicates` consulta o JSON:API do Drupal
com o título exato da tarefa no bundle correspondente ao `content_type`,
sinalizando conteúdo já existente no portal antes de criar rascunho.

## Identidade e ciclo de vida de extensionistas

Endpoints sob `/identity` exigem a permissão Drupal
`administer neruds extensionistas` (a sessão do bridge recebe
`can_admin_users` a partir dela). O módulo `neruds_extensionista_guard`
executa as operações de conta server-side — o bridge não precisa de
`administer users` nem de credenciais administrativas.

- `GET /identity/roster` lista as contas com papel `extensionista`,
  enriquecendo cada uma com tarefas abertas da missão, rascunhos pendentes
  e o registro local de offboarding.
- `POST /identity/accounts` provisiona `{name, mail}` com papel
  `extensionista`; sem `password`, o Drupal gera uma senha temporária
  retornada apenas nesta resposta (nunca persistida).
- `POST /identity/accounts/{uid}/status` ativa ou bloqueia a conta.
- `POST /identity/accounts/{uid}/password-reset` devolve um link de reset
  de uso único do Drupal; o link não é armazenado pelo bridge.
- `POST /identity/accounts/{uid}/offboarding` bloqueia a conta, transfere
  as tarefas abertas da missão para `transfer_to`, marca o checklist e
  devolve alertas pendentes (rascunhos, mailbox Poste.io, sessões Drupal).
- `GET|POST /identity/accounts/{uid}/checklist` lê/marca as etapas do
  offboarding; `GET /identity/events` expõe o histórico de quem ocupou
  cada conta operacional.

O histórico local fica em `data/identity.sqlite3` (fora do Git), mantendo
rastro de provisão, bloqueio, reset e offboarding por ator.

## Fluxo editorial

Toda notícia criada pelo bridge é registrada como rascunho e entra na fila de
revisão. O endpoint `GET /content/news/drafts` aceita os filtros `status`,
`mine_only` e `query`; cada item inclui o status, o comentário e o histórico
de decisão.

- O autor pode reenviar o próprio rascunho devolvido, alterando o estado para
  `pending`.
- Apenas perfis com `can_review` podem aprovar ou devolver para ajuste. A
  devolução exige comentário.
- Apenas perfis com `can_publish` podem publicar rascunhos já aprovados.
- A auditoria e os vínculos opcionais com uma oportunidade ou tarefa de missão
  ficam no banco local de revisão.

Os testes em `tests/` cobrem criação, permissões, aprovação, devolução,
reenvio, publicação e os vínculos do rascunho.

## Oportunidades com curadoria humana

`/opportunities` mantém um catálogo de fontes RSS/Atom e permite capturar URLs
oficiais quando não há feed. Cada item conserva fonte, decisões e eventos de
auditoria.

- URLs e títulos normalizados detectam duplicidades entre fontes sem apagar o
  registro recebido; o item duplicado aponta para a referência e não pode criar
  um rascunho.
- O prazo (`deadline_at`) pode ser sugerido na importação ou informado na
  captura manual, revisado pela curadoria e filtrado por `deadline_status`:
  `upcoming` (próximos sete dias) ou `overdue`.
- Tags de aderência ao NERUDS são sugestões revisáveis pela curadoria e ficam
  registradas no evento da decisão.
- A transição para `aprovado_pauta` exige uma sessão com `can_review`; captura,
  triagem, verificação e descarte continuam disponíveis no fluxo operacional.
- A saúde da fonte é calculada como `healthy`, `stale`, `pending` ou `error`
  com base nas últimas tentativas de atualização.
- Mesmo uma pauta aprovada cria somente um rascunho não publicado no Drupal;
  o vínculo com a oportunidade é guardado na fila editorial.

## Operações (serviço, logs, backup)

### Serviço Windows

`bridge\tools\install_bridge_service.ps1` (PowerShell elevado) registra a
tarefa agendada `NERUDSBridge` — gatilho ONSTART como SYSTEM, sem depender de
logon de usuário. Ela executa `bridge_supervisor.ps1`, que mantém o uvicorn
em `127.0.0.1:8787` e o reinicia se o processo cair. Remoção:

```powershell
Unregister-ScheduledTask -TaskName 'NERUDSBridge' -Confirm:$false
```

### Health vs readiness

- `GET /health` — liveness: o processo responde.
- `GET /ready` — readiness: mission store abre e responde a `SELECT 1`;
  retorna 503 quando indisponível. Use `/ready` em monitores externos.

### Logs

`data/logs/access.log` registra uma linha JSON por requisição (método, rota,
status, duração) — nunca corpos, query strings, cookies ou tokens. Rotaciona
diariamente com 14 dias de retenção. `data/logs/supervisor.log` recebe o
stdout do uvicorn quando o serviço roda pelo supervisor.

### Backup e restore

- Backup automático: no arranque e a cada hora o bridge grava
  `data/backups/missions-<timestamp>.sqlite3` quando o último backup tem mais
  de 24 h (cópia consistente via `sqlite3` backup API, segura com WAL).
- Retenção: 14 arquivos (`NERUDS_BACKUP_KEEP` para ajustar).
- Sob demanda (sessão com `can_admin_users`): `POST /ops/backup`,
  `GET /ops/backups`.
- Restore: pare o bridge, substitua `data/missions.sqlite3` pelo backup
  escolhido e inicie de novo. Valide antes com
  `python -c "import sqlite3; c=sqlite3.connect('<arquivo>'); print(c.execute('PRAGMA integrity_check').fetchone())"`.

### Monitoramento

`GET /ops/status` (somente admin) sonda em paralelo: portal Drupal
(`/user/login`), Tailscale Serve (quando `NERUDS_SELF_HEALTH_URL` aponta para
o endpoint tailnet do próprio bridge, ex. `https://host.tailnet:8443/health`),
Poste.io via conexão TCP ao `NERUDS_SMTP_CONNECT_HOST:NERUDS_SMTP_PORT`, e o
mission store. A tela "Administração → Saúde do serviço" exibe os probes e o
último backup.
