# NERUDS Control Bridge

Bridge FastAPI entre o painel Flutter, o Drupal e os controles locais do NERUDS.

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
- A saúde da fonte é calculada como `healthy`, `stale`, `pending` ou `error`
  com base nas últimas tentativas de atualização.
- Mesmo uma pauta aprovada cria somente um rascunho não publicado no Drupal;
  o vínculo com a oportunidade é guardado na fila editorial.

## Desenvolvimento

```bash
uv run fastapi dev
```

Os testes locais do repositório usam:

```bash
bridge/.venv/bin/python -m pytest -q bridge/tests
```
