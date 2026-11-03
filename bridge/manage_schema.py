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
            _f("field_data_noticia", "Data da notícia", "date", required=True),
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
            _f("field_data_evento", "Data do evento", "date", required=True),
            _f("field_local_evento", "Local", required=True),
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
            _f("field_coordenador", "Coordenador", required=True),
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
            _f("field_nome_completo", "Nome completo", required=True),
            _f("field_email", "E-mail", "email", required=True),
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
            _f("field_titulo_publicacao", "Título da publicação", required=True),
            _f("field_autores", "Autores", required=True),
            _f("field_ano_publicacao", "Ano de publicação", "number", required=True),
            _f("field_link_publicacao", "Link da publicação", "link", required=True),
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
            _f("field_participantes", "Participantes"),
        ],
    },
}


def schema_for(bundle: str) -> dict[str, Any] | None:
    return MANAGE_SCHEMAS.get(bundle)


def spec_for(bundle: str, field_name: str) -> dict[str, Any] | None:
    schema = MANAGE_SCHEMAS.get(bundle) or {}
    for spec in schema.get("fields", []):
        if spec["name"] == field_name:
            return spec
    return None
