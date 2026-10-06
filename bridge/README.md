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
