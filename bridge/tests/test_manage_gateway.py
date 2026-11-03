"""Tests for the generic /manage CRUD gateway."""

import json

import pytest
import respx
from httpx import Response

import main
import manage_schema


def _allow_forms(respx_mock, bundles: set[str]):
    for bundle in main.CONTENT_BUNDLES:
        respx_mock.get(f"https://neruds.org/node/add/{bundle}").mock(
            return_value=Response(
                200 if bundle in bundles else 403,
                text="<form></form>" if bundle in bundles else "",
            )
        )


def _node_jsonapi_item(nid: int, uuid: str, title: str, status: bool = True):
    return {
        "id": uuid,
        "type": "node--grupo_estudos",
        "attributes": {
            "drupal_internal__nid": nid,
            "title": title,
            "status": status,
            "changed": "2026-11-03T12:00:00+00:00",
        },
    }


@pytest.mark.asyncio
@respx.mock
async def test_manage_schemas_returns_bundles_and_access(
    async_client, extensionista_session, respx_mock
):
    token, _ = extensionista_session
    _allow_forms(respx_mock, {"noticia", "relatorio"})
    response = await async_client.get(
        "/manage/schemas", headers={"Authorization": f"Bearer {token}"}
    )
    assert response.status_code == 200
    data = response.json()
    assert "grupo_estudos" in data["schemas"]
    assert "perfil_pesquisador" in data["schemas"]
    assert data["can_create"]["noticia"] is True
    assert data["can_create"]["grupo_estudos"] is False
    fields = {f["name"] for f in data["schemas"]["grupo_estudos"]["fields"]}
    assert "field_lider" in fields


@pytest.mark.asyncio
@respx.mock
async def test_manage_list_normalizes_items(
    async_client, extensionista_session, respx_mock
):
    token, _ = extensionista_session
    respx_mock.get("https://neruds.org/jsonapi/node/grupo_estudos").mock(
        return_value=Response(
            200,
            json={
                "data": [
                    _node_jsonapi_item(10, "u-10", "Grupo Agroecologia"),
                    _node_jsonapi_item(11, "u-11", "Grupo Economia", status=False),
                ],
                "links": {},
            },
        )
    )
    response = await async_client.get(
        "/manage/grupo_estudos?limit=10",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    data = response.json()
    assert [i["nid"] for i in data["items"]] == [10, 11]
    assert data["items"][0]["title"] == "Grupo Agroecologia"
    assert data["items"][1]["status"] is False


@pytest.mark.asyncio
@respx.mock
async def test_manage_list_passes_filters(
    async_client, extensionista_session, respx_mock
):
    token, _ = extensionista_session
    route = respx_mock.get("https://neruds.org/jsonapi/node/grupo_estudos").mock(
        return_value=Response(200, json={"data": [], "links": {}})
    )
    await async_client.get(
        "/manage/grupo_estudos?status=draft&search=agro",
        headers={"Authorization": f"Bearer {token}"},
    )
    query = route.calls.last.request.url.params
    assert query["filter[status]"] == "0"
    assert query["filter[title][value]"] == "agro"


@pytest.mark.asyncio
@respx.mock
async def test_manage_create_unpublished_uses_native_form(
    async_client, extensionista_session, respx_mock
):
    """published=false creates via the Drupal form (born unpublished)."""
    token, _ = extensionista_session
    _allow_forms(respx_mock, {"grupo_estudos"})
    respx_mock.post("https://neruds.org/node/add/grupo_estudos").mock(
        return_value=Response(
            302, headers={"location": "https://neruds.org/node/99"}
        )
    )
    response = await async_client.post(
        "/manage/grupo_estudos",
        json={"values": {"title": "Novo Grupo"}, "published": False},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    assert response.json()["nid"] == 99
    assert response.json()["status"] is False


@pytest.mark.asyncio
@respx.mock
async def test_manage_create_published_posts_jsonapi(
    async_client, extensionista_session, respx_mock
):
    token, _ = extensionista_session
    _allow_forms(respx_mock, {"grupo_estudos"})
    post = respx_mock.post("https://neruds.org/jsonapi/node/grupo_estudos").mock(
        return_value=Response(
            201, json={"data": _node_jsonapi_item(99, "u-99", "Novo Grupo", True)}
        )
    )
    response = await async_client.post(
        "/manage/grupo_estudos",
        json={"values": {"title": "Novo Grupo"}, "published": True},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    sent = json.loads(post.calls.last.request.content)
    assert sent["data"]["type"] == "node--grupo_estudos"
    assert sent["data"]["attributes"]["title"] == "Novo Grupo"
    assert sent["data"]["attributes"]["status"] is True
    assert post.calls.last.request.headers["X-CSRF-Token"] == "fake-csrf-token-ext"


@pytest.mark.asyncio
@respx.mock
async def test_manage_create_denied_without_access(
    async_client, extensionista_session, respx_mock
):
    token, _ = extensionista_session
    _allow_forms(respx_mock, {"noticia"})
    response = await async_client.post(
        "/manage/grupo_estudos",
        json={"values": {"title": "x"}},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 403


@pytest.mark.asyncio
@respx.mock
async def test_manage_update_resolves_uuid_and_patches(
    async_client, extensionista_session, respx_mock
):
    token, _ = extensionista_session
    respx_mock.get("https://neruds.org/jsonapi/node/grupo_estudos").mock(
        return_value=Response(
            200,
            json={"data": [_node_jsonapi_item(10, "u-10", "Old")]},
        )
    )
    patch = respx_mock.patch(
        "https://neruds.org/jsonapi/node/grupo_estudos/u-10"
    ).mock(
        return_value=Response(
            200, json={"data": _node_jsonapi_item(10, "u-10", "Novo Nome")}
        )
    )
    response = await async_client.patch(
        "/manage/grupo_estudos/10",
        json={"values": {"title": "Novo Nome"}},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    sent = json.loads(patch.calls.last.request.content)
    assert sent["data"]["id"] == "u-10"
    assert sent["data"]["attributes"]["title"] == "Novo Nome"


@pytest.mark.asyncio
@respx.mock
async def test_manage_delete_unpublishes_by_default(
    async_client, extensionista_session, respx_mock
):
    token, _ = extensionista_session
    respx_mock.get("https://neruds.org/jsonapi/node/grupo_estudos").mock(
        return_value=Response(
            200, json={"data": [_node_jsonapi_item(10, "u-10", "X")]}
        )
    )
    patch = respx_mock.patch(
        "https://neruds.org/jsonapi/node/grupo_estudos/u-10"
    ).mock(
        return_value=Response(
            200, json={"data": _node_jsonapi_item(10, "u-10", "X", False)}
        )
    )
    response = await async_client.delete(
        "/manage/grupo_estudos/10",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    assert response.json()["published"] is False
    sent = json.loads(patch.calls.last.request.content)
    assert sent["data"]["attributes"]["status"] is False


@pytest.mark.asyncio
@respx.mock
async def test_manage_delete_hard_removes(
    async_client, extensionista_session, respx_mock
):
    token, _ = extensionista_session
    respx_mock.get("https://neruds.org/jsonapi/node/grupo_estudos").mock(
        return_value=Response(
            200, json={"data": [_node_jsonapi_item(10, "u-10", "X")]}
        )
    )
    respx_mock.delete(
        "https://neruds.org/jsonapi/node/grupo_estudos/u-10"
    ).mock(return_value=Response(204))
    response = await async_client.delete(
        "/manage/grupo_estudos/10?hard=1",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    assert response.json()["deleted"] is True


@pytest.mark.asyncio
@respx.mock
async def test_manage_options_for_taxonomy(
    async_client, extensionista_session, respx_mock
):
    token, _ = extensionista_session
    respx_mock.get(
        "https://neruds.org/jsonapi/taxonomy_term/linhas_pesquisa"
    ).mock(
        return_value=Response(
            200,
            json={
                "data": [
                    {
                        "id": "t-1",
                        "attributes": {"drupal_internal__tid": 4, "name": "Agroecologia"},
                    }
                ]
            },
        )
    )
    response = await async_client.get(
        "/manage/options/taxonomy_term/linhas_pesquisa",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    assert response.json()["options"] == [
        {"id": 4, "uuid": "t-1", "label": "Agroecologia"}
    ]


@pytest.mark.asyncio
async def test_manage_unknown_bundle_404(async_client, extensionista_session):
    token, _ = extensionista_session
    response = await async_client.get(
        "/manage/block", headers={"Authorization": f"Bearer {token}"}
    )
    assert response.status_code == 404


@pytest.mark.asyncio
@respx.mock
async def test_manage_upload_streams_binary(
    async_client, extensionista_session, respx_mock
):
    token, _ = extensionista_session
    post = respx_mock.post(
        "https://neruds.org/jsonapi/node/perfil_pesquisador/field_foto_perfil"
    ).mock(
        return_value=Response(
            201,
            json={
                "data": {
                    "id": "file-uuid-1",
                    "attributes": {"uri": {"url": "files/foto.png"}},
                }
            },
        )
    )
    response = await async_client.post(
        "/manage/perfil_pesquisador/files/field_foto_perfil?filename=foto.png",
        content=b"\x89PNG fake",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/octet-stream",
        },
    )
    assert response.status_code == 200
    assert response.json()["id"] == "file-uuid-1"
    sent = post.calls.last.request
    assert sent.headers["Content-Disposition"] == 'attachment; filename="foto.png"'
    assert sent.content == b"\x89PNG fake"


@pytest.mark.asyncio
@respx.mock
async def test_manage_update_reference_resolves_nid(
    async_client, extensionista_session, respx_mock
):
    """Reference fields accept nid/tid and resolve to JSON:API uuids."""
    token, _ = extensionista_session
    grupo = "https://neruds.org/jsonapi/node/grupo_estudos"
    perfil = "https://neruds.org/jsonapi/node/perfil_pesquisador"

    def grupo_handler(request):
        if "u-10" in str(request.url):
            return Response(
                200, json={"data": _node_jsonapi_item(10, "u-10", "Grupo")}
            )
        if request.url.params.get("filter[drupal_internal__nid]") == "10":
            return Response(
                200, json={"data": [_node_jsonapi_item(10, "u-10", "Grupo")]}
            )
        return Response(200, json={"data": [], "links": {}})

    respx_mock.get(url__regex=re_escape(grupo)).mock(side_effect=grupo_handler)
    respx_mock.get(perfil).mock(
        return_value=Response(
            200,
            json={
                "data": [
                    {
                        "id": "p-5",
                        "attributes": {
                            "drupal_internal__nid": 5,
                            "title": "Pesquisadora",
                            "status": True,
                        },
                    }
                ]
            },
        )
    )
    patch = respx_mock.patch(f"{grupo}/u-10").mock(
        return_value=Response(
            200, json={"data": _node_jsonapi_item(10, "u-10", "Grupo")}
        )
    )
    response = await async_client.patch(
        "/manage/grupo_estudos/10",
        json={"values": {"field_lider": 5}},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    sent = json.loads(patch.calls.last.request.content)
    rel = sent["data"]["relationships"]["field_lider"]["data"]
    assert rel == {"type": "node--perfil_pesquisador", "id": "p-5"}


def re_escape(s: str) -> str:
    import re as _re

    return _re.escape(s)
