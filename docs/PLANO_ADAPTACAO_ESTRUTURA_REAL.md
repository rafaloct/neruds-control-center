# Plano de adaptação — monitoramento do núcleo sobre a estrutura real

Este plano deriva da varredura técnica do portal (Drupal 11.2.12, Drush read-only,
evidência em `data/devin/drupal-scan-result.json`) e substitui a leitura literal
da tabela de inspiração inicial. O aplicativo passa a tratar o núcleo como ele é:
monitoramento de projetos de extensão, publicação de notícias, busca por
congressos/editais/pesquisas e acompanhamento das fichas reais — não um clone
dos formulários de cadastro do Drupal.

## Premissas confirmadas pela varredura

- **JSON:API habilitado**: consultas estruturadas de conteúdo sem scraping.
- **Feeds RSS próprios**: `feed/noticias`, `feed/eventos`, `feed/projetos`,
  `feed/publicacoes` — superfície pronta para "o que mudou no portal".
- **Views públicas de conferência**: `/noticias`, `/eventos`, `/projetos`,
  `/mapa-projetos`, `/publicacoes`, `/pesquisadores`, `/grupos-de-estudos`,
  `/relatorios`, `/reunioes`, `/boletins` e busca em `/busca` (search_api).
- **Campos reais por tipo** (scan): `evento_cientifico` tem data, chamada
  aberta, inscrição e submissão; `projeto_pesquisa_extensao` tem
  `field_status_projeto`, coordenador, datas, municípios, equipe;
  `publicacao_cientifica` concentra as maiores lacunas mensuráveis.
- **Permissões reais**: extensionista/pesquisador criam e editam apenas
  `noticia` e `relatorio` próprios. Demais tipos: monitorar e propor —
  edição sempre no portal.
- **Limites**: workflow de moderação só em `page`; `feeds` não instalado;
  taxonomias `territorios`/`unidade_local_extensao_ule`/`setor_produtivo_cadeia`
  estão vazias; existem pares de campos gêmeos/deprecados (ex.: `field_ods_projeto`
  deprecated, `field_linhas_pesquisa` vs `field_linha_pesquisa`).

## Posição arquitetural

O app vira **quadro de trabalho**: computa o que precisa de atenção a partir de
dados vivos, organiza tarefas/evidências no bridge e encaminha a pessoa para o
formulário real do Drupal na hora de editar. Não replica wizards do portal —
o wizard existente no app permanece apenas para `noticia`, único fluxo cuja
paridade com o formulário real já foi provada por E2E.

Nenhuma fase cria tipo de conteúdo, papel, workflow, módulo ou automação de
publicação no portal.

---

## Fase A — Camada de leitura real no bridge

**Objetivo:** o bridge passa a expor, para o app, somente dados que o Drupal
consegue fornecer por consulta.

1. **Mapa de campos versionado** (`bridge/content_map.json` ou módulo):
   para cada bundle, lista de campos monitoráveis com nome real, label e tipo.
   Resolve explicitamente os pares gêmeos: usa `field_ods` (não o deprecated),
   `field_linhas_pesquisa` onde o bundle o define, etc. O mapa é a única fonte
   de nomes de campo — nada de inferência por convenção.

2. **`GET /portal/lacunas`** (autenticado):
   pagina JSON:API por tipo, computa nós com campo ausente e retorna
   `{type, fields: [{field, label, missing, nodes: [{nid, title, view_url,
   edit_url}]}]}`, com totais. Filtros: `tipo`, `campo` (opcionais; `campo`
   sozinho filtra só os tipos que o renderizam), `limite_nodes`.
   Volume atual é pequeno (169 publicações) — computar no bridge é viável.

3. **`GET /portal/eventos`**:
   lê `evento_cientifico` via JSON:API com `field_data_evento`,
   `field_link_inscricao`, `field_local_evento`, `field_organizadores`,
   `field_descricao_evento` e os campos de chamada/submissão
   (`field_chamada_trabalhos`, `field_link_submissao` — nível de storage,
   retornados quando preenchidos). Ordena por prazo; inclui `days_until`/`past`.
   Alimenta "congressos/submissões".

4. **`GET /portal/feeds`**:
   últimos itens publicados por seção (`noticias`, `eventos`, `projetos`,
   `publicacoes`). Implementado via JSON:API (`sort=-created`) — as views
   RSS do portal (`/feed/*`) existem mas respondem HTTP 500 hoje; se forem
   corrigidas no portal, o endpoint pode migrar para elas sem mudar o
   contrato de seções.

5. **`GET /portal/projetos`**:
   `projeto_pesquisa_extensao` + `acao_extensionista` com status, coordenador,
   datas, municípios e link de conferência (`view_url` para `/projetos`,
   `/mapa-projetos`).

6. **Cache curto** (minutos) + carimbo `fetched_at` em toda resposta, para o app
   sempre mostrar a data da consulta.

**Gate:** cada endpoint coberto por teste com fixture JSON:API; nenhum campo
consultado fora do mapa versionado; nada de write — fase 100% de leitura.

---

## Fase B — Reorientação das telas do app

**Objetivo:** o Início deixa de ser card fixo e vira "o que precisa de atenção
hoje", derivado dos endpoints da Fase A.

1. **Início = painel de atenção**:
   - prazos de evento/submissão vencendo (de `/portal/eventos`);
   - fila editorial pendente (endpoint existente);
   - top lacunas por tipo (de `/portal/lacunas`);
   - últimas novidades do portal (de `/portal/feeds`).

2. **Aba Monitoramento** (nova ou evolução do Inventário):
   - seções por eixo real: **Projetos/Ações**, **Eventos**, **Publicações**,
     **Notícias**;
   - por item: título, estado real, lacunas do próprio node, `view_url` da view
     pública certa (não só `/node/N/edit`) e botão "editar no portal";
   - filtros por taxonomias que existem e têm termos (ODS, linha de pesquisa,
     eixo, microrregião, município, status de projeto). Taxonomias vazias
     (território etc.) não aparecem como filtro.

3. **"Nova ficha" honesto**: por tipo, botão que abre `/node/add/<bundle>` real
   no portal. Sem wizard paralelo. Tipos que a conta não pode criar (via
   permissões reais já expostas pela sessão) aparecem desabilitados ou ocultos.

4. **Retorno ao tracking** (best-effort, sem promessa de sync):
   após "nova ficha", a tarefa do app aceita colar a URL/nid da ficha criada
   para vincular — vínculo manual explícito, já suportado pelo modelo de
   evidência.

5. **Conteúdo/notícia**: wizard próprio permanece somente aqui (paridade
   provada); demais tipos encaminham ao portal.

**Gate:** nenhuma tela exibe campo que não exista no mapa; links de edição
apontam para formulário real; estados vazios explicam a causa (sem dados,
sem permissão, portal indisponível).

---

## Fase C — Tarefas nascidas das lacunas reais

**Objetivo:** lacuna computada vira trabalho atribuível, sem inventar conteúdo.

1. **Sugestão de tarefa a partir de lacuna**: na lista de lacunas, botão
   "criar tarefa" pré-preenche missão com `target_nid`, campo faltante,
   responsável e próxima ação ("conferir fonte", "preencher no portal").
   A tarefa continua no contrato existente de missão/evidência.

2. **Reconciliação**: ao salvar/concluir, o app reconsulta o node; se o campo
   já foi preenchido no portal, a tarefa mostra "lacuna resolvida no portal"
   — conferência real, não crença no estado local.

3. **Duplicatas**: sinalização dos DOIs repetidos conhecidos
   (`10.20435/inter.v24i3.3499` em 4 tipos) como candidata a conferência —
   sem fusão/exclusão automática.

**Gate:** nenhuma tarefa conclui por efeito colateral; reconciliação sempre
reconsulta o Drupal; duplicata é sinalização, nunca ação.

---

## Fora de escopo (todas as fases)

- Replicar wizards/formulários do Drupal no app (exceto `noticia`, já provada).
- Criar tipo, papel, workflow, módulo `feeds`, indicadores ou cadastros no portal.
- Edição de projetos/publicações/perfis pelo app — permissões reais não permitem.
- Automação de publicação ou de conclusão de tarefa.
- Métricas institucionais fixas ou estimadas.

## Ordem de implementação sugerida

1. **A** primeiro: semântica de dados correta é pré-requisito das telas.
2. **B** em duas entregas: painel de atenção; depois Monitoramento por eixo.
3. **C** por último: depende de A+B estáveis.

Cada fase sai em branch temática com testes de contrato (bridge) e testes de
widget (app), seguindo o fluxo Issue→PR→checks→revisão→decisão do ROADMAP.
Nada deste plano toca produção além de leituras já públicas/autenticadas.
