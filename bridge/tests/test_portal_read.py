"""Contract tests for the real-structure read layer (issue #22).

All endpoints are read-only against the portal and must only consult fields
present in the versioned content_map (real form displays).
"""

import respx
from httpx import Response

PORTAL = "https://neruds.org"


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def _node_item(nid, title, attrs=None, rels=None):
    item = {
        "id": f"uuid-{nid}",
        "type": "node--publicacao_cientifica",
        "attributes": {
            "drupal_internal__nid": nid,
            "title": title,
            "status": True,
            "path": {"alias": f"/pub/{nid}"},
        },
    }
    if attrs:
        item["attributes"].update(attrs)
    if rels:
        item["relationships"] = rels
    return item


def _jsonapi_payload(items, next_href=None, included=None):
    payload = {"data": items, "links": {}}
    if next_href:
        payload["links"]["next"] = {"href": next_href}
    if included:
        payload["included"] = included
    return payload


@respx.mock
async def test_lacunas_computes_attribute_and_relationship_gaps(
    async_client, extensionista_session
):
    token, _ = extensionista_session
    items = [
        _node_item(1, "Pub completa", attrs={
            "field_ano_publicacao": 2024,
            "field_doi": "10.1/x",
            "field_link_publicacao": {"uri": "https://doi.org/10.1/x"},
            "field_resumo_publicacao": {"value": "Resumo", "format": "plain_text"},
        }, rels={"field_linhas_pesquisa": {"data": [{"id": "t1"}]}}),
        _node_item(2, "Pub sem ano nem resumo", attrs={
            "field_ano_publicacao": None,
            "field_doi": "10.1/y",
            "field_link_publicacao": {"uri": "https://doi.org/10.1/y"},
            "field_resumo_publicacao": {"value": "", "format": "plain_text"},
        }, rels={"field_linhas_pesquisa": {"data": []}}),
        _node_item(3, "Pub sem link", attrs={
            "field_ano_publicacao": 2023,
            "field_doi": "10.1/z",
            "field_link_publicacao": {"uri": ""},
            "field_resumo_publicacao": {"value": "Tem resumo"},
        }, rels={"field_linhas_pesquisa": {"data": [{"id": "t2"}]}}),
    ]
    respx_mock = respx.get(f"{PORTAL}/jsonapi/node/publicacao_cientifica").mock(
        return_value=Response(200, json=_jsonapi_payload(items))
    )

    response = await async_client.get(
        "/portal/lacunas?tipo=publicacao_cientifica", headers=_auth(token)
    )
    assert response.status_code == 200
    body = response.json()
    assert respx_mock.called
    assert body["fetched_at"]
    (tipo,) = body["types"]
    assert tipo["type"] == "publicacao_cientifica"
    assert tipo["published"] == 3
    assert tipo["listing_url"] == f"{PORTAL}/publicacoes"
    gaps = {f["field"]: f for f in tipo["fields"]}
    assert gaps["field_ano_publicacao"]["missing"] == 1
    assert gaps["field_ano_publicacao"]["nodes"][0]["nid"] == 2
    assert gaps["field_resumo_publicacao"]["missing"] == 1
    assert gaps["field_link_publicacao"]["missing"] == 1
    assert gaps["field_link_publicacao"]["nodes"][0]["nid"] == 3
    assert gaps["field_linhas_pesquisa"]["missing"] == 1  # relationship emptiness
    # no gap for fields filled in every node
    assert "field_doi" not in gaps
    # titulo_publicacao is absent in all three fixtures -> missing == 3
    assert gaps["field_titulo_publicacao"]["missing"] == 3
    ano_node = gaps["field_ano_publicacao"]["nodes"][0]
    assert ano_node["view_url"] == f"{PORTAL}/pub/2"
    assert ano_node["edit_url"] == f"{PORTAL}/node/2/edit"


@respx.mock
async def test_lacunas_follows_pagination(async_client, extensionista_session):
    token, _ = extensionista_session
    page2 = f"{PORTAL}/jsonapi/node/publicacao_cientifica?page%5Boffset%5D=50"
    respx.get(f"{PORTAL}/jsonapi/node/publicacao_cientifica").mock(
        side_effect=[
            Response(200, json=_jsonapi_payload(
                [_node_item(1, "A", attrs={"field_doi": "10.1/a"})],
                next_href=page2,
            )),
            Response(200, json=_jsonapi_payload(
                [_node_item(2, "B", attrs={"field_doi": None})],
            )),
        ]
    )
    response = await async_client.get(
        "/portal/lacunas?tipo=publicacao_cientifica&campo=field_doi",
        headers=_auth(token),
    )
    assert response.status_code == 200
    tipo = response.json()["types"][0]
    assert tipo["published"] == 2
    assert tipo["fields"][0]["missing"] == 1
    assert tipo["fields"][0]["nodes"][0]["nid"] == 2


async def test_lacunas_rejects_unknown_type(async_client, extensionista_session):
    token, _ = extensionista_session
    response = await async_client.get(
        "/portal/lacunas?tipo=tipo_inexistente", headers=_auth(token)
    )
    assert response.status_code == 422


async def test_lacunas_rejects_unmonitored_field(async_client, extensionista_session):
    token, _ = extensionista_session
    response = await async_client.get(
        "/portal/lacunas?tipo=noticia&campo=field_data_noticia",
        headers=_auth(token),
    )
    # field_data_noticia exists in storage but is not rendered in the real form
    assert response.status_code == 422


async def test_lacunas_requires_session(async_client):
    response = await async_client.get("/portal/lacunas")
    assert response.status_code == 401


@respx.mock
async def test_eventos_sorted_with_days_until(async_client, extensionista_session):
    token, _ = extensionista_session
    items = [
        {
            "id": "e1",
            "attributes": {
                "drupal_internal__nid": 10,
                "title": "Evento passado",
                "field_data_evento": "2020-01-01T09:00:00+00:00",
                "field_local_evento": "Palmas",
                "field_link_inscricao": {"uri": "https://ex.org/insc"},
                "field_descricao_evento": {"value": "<p>Desc</p>", "format": "x"},
                "path": {"alias": "/evento/10"},
            },
        },
        {
            "id": "e2",
            "attributes": {
                "drupal_internal__nid": 11,
                "title": "Evento futuro",
                "field_data_evento": "2999-01-01T09:00:00+00:00",
                "field_local_evento": "Online",
                "field_link_inscricao": None,
                "path": {"alias": None},
            },
        },
    ]
    respx.get(f"{PORTAL}/jsonapi/node/evento_cientifico").mock(
        return_value=Response(200, json=_jsonapi_payload(items))
    )
    response = await async_client.get("/portal/eventos", headers=_auth(token))
    assert response.status_code == 200
    body = response.json()
    assert body["listing_url"] == f"{PORTAL}/eventos"
    assert [e["title"] for e in body["events"]] == ["Evento futuro", "Evento passado"]
    futuro, passado = body["events"]
    assert futuro["past"] is False and futuro["days_until"] > 0
    assert passado["past"] is True and passado["signup_url"] == "https://ex.org/insc"
    assert passado["description"] == "Desc"
    assert futuro["edit_url"] == f"{PORTAL}/node/11/edit"


@respx.mock
async def test_projetos_resolve_term_names(async_client, extensionista_session):
    token, _ = extensionista_session
    proj = {
        "id": "p1",
        "attributes": {
            "drupal_internal__nid": 20,
            "title": "Projeto X",
            "field_coordenador": "Maria",
            "field_data_inicio": "2024-01-01",
            "field_data_fim": "2025-12-31",
            "field_resumo": {"value": "Resumo do projeto"},
            "path": {"alias": "/projeto/20"},
        },
        "relationships": {
            "field_status_projeto": {"data": [{"id": "term-1"}]},
            "field_tipo_projeto": {"data": [{"id": "term-2"}]},
        },
    }
    acao = {
        "id": "a1",
        "attributes": {
            "drupal_internal__nid": 30,
            "title": "Ação Y",
            "field_local_acao": "Araguaína",
            "field_numero_participantes": 40,
            "path": {"alias": "/acao/30"},
        },
        "relationships": {
            "field_municipio": {"data": [{"id": "term-3"}]},
            "field_tipo_acao": {"data": [{"id": "term-4"}]},
        },
    }
    included = [
        {"id": "term-1", "type": "taxonomy_term--status_projeto",
         "attributes": {"name": "Em andamento"}},
        {"id": "term-2", "type": "taxonomy_term--tipo_projeto",
         "attributes": {"name": "Extensão"}},
        {"id": "term-3", "type": "taxonomy_term--municipio",
         "attributes": {"name": "Araguaína"}},
        {"id": "term-4", "type": "taxonomy_term--tipo_acao",
         "attributes": {"name": "Curso"}},
    ]
    respx.get(f"{PORTAL}/jsonapi/node/projeto_pesquisa_extensao").mock(
        return_value=Response(
            200, json=_jsonapi_payload([proj], included=included)
        )
    )
    respx.get(f"{PORTAL}/jsonapi/node/acao_extensionista").mock(
        return_value=Response(
            200, json=_jsonapi_payload([acao], included=included)
        )
    )
    response = await async_client.get("/portal/projetos", headers=_auth(token))
    assert response.status_code == 200
    body = response.json()
    p = body["projetos"][0]
    assert p["status"] == ["Em andamento"]
    assert p["kind"] == ["Extensão"]
    assert p["coordinator"] == "Maria"
    assert p["summary"] == "Resumo do projeto"
    a = body["acoes"][0]
    assert a["municipality"] == ["Araguaína"]
    assert a["kind"] == ["Curso"]
    assert a["participants"] == 40


def _section_payload(nid, title, alias):
    return _jsonapi_payload([
        {
            "id": f"uuid-{nid}",
            "attributes": {
                "drupal_internal__nid": nid,
                "title": title,
                "created": "2026-10-07T10:00:00+00:00",
                "path": {"alias": alias},
            },
        }
    ])


@respx.mock
async def test_feeds_lists_latest_per_section(async_client, extensionista_session):
    token, _ = extensionista_session
    respx.get(f"{PORTAL}/jsonapi/node/noticia").mock(
        return_value=Response(200, json=_section_payload(1, "Notícia A", "/noticias/a"))
    )
    respx.get(f"{PORTAL}/jsonapi/node/evento_cientifico").mock(
        return_value=Response(200, json=_section_payload(2, "Congresso X", "/eventos/x"))
    )
    respx.get(f"{PORTAL}/jsonapi/node/projeto_pesquisa_extensao").mock(
        return_value=Response(200, json=_jsonapi_payload([]))
    )
    respx.get(f"{PORTAL}/jsonapi/node/publicacao_cientifica").mock(
        return_value=Response(200, json=_section_payload(3, "Pub Z", "/publicacoes/z"))
    )
    response = await async_client.get("/portal/feeds", headers=_auth(token))
    assert response.status_code == 200
    body = response.json()
    assert set(body["sections"]) == {"noticias", "eventos", "projetos", "publicacoes"}
    item = body["sections"]["noticias"]["items"][0]
    assert item["title"] == "Notícia A"
    assert item["link"] == f"{PORTAL}/noticias/a"
    assert item["published"]
    assert body["sections"]["projetos"]["items"] == []


@respx.mock
async def test_feeds_survives_broken_section(async_client, extensionista_session):
    token, _ = extensionista_session
    respx.get(f"{PORTAL}/jsonapi/node/noticia").mock(return_value=Response(403))
    respx.get(f"{PORTAL}/jsonapi/node/evento_cientifico").mock(
        return_value=Response(200, json=_section_payload(2, "Congresso X", "/e/x"))
    )
    respx.get(f"{PORTAL}/jsonapi/node/projeto_pesquisa_extensao").mock(
        return_value=Response(500)
    )
    respx.get(f"{PORTAL}/jsonapi/node/publicacao_cientifica").mock(
        return_value=Response(500)
    )
    response = await async_client.get("/portal/feeds", headers=_auth(token))
    assert response.status_code == 200
    body = response.json()
    assert body["sections"]["noticias"] == {"ok": False, "items": []}
    assert body["sections"]["eventos"]["items"][0]["title"] == "Congresso X"


@respx.mock
async def test_jsonapi_error_propagates(async_client, extensionista_session):
    token, _ = extensionista_session
    respx.get(f"{PORTAL}/jsonapi/node/noticia").mock(
        return_value=Response(403, json={"errors": []})
    )
    response = await async_client.get(
        "/portal/lacunas?tipo=noticia", headers=_auth(token)
    )
    assert response.status_code == 403
