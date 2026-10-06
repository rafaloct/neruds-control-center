"""Regression coverage for the existing portal/editorial workflows."""
import asyncio
import json
from datetime import date
from urllib.parse import parse_qs

import pytest
from httpx import Response

import main
import review_store
import rss_store


@pytest.fixture(autouse=True)
def isolated_editorial_services(monkeypatch):
    monkeypatch.setattr(main, "PORTAL_URL", "https://portal.example.org")
    monkeypatch.setattr(main, "SMTP_FROM", "")
    monkeypatch.setattr(main, "SMTP_REVIEW_TO", "")


def native_news(nid, owner_uid=None, *, published=False, title="Notícia institucional"):
    item = {
        "id": f"uuid-{nid}",
        "attributes": {
            "drupal_internal__nid": nid,
            "title": title,
            "status": published,
            "body": {
                "value": "<p>Primeiro &amp; segundo.</p><p>Próximo parágrafo.</p>",
                "summary": "Resumo da notícia.",
            },
            "path": {"alias": f"/noticia-{nid}"},
            "field_resumo_noticia": {"value": ""},
        },
    }
    if owner_uid is not None:
        item["relationships"] = {
            "uid": {
                "data": {
                    "type": "user--user",
                    "id": f"user-uuid-{owner_uid}",
                    "meta": {"drupal_internal__target_id": owner_uid},
                }
            }
        }
    return item


def approved_opportunity():
    item = rss_store.add_manual_item(
        title="Chamada institucional",
        url="https://source.example.org/chamada",
        category="Edital",
        actor="extensionista.test",
        deadline_at="2027-12-20",
    )
    return rss_store.decide(
        item["id"], actor="revisor.test", status="aprovado_pauta"
    )


async def test_published_queue_uses_drupal_state_and_readable_content(
    async_client, revisor_session, respx_mock
):
    token, _ = revisor_session
    review_store.register_draft("501", "Título antigo", "Drupal")
    review_store.decide("501", actor="revisor.test", status="approved", note=None)
    route = respx_mock.get(f"{main.PORTAL_URL}/jsonapi/node/noticia").mock(
        return_value=Response(200, json={"data": [native_news(501, 101, published=True)]})
    )

    response = await async_client.get(
        "/content/news/drafts?status=published",
        headers={"Authorization": f"Bearer {token}"},
    )

    assert response.status_code == 200
    assert route.calls.last.request.url.params["filter[status]"] == "1"
    assert "fake-cookie-revisor" in route.calls.last.request.headers["cookie"]
    item = response.json()["items"][0]
    assert item["status"] == item["review"]["review_status"] == "published"
    assert item["body"] == "Primeiro & segundo.\nPróximo parágrafo."
    assert item["summary"] == "Resumo da notícia."
    assert item["public_url"] == f"{main.PORTAL_URL}/noticia-501"
    assert item["edit_url"] == f"{main.PORTAL_URL}/node/501/edit"
    assert item["owner_uid"] == "101"
    assert item["is_owner"] is False
    assert item["review"]["author"] == "Drupal"
    assert item["review"]["published_at"] is None


async def test_native_uid_controls_mine_filter_even_with_legacy_author_names(
    async_client, extensionista_session, respx_mock
):
    token, _ = extensionista_session
    review_store.register_draft("601", "Nativa", "Drupal")
    review_store.register_draft("602", "Outro proprietário", "extensionista.test")
    respx_mock.get(f"{main.PORTAL_URL}/jsonapi/node/noticia").mock(
        return_value=Response(200, json={"data": [native_news(601, 101), native_news(602, 999)]})
    )
    response = await async_client.get(
        "/content/news/drafts?status=pending&mine_only=true",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    assert [item["nid"] for item in response.json()["items"]] == [601]
    assert response.json()["items"][0]["is_owner"] is True
    assert review_store.get_review("601")["author"] == "extensionista.test"
    assert review_store.get_review("602")["owner_uid"] == "999"


@pytest.mark.parametrize("owner_uid,expected_http", [(101, 200), (999, 403), (None, 403)])
async def test_native_legacy_draft_resubmission_requires_proven_owner(
    async_client, extensionista_session, respx_mock, owner_uid, expected_http
):
    token, _ = extensionista_session
    review_store.register_draft("603", "Nativa", "Drupal")
    review_store.decide("603", actor="revisor.test", status="changes_requested", note="Inclua a fonte.")
    route = respx_mock.get(f"{main.PORTAL_URL}/jsonapi/node/noticia").mock(
        return_value=Response(200, json={"data": [native_news(603, owner_uid)]})
    )
    response = await async_client.patch(
        "/content/news/drafts/603/review",
        json={"status": "pending", "note": "Fonte conferida."},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == expected_http
    assert route.calls.last.request.url.params["filter[drupal_internal__nid]"] == "603"
    review = review_store.get_review("603")
    assert review["review_status"] == ("pending" if expected_http == 200 else "changes_requested")
    assert review["author"] == ("extensionista.test" if expected_http == 200 else "Drupal")


async def test_denied_drupal_read_does_not_expose_local_review_or_body(
    async_client, extensionista_session, respx_mock
):
    token, _ = extensionista_session
    review_store.register_draft("604", "Registro restrito", "outra.pessoa")
    respx_mock.get(f"{main.PORTAL_URL}/jsonapi/node/noticia").mock(return_value=Response(403))
    response = await async_client.get(
        "/content/news/drafts", headers={"Authorization": f"Bearer {token}"}
    )
    assert response.status_code == 403
    assert "Registro restrito" not in response.text
    assert review_store.get_review("604")["author"] == "outra.pessoa"


def test_drupal_unpublish_reopens_review_without_reusing_previous_approval():
    review_store.register_draft("605", "Anterior", "extensionista.test", owner_uid="101")
    review_store.mark_published("605", "publicador.test")
    observed = review_store.reconcile_draft(
        "605", "Título atualizado no portal", owner_uid="101", published=False
    )
    assert observed["review_status"] == "pending"
    assert observed["title"] == "Título atualizado no portal"
    assert observed["owner_uid"] == "101"
    assert any(event["event_type"] == "published" for event in observed["events"])


@pytest.mark.parametrize("publication_date", ["2027-02-15", None])
async def test_native_creation_supplies_required_news_date_without_publish(
    async_client, extensionista_session, respx_mock, publication_date
):
    token, _ = extensionista_session
    respx_mock.get(f"{main.PORTAL_URL}/node/add/noticia").mock(
        return_value=Response(200, text='<form><input type="hidden" name="form_id" value="node_noticia_form"><input type="hidden" name="status[value]" value="1"><input type="hidden" name="body[0][format]" value="plain_text"></form>')
    )
    save = respx_mock.post(f"{main.PORTAL_URL}/node/add/noticia").mock(
        return_value=Response(302, headers={"location": f"{main.PORTAL_URL}/node/606"})
    )
    payload = {"title": "Registro de atividade", "body": "Relato conferido."}
    if publication_date:
        payload["publication_date"] = publication_date
    response = await async_client.post(
        "/content/news/draft", json=payload, headers={"Authorization": f"Bearer {token}"}
    )
    assert response.status_code == 200
    fields = parse_qs(save.calls.last.request.content.decode())
    assert fields["field_data_noticia[0][value][date]"] == [
        publication_date or date.today().isoformat()
    ]
    assert fields["status[value]"] == ["0"]
    assert "moderation_state[0][state]" not in fields
    assert response.json()["published"] is False
    assert response.json()["edit_url"] == f"{main.PORTAL_URL}/node/606/edit"
    assert review_store.get_review("606")["owner_uid"] == "101"


async def test_opportunity_creation_serializes_concurrent_requests(
    async_client, extensionista_session, monkeypatch
):
    token, _ = extensionista_session
    item = approved_opportunity()
    entered = asyncio.Event()
    release = asyncio.Event()
    calls = []

    async def create(**kwargs):
        calls.append(kwargs)
        entered.set()
        await release.wait()
        return {"id": "701"}

    monkeypatch.setattr(main, "_create_news_draft_internal", create)
    headers = {"Authorization": f"Bearer {token}"}
    first = asyncio.create_task(async_client.post(f"/opportunities/items/{item['id']}/draft", headers=headers))
    await asyncio.wait_for(entered.wait(), timeout=2)
    second = asyncio.create_task(async_client.post(f"/opportunities/items/{item['id']}/draft", headers=headers))
    await asyncio.sleep(0)
    release.set()
    responses = await asyncio.wait_for(asyncio.gather(first, second), timeout=2)

    assert sorted(response.status_code for response in responses) == [200, 409]
    assert len(calls) == 1
    assert calls[0]["publication_date"] is None
    assert rss_store.item_detail(item["id"])["drupal_draft_id"] == "701"
    created = next(response.json() for response in responses if response.status_code == 200)
    assert created["edit_url"] == f"{main.PORTAL_URL}/node/701/edit"


@pytest.mark.parametrize("draft_id", ["702", "89ea82b9-5e11-44cb-839e-321385347eef"])
async def test_linked_opportunity_cannot_create_again_after_legacy_state_regression(
    async_client, extensionista_session, monkeypatch, draft_id
):
    token, _ = extensionista_session
    item = approved_opportunity()
    rss_store.mark_draft(item["id"], "extensionista.test", draft_id)
    with rss_store.connect() as conn:
        conn.execute("UPDATE feed_item SET status='aprovado_pauta' WHERE id=?", (item["id"],))
        conn.commit()

    async def must_not_create(**kwargs):
        pytest.fail("An existing Drupal link must prevent another creation.")

    monkeypatch.setattr(main, "_create_news_draft_internal", must_not_create)
    headers = {"Authorization": f"Bearer {token}"}
    response = await async_client.post(f"/opportunities/items/{item['id']}/draft", headers=headers)
    assert response.status_code == 409
    assert "já possui" in response.json()["detail"]
    assert rss_store.item_detail(item["id"])["drupal_draft_id"] == draft_id
    detail = await async_client.get(f"/opportunities/items/{item['id']}", headers=headers)
    expected_edit_url = f"{main.PORTAL_URL}/node/702/edit" if draft_id == "702" else None
    assert detail.json()["edit_url"] == expected_edit_url


async def test_opportunity_decision_preserves_existing_link_and_rejects_regression(
    async_client, extensionista_session
):
    token, _ = extensionista_session
    item = approved_opportunity()
    rss_store.mark_draft(item["id"], "extensionista.test", "703")
    headers = {"Authorization": f"Bearer {token}"}
    rejected = await async_client.patch(
        f"/opportunities/items/{item['id']}/decision",
        json={"status": "verificado"}, headers=headers,
    )
    assert rejected.status_code == 409
    archived = await async_client.patch(
        f"/opportunities/items/{item['id']}/decision",
        json={"status": "arquivado"}, headers=headers,
    )
    assert archived.status_code == 200
    assert archived.json()["drupal_draft_id"] == "703"
    assert archived.json()["public_url"] == f"{main.PORTAL_URL}/node/703"
    repeated = rss_store.mark_draft(item["id"], "extensionista.test", "703")
    assert sum(event["event_type"] == "drupal_draft_created" for event in repeated["events"]) == 1
    with pytest.raises(rss_store.DraftConflict):
        rss_store.mark_draft(item["id"], "extensionista.test", "704")
    assert rss_store.item_detail(item["id"])["drupal_draft_id"] == "703"


@pytest.mark.parametrize(
    "patch,expected",
    [({}, "2027-12-20"), ({"deadline_at": None}, "2027-12-20"), ({"deadline_at": ""}, None)],
)
async def test_opportunity_deadline_omission_null_and_explicit_clear(
    async_client, extensionista_session, patch, expected
):
    token, _ = extensionista_session
    item = approved_opportunity()
    response = await async_client.patch(
        f"/opportunities/items/{item['id']}/decision",
        json={"status": "em_triagem", **patch},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    assert response.json()["deadline_at"] == expected
    changes = json.loads(response.json()["events"][0]["changes_json"])
    if expected is None:
        assert changes["deadline_at"] == {"from": "2027-12-20", "to": None}
    else:
        assert "deadline_at" not in changes


async def test_snapshot_includes_institutional_pages_and_working_news_link(async_client, respx_mock):
    respx_mock.get(f"{main.PORTAL_URL}/").mock(return_value=Response(200))
    respx_mock.get(f"{main.PORTAL_URL}/jsonapi").mock(
        return_value=Response(200, json={"links": {"node--page": {}, "node--noticia": {}}})
    )
    respx_mock.get(f"{main.PORTAL_URL}/jsonapi/node_type/node_type").mock(
        return_value=Response(200, json={"data": []})
    )
    respx_mock.get(f"{main.PORTAL_URL}/jsonapi/node/noticia").mock(
        return_value=Response(200, json={"data": [native_news(801, 101, published=True)]})
    )
    response = await async_client.get("/portal/snapshot")
    assert response.status_code == 200
    assert response.json()["content_types"] == ["noticia", "page"]
    assert response.json()["latest_news"][0]["public_url"] == f"{main.PORTAL_URL}/noticia-801"




@pytest.mark.parametrize(
    "format_field,expected_format,expected_body",
    [
        (
            '<input type="hidden" name="body[0][format]" value="plain_text">',
            "plain_text",
            "Texto <tags> <3 &amp;\nSegunda linha.",
        ),
        (
            '<select name="body[0][format]"><option value="plain_text">Simples</option>'
            '<option value="content_format" selected>Conteúdo</option></select>',
            "content_format",
            "<p>Texto &lt;tags&gt; &lt;3 &amp;amp;<br>Segunda linha.</p>",
        ),
        (
            '<select name="body[0][format]"><option value="full_html" selected disabled>Bloqueado</option>'
            '<optgroup disabled><option value="basic_html">Indisponível</option></optgroup>'
            '<option value="plain_text">Simples</option>'
            '<option value="webform_default">Webform</option></select>',
            "plain_text",
            "Texto <tags> <3 &amp;\nSegunda linha.",
        ),
        (
            '<input type="hidden" name="body[0][format]" value="webform_default">',
            "webform_default",
            "<p>Texto &lt;tags&gt; &lt;3 &amp;amp;<br>Segunda linha.</p>",
        ),
    ],
)
async def test_native_creation_respects_offered_format_and_escapes_only_html(
    async_client, extensionista_session, respx_mock,
    format_field, expected_format, expected_body,
):
    token, _ = extensionista_session
    respx_mock.get(f"{main.PORTAL_URL}/node/add/noticia").mock(
        return_value=Response(200, text=f'<form>{format_field}</form>')
    )
    save = respx_mock.post(f"{main.PORTAL_URL}/node/add/noticia").mock(
        return_value=Response(302, headers={"location": "/node/901"})
    )
    literal = "Texto <tags> <3 &amp;\nSegunda linha."
    response = await async_client.post(
        "/content/news/draft",
        json={"title": "Registro conferido", "summary": literal, "body": literal},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    fields = parse_qs(save.calls.last.request.content.decode())
    assert fields["body[0][format]"] == [expected_format]
    assert fields["body[0][value]"] == [expected_body]
    assert fields["body[0][summary]"] == [expected_body]
    assert fields["status[value]"] == ["0"]
    assert response.json()["id"] == "901"
    assert response.json()["edit_url"] == f"{main.PORTAL_URL}/node/901/edit"
    assert response.json()["published"] is False


@pytest.mark.parametrize(
    "format_field",
    [
        "",
        '<input type="hidden" name="body[0][format]" value="plain_text" disabled>',
        '<select name="body[0][format]" disabled><option value="plain_text">Simples</option></select>',
        '<select name="body[0][format]"><option value="">Escolha</option>'
        '<option value="full_html" disabled>Indisponível</option></select>',
    ],
)
async def test_no_available_text_format_stops_before_saving(
    async_client, extensionista_session, respx_mock, format_field
):
    token, _ = extensionista_session
    respx_mock.get(f"{main.PORTAL_URL}/node/add/noticia").mock(
        return_value=Response(200, text=f'<form>{format_field}</form>')
    )
    response = await async_client.post(
        "/content/news/draft",
        json={"title": "Registro bloqueado", "body": "Conteúdo conferido."},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 403
    assert "não ofereceu um formato" in response.json()["detail"]
    assert all(call.request.method == "GET" for call in respx_mock.calls)


async def test_plain_text_draft_review_preserves_literal_content(
    async_client, extensionista_session, respx_mock
):
    token, _ = extensionista_session
    item = native_news(902, 101)
    literal = "Texto <tags> <3 &amp;\n  Espaçamento original."
    item["attributes"]["body"] = {
        "value": literal, "summary": literal, "format": "plain_text",
        "processed": "<p>Texto processado não substitui a origem.</p>",
    }
    respx_mock.get(f"{main.PORTAL_URL}/jsonapi/node/noticia").mock(
        return_value=Response(200, json={"data": [item]})
    )
    response = await async_client.get(
        "/content/news/drafts", headers={"Authorization": f"Bearer {token}"}
    )
    assert response.status_code == 200
    result = response.json()["items"][0]
    assert result["body"] == literal
    assert result["summary"] == literal


@pytest.mark.parametrize("numeric_nid,expected_http", [(903, 200), (None, 502)])
async def test_alias_redirect_requires_real_nid_instead_of_jsonapi_uuid(
    async_client, extensionista_session, respx_mock, numeric_nid, expected_http
):
    token, _ = extensionista_session
    respx_mock.get(f"{main.PORTAL_URL}/node/add/noticia").mock(
        return_value=Response(
            200,
            text='<form><input type="hidden" name="body[0][format]" value="plain_text"></form>',
        )
    )
    respx_mock.post(f"{main.PORTAL_URL}/node/add/noticia").mock(
        return_value=Response(302, headers={"location": "/registro-conferido"})
    )
    item = native_news(numeric_nid, 101, title="Registro conferido")
    item["id"] = "89ea82b9-5e11-44cb-839e-321385347eef"
    respx_mock.get(f"{main.PORTAL_URL}/jsonapi/node/noticia").mock(
        return_value=Response(200, json={"data": [item]})
    )
    response = await async_client.post(
        "/content/news/draft",
        json={"title": "Registro conferido", "body": "Conteúdo conferido."},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == expected_http
    assert review_store.get_review(item["id"]) is None
    if numeric_nid is not None:
        assert response.json()["id"] == "903"
        assert response.json()["edit_url"] == f"{main.PORTAL_URL}/node/903/edit"
        assert review_store.get_review("903")["owner_uid"] == "101"
    else:
        assert "Confira o registro no portal antes de repetir" in response.json()["detail"]


async def test_native_validation_failure_does_not_report_success(
    async_client, extensionista_session, respx_mock
):
    token, _ = extensionista_session
    respx_mock.get(f"{main.PORTAL_URL}/node/add/noticia").mock(
        return_value=Response(
            200,
            text='<form><input type="hidden" name="body[0][format]" value="plain_text"></form>',
        )
    )
    respx_mock.post(f"{main.PORTAL_URL}/node/add/noticia").mock(
        return_value=Response(200, text='<form>Corrija os campos obrigatórios.</form>')
    )
    response = await async_client.post(
        "/content/news/draft",
        json={"title": "Registro conferido", "body": "Conteúdo conferido."},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 422
    assert "não salvou" in response.json()["detail"]["message"]
