# Fase D — arquitetura das páginas institucionais (investigação 2026-11)

## Modelo real do Drupal (neruds.org)

- **Homepage** = Views (`home-panel`, `academic-card`) + template
  `site-main--front` do tema `bico_papagaio`. Conteúdo vem dos 9 bundles
  — os painéis atualizam sozinhos quando editamos conteúdo no app.
- **`node--page`** = 4 páginas finas (Home, Sobre o NERUDS,
  Missão e Visão, Links úteis) — `field_content`/`field_description`
  vazios; são cascas para aliases (/sobre, /links-uteis).
- **Menus** = `menu_link_content` + `menu` (11 menus: Navegação
  principal, Rodapé, Acesso Rápido, Recursos e Dados etc.) — legíveis
  via JSON:API anônima.
- **Blocks** = `block--block` no tema `bico_papagaio` (header/content).
  `block_content` custom content NÃO é exposto na JSON:API.
- **Bundles não gerenciados** descobertos: `boletim`,
  `boletim_periodico`, `relatorio_fno`, `publicacao`.
- Paragraphs habilitado (`paragraphs_type`) mas nenhum type legível
  expõe conteúdo nas páginas.

## Decisão: editor Elementor total = NÃO viável incrementalmente

Layouts institucionais moram em templates de tema + config de Views,
que a JSON:API não edita. Um editor visual paralelo criaria um modelo
fantasma desconectado do Drupal — proibido pelo contrato.

## Fatias viáveis (incrementais, sem modelo paralelo)

1. **Menus manager** — `/manage/menus` list + PATCH de itens (label,
   link, enabled, ordem). Editável de verdade via JSON:API.
2. **`node--page` no /manage** — página institucional como bundle
   (title, field_content, field_description, imagem).
3. **Bundles faltantes** — boletim/relatorio_fno/publicacao nos schemas.
4. **Preview interno** — compor a home a partir dos dados /manage
   (seções atuais) para conferir como o site vai ficar.
