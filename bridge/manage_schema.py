"""Schemas de gestão de conteúdo (gateway /manage).

Cada bundle descreve os campos que o app precisa renderizar — o Flutter
constrói formulários dinâmicos a partir destas definições, então setores
novos aparecem no app assim que o schema é cadastrado aqui, sem rebuild.

`kind` suportados pelo formulário universal:
  text, longtext, number, email, link, date, daterange, bool,
  reference (entity_reference → node bundle ou taxonomy vocabulary),
  image, file
"""

from __future__ import annotations

from typing import Any


def _f(
    name: str,
    label: str,
    kind: str = "text",
    *,
    required: bool = False,
    target: str | None = None,
    multiple: bool = False,
    hint: str | None = None,
) -> dict[str, Any]:
    field: dict[str, Any] = {
        "name": name,
        "label": label,
        "kind": kind,
        "required": required,
    }
    if target:
        field["target"] = target  # "node:perfil_pesquisador" ou "taxonomy_term:linhas_pesquisa"
    if multiple:
        field["multiple"] = True
    if hint:
        field["hint"] = hint
    return field


MANAGE_SCHEMAS: dict[str, dict[str, Any]] = {
    "noticia": {
        "label": "Notícias",
        "label_singular": "Notícia",
        "icon": "newspaper",
        "fields": [
            _f("title", "Título", required=True),
            _f("field_resumo_noticia", "Resumo", "longtext"),
            _f("body", "Texto", "longtext"),
            _f("field_data_noticia", "Data da notícia", "date", required=False),
            _f("field_autor_noticia", "Autor da notícia"),
            _f("field_link_noticia", "Link da notícia", "link"),
            _f("field_fonte_externa", "Fonte externa", "link"),
            _f("field_imagem_destaque", "Imagem de destaque", "image"),
            _f("field_pdf", "Arquivos PDF", "file", multiple=True),
            _f(
                "field_projeto_associado",
                "Projeto associado",
                "reference",
                target="node:projeto_pesquisa_extensao",
            ),
            _f(
                "field_linha_pesquisa",
                "Linha de pesquisa",
                "reference",
                target="taxonomy_term:linhas_pesquisa",
            ),
            _f(
                "field_tags",
                "Tags",
                "reference",
                target="taxonomy_term:tags",
                multiple=True,
            ),
        ],
    },
    "evento_cientifico": {
        "label": "Eventos",
        "label_singular": "Evento científico",
        "icon": "event",
        "fields": [
            _f("title", "Título", required=True),
            _f("field_descricao_evento", "Descrição", "longtext"),
            _f("field_data_evento", "Data do evento", "date", required=False),
            _f("field_local_evento", "Local", required=False),
            _f("field_organizadores", "Organizadores"),
            _f("field_link_inscricao", "Link de inscrição", "link"),
            _f("field_link_submissao", "Link para submissão", "link"),
            _f("field_chamada_trabalhos", "Chamada de trabalhos aberta", "bool"),
            _f("field_imagem_destaque", "Banner", "image"),
        ],
    },
    "projeto_pesquisa_extensao": {
        "label": "Projetos",
        "label_singular": "Projeto",
        "icon": "folder",
        "fields": [
            _f("title", "Título", required=True),
            _f("field_coordenador", "Coordenador", required=False),
            _f("field_resumo", "Resumo", "longtext"),
            _f("field_descricao_projeto", "Descrição", "longtext"),
            _f("field_justificativa", "Justificativa", "longtext"),
            _f("field_objetivos", "Objetivos", "longtext"),
            _f("field_metodologia", "Metodologia", "longtext"),
            _f("field_data_inicio", "Data de início", "date"),
            _f("field_data_fim", "Data de fim", "date"),
            _f("field_local_execucao", "Local de execução"),
            _f(
                "field_equipe_pesquisa",
                "Equipe",
                "reference",
                target="node:perfil_pesquisador",
                multiple=True,
            ),
            _f(
                "field_linhas_pesquisa",
                "Linhas de pesquisa",
                "reference",
                target="taxonomy_term:linhas_pesquisa",
                multiple=True,
            ),
            _f(
                "field_status_projeto",
                "Status do projeto",
                "reference",
                target="taxonomy_term:status_projeto",
            ),
            _f(
                "field_tipo_projeto",
                "Tipo de projeto",
                "reference",
                target="taxonomy_term:tipo_projeto",
            ),
            _f("field_imagens_projeto", "Galeria", "image", multiple=True),
            _f("field_pdf", "Arquivos PDF", "file", multiple=True),
        ],
    },
    "perfil_pesquisador": {
        "label": "Pesquisadores",
        "label_singular": "Pesquisador",
        "icon": "person",
        "fields": [
            _f("title", "Título do perfil", required=True,
               hint="Como o perfil aparece nas listagens"),
            _f("field_nome_completo", "Nome completo", required=False),
            _f("field_email", "E-mail", "email", required=False),
            _f("field_biografia", "Biografia/Resumo", "longtext"),
            _f("field_foto_perfil", "Foto do perfil", "image"),
            _f("field_lattes", "Currículo Lattes", "link"),
            _f("field_orcid_id", "ORCID iD"),
            _f("field_google_scholar", "Google Scholar", "link"),
            _f("field_linkedin", "LinkedIn", "link"),
            _f(
                "field_formacao",
                "Formação acadêmica",
                "reference",
                target="taxonomy_term:formacao_academica",
                multiple=True,
            ),
            _f(
                "field_linhas_pesquisa",
                "Linhas de pesquisa",
                "reference",
                target="taxonomy_term:linhas_pesquisa",
                multiple=True,
            ),
            _f(
                "field_instituicao",
                "Instituição",
                "reference",
                target="taxonomy_term:instituicao_ensino",
            ),
        ],
    },
    "publicacao_cientifica": {
        "label": "Publicações",
        "label_singular": "Publicação",
        "icon": "menu_book",
        "fields": [
            _f("title", "Título da página", required=True,
               hint="Nome interno de referência"),
            _f("field_titulo_publicacao", "Título da publicação", required=False),
            _f(
                "field_pesquisadores_autores",
                "Autores do núcleo",
                "reference",
                target="node:perfil_pesquisador",
                multiple=True,
                hint="Pesquisadores cadastrados — escolha na lista",
            ),
            _f("field_autores", "Autores externos / demais autores",
               hint="Quem não é pesquisador do NERUDS — escreva o nome"),
            _f("field_ano_publicacao", "Ano de publicação", "number", required=False),
            _f("field_link_publicacao", "Link da publicação", "link", required=False),
            _f("field_doi", "DOI"),
            _f("field_pdf", "Arquivos PDF", "file", multiple=True),
            _f(
                "field_areas_conhecimento",
                "Áreas de conhecimento",
                "reference",
                target="taxonomy_term:area_conhecimento",
                multiple=True,
            ),
        ],
    },
    "grupo_estudos": {
        "label": "Grupos de estudos",
        "label_singular": "Grupo de estudos",
        "icon": "groups",
        "fields": [
            _f("title", "Título", required=True),
            _f("body", "Apresentação", "longtext"),
            _f("field_cronograma", "Cronograma", "daterange"),
            _f(
                "field_lider",
                "Líder do grupo",
                "reference",
                target="node:perfil_pesquisador",
            ),
            _f(
                "field_membros",
                "Membros",
                "reference",
                target="node:perfil_pesquisador",
                multiple=True,
            ),
            _f(
                "field_linha_pesquisa",
                "Linha de pesquisa",
                "reference",
                target="taxonomy_term:linhas_pesquisa",
            ),
        ],
    },
    "acao_extensionista": {
        "label": "Ações extensionistas",
        "label_singular": "Ação extensionista",
        "icon": "volunteer_activism",
        "fields": [
            _f("title", "Título", required=True),
            _f("body", "Descrição", "longtext"),
            _f("field_local_acao", "Local da ação"),
            _f("field_numero_participantes", "Nº de participantes", "number"),
            _f("field_impactos_resultados", "Impactos e resultados", "longtext"),
            _f(
                "field_tipo_acao",
                "Tipo de ação",
                "reference",
                target="taxonomy_term:tipo_acao_extensionista",
            ),
            _f(
                "field_municipio",
                "Município",
                "reference",
                target="taxonomy_term:municipio",
            ),
            _f("field_pdf", "PDF", "file"),
        ],
    },
    "relatorio": {
        "label": "Relatórios",
        "label_singular": "Relatório",
        "icon": "description",
        "fields": [
            _f("title", "Título", required=True),
            _f("field_resumo_executivo", "Resumo executivo", "longtext"),
            _f("field_objetivos_alcancados", "Objetivos alcançados", "longtext"),
            _f("field_resultados_obtidos", "Resultados obtidos", "longtext"),
            _f("field_proximos_passos", "Próximos passos", "longtext"),
            _f("field_periodo_relatorio", "Período", "daterange"),
            _f(
                "field_projeto_vinculado",
                "Projeto vinculado",
                "reference",
                target="node:projeto_pesquisa_extensao",
            ),
            _f("field_arquivo_relatorio", "Arquivo do relatório", "file"),
        ],
    },
    "reuniao": {
        "label": "Reuniões",
        "label_singular": "Reunião",
        "icon": "groups_2",
        "fields": [
            _f("title", "Título", required=True),
            _f("field_data_reuniao", "Data e hora", "date"),
            _f("field_pauta", "Pauta", "longtext"),
            _f(
                "field_participantes_reuniao",
                "Participantes",
                "reference",
                target="node:perfil_pesquisador",
                multiple=True,
            ),
            _f("field_participantes", "Participantes externos",
               hint="Quem não é pesquisador do NERUDS — escreva o nome"),
        ],
    },
    "page": {
        "label": "Páginas institucionais",
        "label_singular": "Página",
        "icon": "article",
        "fields": [
            _f("title", "Título", required=True),
            _f("field_content", "Conteúdo", "longtext"),
            _f("field_description", "Descrição", "longtext"),
            _f("field_featured_image", "Imagem de destaque", "image"),
            _f("field_tags", "Tags", "reference",
               target="taxonomy_term:tags", multiple=True),
        ],
    },
    "boletim_periodico": {
        "label": "Boletins",
        "label_singular": "Boletim",
        "icon": "description",
        "fields": [
            _f("title", "Título", required=True),
            _f("field_resumo_boletim", "Resumo", "longtext"),
            _f("field_ano_publicacao", "Ano", "number"),
            _f("field_mes_publicacao", "Mês"),
            _f("field_periodo_publicacao", "Período"),
        ],
    },
    "relatorio_fno": {
        "label": "Relatórios FNO",
        "label_singular": "Relatório FNO",
        "icon": "analytics",
        "fields": [
            _f("title", "Título", required=True),
            _f("field_fno_key_findings", "Principais descobertas", "longtext"),
            _f("field_fno_methodology", "Metodologia FNO", "longtext"),
            _f("field_metodologia", "Metodologia", "longtext"),
            _f("field_principais_descobertas", "Descobertas", "longtext"),
            _f("field_pesquisadores", "Pesquisadores"),
            _f("field_periodo_pesquisa", "Período da pesquisa"),
            _f("field_fno_research_period", "Período FNO"),
            _f("field_fno_report_url", "URL do relatório", "link"),
            _f("field_looker_url", "URL Looker", "link"),
            _f("field_embed_code", "Código embed", "longtext"),
            _f("field_fno_report_embed", "Embed do relatório", "longtext"),
        ],
    },
}


# Divisão dos formulários em passos de wizard (desenho validado com
# consulta arquitetural — campos acadêmicos profundos agrupados).
# ids de grupo: basics | content | details | academic | team | refs | media
_WIZARD_STEPS: dict[str, list[dict[str, str]]] = {
    "noticia": [
        {"id": "basics", "label": "Informações básicas"},
        {"id": "content", "label": "Conteúdo"},
        {"id": "refs", "label": "Vínculos e classificação"},
        {"id": "media", "label": "Mídia e anexos"},
    ],
    "evento_cientifico": [
        {"id": "basics", "label": "Informações básicas"},
        {"id": "details", "label": "Detalhes do evento"},
        {"id": "media", "label": "Mídia"},
    ],
    "projeto_pesquisa_extensao": [
        {"id": "basics", "label": "Informações básicas"},
        {"id": "academic", "label": "Metadados acadêmicos"},
        {"id": "team", "label": "Equipe e classificação"},
        {"id": "media", "label": "Mídia e anexos"},
    ],
    "perfil_pesquisador": [
        {"id": "basics", "label": "Identificação"},
        {"id": "academic", "label": "Curriculo acadêmico"},
        {"id": "content", "label": "Biografia"},
        {"id": "media", "label": "Foto"},
    ],
    "publicacao_cientifica": [
        {"id": "basics", "label": "Identificação"},
        {"id": "academic", "label": "Metadados da publicação"},
        {"id": "media", "label": "Arquivos"},
    ],
    "grupo_estudos": [
        {"id": "basics", "label": "Informações básicas"},
        {"id": "team", "label": "Equipe e linha"},
        {"id": "details", "label": "Descrição"},
    ],
    "acao_extensionista": [
        {"id": "basics", "label": "Informações básicas"},
        {"id": "details", "label": "Execução e impacto"},
        {"id": "media", "label": "Anexos"},
    ],
    "relatorio": [
        {"id": "basics", "label": "Identificação"},
        {"id": "content", "label": "Conteúdo do relatório"},
        {"id": "media", "label": "Arquivos"},
    ],
    "page": [
        {"id": "content", "label": "Conteúdo"},
        {"id": "refs", "label": "Classificação"},
        {"id": "media", "label": "Mídia"},
    ],
    "boletim_periodico": [
        {"id": "basics", "label": "Informações básicas"},
        {"id": "content", "label": "Conteúdo"},
    ],
    "relatorio_fno": [
        {"id": "basics", "label": "Informações básicas"},
        {"id": "academic", "label": "Pesquisa"},
        {"id": "refs", "label": "Links e embeds"},
    ],
    "reuniao": [
        {"id": "basics", "label": "Informações básicas"},
        {"id": "details", "label": "Pauta e participantes"},
    ],
}

_FIELD_GROUPS: dict[str, dict[str, str]] = {
    "noticia": {
        "title": "basics", "field_data_noticia": "basics",
        "field_autor_noticia": "basics",
        "field_resumo_noticia": "content", "body": "content",
        "field_link_noticia": "content", "field_fonte_externa": "content",
        "field_projeto_associado": "refs",
        "field_linha_pesquisa": "refs", "field_tags": "refs",
        "field_imagem_destaque": "media", "field_pdf": "media",
    },
    "evento_cientifico": {
        "title": "basics", "field_data_evento": "basics",
        "field_local_evento": "basics",
        "field_descricao_evento": "details",
        "field_organizadores": "details",
        "field_chamada_trabalhos": "details",
        "field_link_inscricao": "details",
        "field_link_submissao": "details",
        "field_imagem_destaque": "media",
    },
    "projeto_pesquisa_extensao": {
        "title": "basics", "field_coordenador": "basics",
        "field_data_inicio": "basics", "field_data_fim": "basics",
        "field_local_execucao": "basics",
        "field_resumo": "academic", "field_descricao_projeto": "academic",
        "field_justificativa": "academic",
        "field_objetivos": "academic", "field_metodologia": "academic",
        "field_equipe_pesquisa": "team",
        "field_linhas_pesquisa": "team",
        "field_status_projeto": "team", "field_tipo_projeto": "team",
        "field_imagens_projeto": "media", "field_pdf": "media",
    },
    "perfil_pesquisador": {
        "title": "basics", "field_nome_completo": "basics",
        "field_email": "basics",
        "field_instituicao": "basics",
        "field_lattes": "academic", "field_orcid_id": "academic",
        "field_google_scholar": "academic", "field_linkedin": "academic",
        "field_formacao": "academic",
        "field_linhas_pesquisa": "academic",
        "field_biografia": "content",
        "field_foto_perfil": "media",
    },
    "publicacao_cientifica": {
        "title": "basics",
        "field_titulo_publicacao": "basics",
        "field_pesquisadores_autores": "academic",
        "field_autores": "academic",
        "field_ano_publicacao": "academic",
        "field_link_publicacao": "academic", "field_doi": "academic",
        "field_areas_conhecimento": "academic",
        "field_pdf": "media",
    },
    "grupo_estudos": {
        "title": "basics", "field_cronograma": "basics",
        "field_lider": "team", "field_membros": "team",
        "field_linha_pesquisa": "team",
        "body": "details",
    },
    "acao_extensionista": {
        "title": "basics", "field_local_acao": "basics",
        "field_tipo_acao": "basics", "field_municipio": "basics",
        "body": "details",
        "field_numero_participantes": "details",
        "field_impactos_resultados": "details",
        "field_pdf": "media",
    },
    "relatorio": {
        "title": "basics", "field_periodo_relatorio": "basics",
        "field_projeto_vinculado": "basics",
        "field_resumo_executivo": "content",
        "field_objetivos_alcancados": "content",
        "field_resultados_obtidos": "content",
        "field_proximos_passos": "content",
        "field_arquivo_relatorio": "media",
    },
    "reuniao": {
        "title": "basics", "field_data_reuniao": "basics",
        "field_pauta": "details", "field_participantes_reuniao": "details",
        "field_participantes": "details",
    },
    "page": {
        "title": "content", "field_content": "content",
        "field_description": "content",
        "field_tags": "refs", "field_featured_image": "media",
    },
    "boletim_periodico": {
        "title": "basics", "field_ano_publicacao": "basics",
        "field_mes_publicacao": "basics",
        "field_periodo_publicacao": "basics",
        "field_resumo_boletim": "content",
    },
    "relatorio_fno": {
        "title": "basics", "field_pesquisadores": "basics",
        "field_periodo_pesquisa": "basics",
        "field_fno_research_period": "basics",
        "field_fno_key_findings": "academic",
        "field_fno_methodology": "academic",
        "field_metodologia": "academic",
        "field_principais_descobertas": "academic",
        "field_fno_report_url": "refs", "field_looker_url": "refs",
        "field_embed_code": "refs", "field_fno_report_embed": "refs",
    },
}

_REVIEW_STEP = {"id": "review", "label": "Revisão e salvar"}

for _bundle, _schema in MANAGE_SCHEMAS.items():
    _steps = _WIZARD_STEPS.get(_bundle)
    if not _steps:
        continue
    _groups = _FIELD_GROUPS.get(_bundle, {})
    for _field in _schema["fields"]:
        _field["group"] = _groups.get(_field["name"], "basics")
    _schema["steps"] = [*_steps, dict(_REVIEW_STEP)]


# Vocabulários de taxonomia gerenciáveis (espelhado de produção, 39 vocabs).
# Todos compartilham a mesma forma de termo (name/description/weight/parent),
# então um único schema cobre qualquer vocabulário.
TAXONOMY_VOCABS: dict[str, dict[str, str]] = {
    v: {"label": label}
    for v, label in {
        "apoiadores_financiadores": "Apoiadores e Financiadores",
        "area_conhecimento": "Área de Conhecimento",
        "areas_conhecimento": "Áreas de Conhecimento",
        "biomas": "Biomas",
        "boletins_periodicos": "Boletins Periódicos",
        "comunidade_atendida": "Comunidade Atendida",
        "eixos_tematicos": "Eixos Temáticos",
        "formacao_academica": "Formação Acadêmica",
        "geografia_estados": "Geografia - Estados",
        "instituicao_ensino": "Instituição de Ensino",
        "linha_pesquisa": "Linha de Pesquisa",
        "linhas_pesquisa": "Linhas de Pesquisa",
        "metodologias_pesquisa": "Metodologias de Pesquisa",
        "microrregiao_tocantins": "Microrregião Tocantins",
        "microrregioes": "Microrregiões",
        "municipio": "Município",
        "municipios": "Municípios",
        "natureza_pesquisa": "Natureza da Pesquisa",
        "ods": "ODS - Objetivos de Desenvolvimento Sustentável",
        "ods_interesse": "ODS de Interesse",
        "palavras_chave": "Palavras-chave",
        "produtos_projeto": "Produtos do Projeto",
        "setor_produtivo": "Setor Produtivo",
        "setor_produtivo_cadeia": "Setor Produtivo/Cadeia",
        "setores_produtivos": "Setores Produtivos",
        "status_projeto": "Status do Projeto",
        "tags": "Tags",
        "temas_pesquisa": "Temas de Pesquisa",
        "territorios": "Territorios",
        "tipo_acao_extensionista": "Tipo de Ação Extensionista",
        "tipo_boletim": "Tipo de Boletim",
        "tipo_producao": "Tipo de Produção Científica",
        "tipo_projeto": "Tipo de Projeto",
        "tipo_publicacao": "Tipo de Publicação",
        "tipo_vinculo": "Tipo de Vínculo",
        "unidade_conservacao": "Unidades de Conservação",
        "unidade_local_extensao_ule": "Unidade Local de Extensão (ULE)",
        "unidades_conservacao": "Unidades de Conservação",
    }.items()
}


def taxonomy_fields(vocab: str) -> list[dict[str, Any]]:
    """Termos compartilham sempre a mesma forma — só o alvo do pai varia."""
    return [
        _f("name", "Nome", required=True),
        _f("description", "Descrição", "longtext"),
        _f("weight", "Peso (ordem)", "number",
           hint="Menor aparece primeiro nas listagens"),
        _f("parent", "Termo pai", "reference",
           target=f"taxonomy_term:{vocab}"),
    ]


def schema_for(bundle: str) -> dict[str, Any] | None:
    return MANAGE_SCHEMAS.get(bundle)


def spec_for(bundle: str, field_name: str) -> dict[str, Any] | None:
    schema = MANAGE_SCHEMAS.get(bundle) or {}
    for spec in schema.get("fields", []):
        if spec["name"] == field_name:
            return spec
    return None
