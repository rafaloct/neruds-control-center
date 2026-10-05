---
name: neruds-drupal-content
description: Operar conteúdo do portal NERUDS respeitando a modelagem Drupal, revisão humana e perpetuidade editorial.
---

# NERUDS Drupal Content

Use esta skill para criar ou atualizar conteúdo do neruds.org.

## Regras

- Drupal é a fonte de verdade.
- Nunca inventar um tipo de conteúdo novo sem verificar os bundles existentes.
- Preferir JSON:API para entidades.
- Criar como rascunho por padrão.
- Nunca publicar automaticamente conteúdo produzido por IA.
- Preservar relacionamentos com pesquisadores, projetos, ODS, linhas de pesquisa e territórios.
- Validar anexos, links, autoria e datas antes de enviar para revisão.
- Não armazenar senha Drupal em arquivo do projeto.

## Ordem de trabalho

1. identificar o bundle;
2. ler campos e relacionamentos;
3. preencher somente campos compatíveis;
4. validar obrigatórios;
5. salvar rascunho;
6. mostrar resumo das mudanças;
7. enviar para revisão;
8. publicar somente com permissão adequada.

## Linguagem da interface

Usar rótulos humanos. Exemplo: mostrar “Projeto relacionado” em vez de “field_projeto_relacionado”.
