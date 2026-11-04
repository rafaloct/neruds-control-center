"""Tests for the generic /content/{bundle}/draft endpoints."""

import pytest
import respx
from httpx import Response

import main

_FORM_HTML = (
    '<form><input type="hidden" name="form_build_id" value="build-123"/>'
    '<input type="hidden" name="form_id" value="node_evento_cientifico_form"/>'
    '<input type="hidden" name="body[0][value]" value=""/>'
    '<input type="hidden" name="body[0][format]" value="plain_text"/></form>'
)


def _mock_bundle_forms(respx_mock, allowed: dict[str, int]):
    for bundle in main.CONTENT_BUNDLES:
        status = allowed.get(bundle, 403)
        respx_mock.get(f"https://neruds.org/node/add/{bundle}").mock(
            return_value=Response(status, text=_FORM_HTML if status == 200 else "")
        )
        # Probe de permissão via JSON:API — POST vazio: 403 = sem create,
        # 422/400 = pode criar (validação reprova o payload).
        respx_mock.post(f"https://neruds.org/jsonapi/node/{bundle}").mock(
            return_value=Response(
                403 if status != 200 else 422, text=""
            )
        )


@pytest.mark.asyncio
@respx.mock
async def test_content_types_lists_only_allowed_bundles(
    async_client, extensionista_session, respx_mock
):
    token, _ = extensionista_session
    _mock_bundle_forms(respx_mock, {"noticia": 200, "relatorio": 200})
    response = await async_client.get(
        "/content/types", headers={"Authorization": f"Bearer {token}"}
    )
    assert response.status_code == 200
    bundles = {t["bundle"] for t in response.json()["types"]}
    assert bundles == {"noticia", "relatorio"}


@pytest.mark.asyncio
@respx.mock
async def test_bundle_draft_requires_mandatory_fields(
    async_client, extensionista_session, respx_mock
):
    token, _ = extensionista_session
    _mock_bundle_forms(respx_mock, {"evento_cientifico": 200})
    response = await async_client.post(
        "/content/evento_cientifico/draft",
        json={"title": "Seminário NERUDS", "body": "texto"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 422
    assert "Data do evento" in response.json()["detail"]
    assert "Local do evento" in response.json()["detail"]


@pytest.mark.asyncio
@respx.mock
async def test_bundle_draft_denied_without_form_access(
    async_client, extensionista_session, respx_mock
):
    token, _ = extensionista_session
    _mock_bundle_forms(respx_mock, {"noticia": 200})  # evento negado
    response = await async_client.post(
        "/content/evento_cientifico/draft",
        json={
            "title": "Seminário NERUDS",
            "body": "texto",
            "data": "2026-12-01",
            "local": "Palmas",
        },
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 403


@pytest.mark.asyncio
@respx.mock
async def test_bundle_draft_created_with_required_fields(
    async_client, extensionista_session, respx_mock
):
    token, _ = extensionista_session
    _mock_bundle_forms(respx_mock, {"evento_cientifico": 200})
    respx_mock.post("https://neruds.org/node/add/evento_cientifico").mock(
        return_value=Response(
            302, headers={"location": "https://neruds.org/node/410"}
        )
    )
    response = await async_client.post(
        "/content/evento_cientifico/draft",
        json={
            "title": "Seminário NERUDS 2026",
            "summary": "resumo",
            "body": "texto do evento",
            "data": "2026-12-01",
            "local": "Palmas/TO",
        },
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    data = response.json()
    assert data["ok"] is True
    assert data["id"] == "410"
    assert data["bundle"] == "evento_cientifico"
    assert data["published"] is False

    # Drupal fields went in the native form POST
    posted = respx_mock.calls[-1].request.content.decode()
    assert "field_data_evento%5B0%5D%5Bvalue%5D%5Bdate%5D=2026-12-01" in posted
    assert "field_local_evento" in posted


@pytest.mark.asyncio
async def test_bundle_unknown_returns_404(async_client, extensionista_session):
    token, _ = extensionista_session
    response = await async_client.post(
        "/content/artigo_cientifico/draft",
        json={"title": "Teste", "body": "x"},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 404


@pytest.mark.asyncio
async def test_content_types_requires_auth(async_client):
    response = await async_client.get("/content/types")
    assert response.status_code == 401
