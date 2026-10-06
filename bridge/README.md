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
