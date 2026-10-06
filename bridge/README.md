# NERUDS Control Bridge

API FastAPI usada pelo Control Center para integrar o app Flutter ao Drupal,
às missões e à curadoria de oportunidades.

## Desenvolvimento

```bash
uv run fastapi dev
uv run pytest -q
```

## Missão operacional

O Controle Master preserva as 205 verificações principais e as 73 atividades
complementares da planilha de origem. A API da missão permite filtrar tarefas
atrasadas (`due_status=overdue`) ou previstas para os próximos sete dias
(`due_status=upcoming`), salvar filtros por usuário e consultar o relatório
semanal em `GET /missions/{mission_id}/weekly-report`.

`GET /missions/{mission_id}/export.xlsx` exporta o Controle Master em XLSX,
incluindo responsáveis, revisão cruzada, prazo, evidências e rastreabilidade.
