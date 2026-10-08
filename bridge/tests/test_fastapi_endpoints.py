from datetime import date, timedelta

import pytest
import respx
from httpx import Response
import main
import mission_store
import review_store
import rss_store


async def test_health_and_capabilities(async_client):
    res_health = await async_client.get("/health")
    assert res_health.status_code == 200
    data_h = res_health.json()
    assert data_h["ok"] is True
    assert data_h["service"] == "neruds-control-bridge"

    res_cap = await async_client.get("/capabilities")
    assert res_cap.status_code == 200
    data_c = res_cap.json()
    assert data_c["news_draft"] is True
    assert data_c["draft_queue"] is True


async def test_unauthenticated_access_rejected(async_client):
    endpoints = [
        ("GET", "/auth/me"),
        ("GET", "/missions"),
        ("GET", "/opportunities/items"),
        ("POST", "/content/news/draft"),
    ]
    for method, path in endpoints:
        if method == "GET":
            res = await async_client.get(path)
        else:
            res = await async_client.post(path, json={})
        assert res.status_code == 401
        assert "Sessão" in res.json()["detail"]


async def test_auth_me_and_logout(async_client, extensionista_session, respx_mock):
    token, session = extensionista_session
    headers = {"Authorization": f"Bearer {token}"}

    # Mock Drupal /user probe
    respx_mock.get("https://neruds.org/user").mock(
        return_value=Response(302, headers={"location": "https://neruds.org/user/101"})
    )

    res_me = await async_client.get("/auth/me", headers=headers)
    assert res_me.status_code == 200
    data = res_me.json()
    assert data["username"] == "extensionista.test"
    assert data["can_review"] is False
    assert data["can_publish"] is False

    # Logout
    respx_mock.get("https://neruds.org/user/logout").mock(return_value=Response(200))
    res_logout = await async_client.post("/auth/logout", headers=headers)
    assert res_logout.status_code == 200
    assert res_logout.json() == {"ok": True}

    # Session token should no longer be valid
    res_me_after = await async_client.get("/auth/me", headers=headers)
    assert res_me_after.status_code == 401


@respx.mock
async def test_create_news_draft_born_as_draft(async_client, extensionista_session, respx_mock):
    token, session = extensionista_session
    headers = {"Authorization": f"Bearer {token}"}

    # Mock Drupal form GET
    respx_mock.get("https://neruds.org/node/add/noticia").mock(
        return_value=Response(
            200,
            text='<form><input type="hidden" name="form_build_id" value="build-123"/><input type="hidden" name="form_id" value="node_noticia_form"/><input type="hidden" name="body[0][format]" value="plain_text"/></form>',
        )
    )

    # Mock Drupal form POST saving draft
    respx_mock.post("https://neruds.org/node/add/noticia").mock(
        return_value=Response(
            302,
            headers={"location": "https://neruds.org/node/356"},
        )
    )

    payload = {
        "title": "Notícia de Teste Criada por Extensionista",
        "summary": "Resumo da notícia de teste",
        "body": "Corpo detalhado da notícia de teste.",
        "opportunity_item_id": 21,
        "mission_task_id": 34,
    }

    res = await async_client.post("/content/news/draft", json=payload, headers=headers)
    assert res.status_code == 200
    data = res.json()

    assert data["ok"] is True
    assert data["id"] == "356"
    assert data["published"] is False  # MUST ALWAYS BE FALSE
    assert data["title"] == "Notícia de Teste Criada por Extensionista"

    # Verify review store has registered this draft in 'pending' status
    rev = review_store.get_review("356")
    assert rev is not None
    assert rev["review_status"] == "pending"
    assert rev["author"] == "extensionista.test"
    assert rev["opportunity_item_id"] == 21
    assert rev["mission_task_id"] == 34


async def test_negative_extensionista_permissions(async_client, extensionista_session):
    token, session = extensionista_session
    headers = {"Authorization": f"Bearer {token}"}

    review_store.register_draft("356", title="Notícia 356", author="extensionista.test")

    # Extensionista CANNOT review draft
    res_review = await async_client.patch(
        "/content/news/drafts/356/review",
        json={"status": "approved", "note": "Tentativa de auto-aprovação"},
        headers=headers,
    )
    assert res_review.status_code == 403
    assert "revisar" in res_review.json()["detail"]

    # Extensionista CANNOT publish draft
    res_pub = await async_client.post(
        "/content/news/drafts/356/publish",
        headers=headers,
    )
    assert res_pub.status_code == 403
    assert "publicar" in res_pub.json()["detail"]


async def test_author_can_resubmit_own_draft(async_client, extensionista_session, respx_mock):
    token, _ = extensionista_session
    headers = {"Authorization": f"Bearer {token}"}
    review_store.register_draft("357", title="Notícia 357", author="extensionista.test")
    respx_mock.get(f"{main.PORTAL_URL}/jsonapi/node/noticia").mock(
        return_value=Response(
            200,
            json={"data": [{
                "id": "uuid-357",
                "attributes": {"drupal_internal__nid": 357, "title": "Notícia 357", "status": False},
                "relationships": {"uid": {"data": {
                    "type": "user--user", "id": "user-101",
                    "meta": {"drupal_internal__target_id": 101},
                }}},
            }]},
        )
    )
    review_store.decide(
        "357",
        actor="revisor.test",
        status="changes_requested",
        note="Inclua a fonte.",
    )

    res = await async_client.patch(
        "/content/news/drafts/357/review",
        json={"status": "pending", "note": "Fonte incluída."},
        headers=headers,
    )

    assert res.status_code == 200
    assert res.json()["review"]["review_status"] == "pending"
    assert res.json()["review"]["events"][0]["actor"] == "extensionista.test"


@respx.mock
async def test_draft_queue_filters_status_author_and_search(
    async_client, extensionista_session, respx_mock
):
    token, _ = extensionista_session
    headers = {"Authorization": f"Bearer {token}"}
    review_store.register_draft("601", title="Edital da autora", author="extensionista.test")
    review_store.register_draft("602", title="Notícia de terceiro", author="outra.pessoa")
    review_store.decide("602", actor="revisor.test", status="approved", note="Aprovado.")

    respx_mock.get("https://neruds.org/jsonapi/node/noticia").mock(
        return_value=Response(
            200,
            json={
                "data": [
                    {
                        "id": "uuid-601",
                        "attributes": {
                            "drupal_internal__nid": 601,
                            "title": "Edital da autora",
                            "changed": "2026-10-05T00:00:00+00:00",
                        },
                    },
                    {
                        "id": "uuid-602",
                        "attributes": {
                            "drupal_internal__nid": 602,
                            "title": "Notícia de terceiro",
                            "changed": "2026-10-05T00:00:00+00:00",
                        },
                    },
                ]
            },
        )
    )

    res = await async_client.get(
        "/content/news/drafts?status=pending&mine_only=true&query=edital",
        headers=headers,
    )

    assert res.status_code == 200
    assert [item["nid"] for item in res.json()["items"]] == [601]


async def test_negative_revisor_permissions(async_client, revisor_session):
    token, session = revisor_session
    headers = {"Authorization": f"Bearer {token}"}

    review_store.register_draft("356", title="Notícia 356", author="extensionista.test")
    review_store.decide("356", actor="revisor.test", status="approved", note="Aprovado")

    # Revisor CANNOT publish draft
    res_pub = await async_client.post(
        "/content/news/drafts/356/publish",
        headers=headers,
    )
    assert res_pub.status_code == 403
    assert "publicar" in res_pub.json()["detail"]


async def test_review_and_publish_workflow(async_client, revisor_session, publicador_session, respx_mock):
    rev_token, _ = revisor_session
    pub_token, _ = publicador_session

    rev_headers = {"Authorization": f"Bearer {rev_token}"}
    pub_headers = {"Authorization": f"Bearer {pub_token}"}

    review_store.register_draft("500", title="Rascunho de Teste 500", author="extensionista.test")

    # 1. Attempting to publish unapproved draft returns 409 Conflict
    res_early_pub = await async_client.post("/content/news/drafts/500/publish", headers=pub_headers)
    assert res_early_pub.status_code == 409
    assert "aprovado" in res_early_pub.json()["detail"]

    # 2. Revisor requests changes without note -> returns 422
    res_dev_nonote = await async_client.patch(
        "/content/news/drafts/500/review",
        json={"status": "changes_requested", "note": "   "},
        headers=rev_headers,
    )
    assert res_dev_nonote.status_code == 422
    assert "Ajustado" in res_dev_nonote.json()["detail"] or "ajustado" in res_dev_nonote.json()["detail"]

    # 3. Revisor requests changes with note
    res_dev = await async_client.patch(
        "/content/news/drafts/500/review",
        json={"status": "changes_requested", "note": "Corrigir os termos técnicos."},
        headers=rev_headers,
    )
    assert res_dev.status_code == 200
    assert res_dev.json()["review"]["review_status"] == "changes_requested"

    # 4. Revisor approves draft
    res_approve = await async_client.patch(
        "/content/news/drafts/500/review",
        json={"status": "approved", "note": "Tudo corrigido, aprovado."},
        headers=rev_headers,
    )
    assert res_approve.status_code == 200
    assert res_approve.json()["review"]["review_status"] == "approved"

    # 5. Publicador publishes draft
    respx_mock.post("https://neruds.org/neruds-control/news/500/publish").mock(
        return_value=Response(200, json={"published": True})
    )

    res_pub = await async_client.post("/content/news/drafts/500/publish", headers=pub_headers)
    assert res_pub.status_code == 200
    pub_data = res_pub.json()
    assert pub_data["ok"] is True
    assert pub_data["nid"] == 500
    assert pub_data["published"] is True
    assert pub_data["review"]["review_status"] == "published"


async def test_opportunity_to_draft_workflow(async_client, extensionista_session, respx_mock):
    token, _ = extensionista_session
    headers = {"Authorization": f"Bearer {token}"}

    # Add a manual opportunity
    item = rss_store.add_manual_item(
        title="Oportunidade Edital Sebrae",
        url="https://neruds.org/oportunidades/sebrae-2026",
        category="Edital",
        actor="extensionista.test",
    )
    item_id = item["id"]

    # Attempting to convert opportunity to draft before approval returns 409 Conflict
    res_early_draft = await async_client.post(f"/opportunities/items/{item_id}/draft", headers=headers)
    assert res_early_draft.status_code == 409
    assert "aprovada como pauta" in res_early_draft.json()["detail"]

    # Approve opportunity pauta
    rss_store.decide(item_id, actor="revisor.test", status="aprovado_pauta", note="Pauta aprovada.")

    # Mock Drupal form GET & POST for draft creation
    respx_mock.get("https://neruds.org/node/add/noticia").mock(
        return_value=Response(200, text='<form><input type="hidden" name="form_id" value="node_noticia_form"/><input type="hidden" name="body[0][format]" value="plain_text"/></form>')
    )
    respx_mock.post("https://neruds.org/node/add/noticia").mock(
        return_value=Response(302, headers={"location": "https://neruds.org/node/789"})
    )

    # Convert approved opportunity to draft
    res_draft = await async_client.post(f"/opportunities/items/{item_id}/draft", headers=headers)
    assert res_draft.status_code == 200
    data = res_draft.json()
    assert data["ok"] is True
    assert data["drupal_draft_id"] == "789"
    assert data["published"] is False

    # Check that item status in rss_store is now 'rascunho_criado'
    updated_item = rss_store.item_detail(item_id)
    assert updated_item["status"] == "rascunho_criado"
    assert updated_item["drupal_draft_id"] == "789"
    review = review_store.get_review("789")
    assert review is not None
    assert review["opportunity_item_id"] == item_id


async def test_mission_endpoints(async_client, extensionista_session, seeded_mission):
    token, _ = extensionista_session
    headers = {"Authorization": f"Bearer {token}"}

    # List missions
    res_m = await async_client.get("/missions", headers=headers)
    assert res_m.status_code == 200
    assert len(res_m.json()) == 1

    # Mission dashboard
    res_dash = await async_client.get("/missions/1/dashboard", headers=headers)
    assert res_dash.status_code == 200
    assert res_dash.json()["code"] == "GESTAO_PORTAL_NERUDS"

    # Mission tasks
    res_tasks = await async_client.get("/missions/1/tasks", headers=headers)
    assert res_tasks.status_code == 200
    tasks = res_tasks.json()["items"]
    assert len(tasks) > 0

    first_task_id = tasks[0]["id"]

    # Patch task
    res_patch = await async_client.patch(
        f"/mission-tasks/{first_task_id}",
        json={"current_stage": "Em pesquisa", "note": "Atualização via API"},
        headers=headers,
    )
    assert res_patch.status_code == 200
    assert res_patch.json()["current_stage"] == "Em pesquisa"

    # Get a valid checklist template item
    with mission_store.connect() as conn:
        tpl = conn.execute("SELECT kind, item_order FROM checklist_template ORDER BY item_order LIMIT 1").fetchone()
        v_kind, v_order = tpl["kind"], tpl["item_order"]

    # Patch checklist item
    res_check = await async_client.patch(
        f"/mission-tasks/{first_task_id}/checklists/{v_kind}/{v_order}",
        json={"completed": True, "note": "OK via API"},
        headers=headers,
    )
    assert res_check.status_code == 200


async def test_mission_assignment_fields_require_reviewer_permission(
    async_client, extensionista_session, revisor_session, seeded_mission
):
    extensionista_token, _ = extensionista_session
    revisor_token, _ = revisor_session
    extensionista_headers = {"Authorization": f"Bearer {extensionista_token}"}
    revisor_headers = {"Authorization": f"Bearer {revisor_token}"}

    task = mission_store.list_tasks(1, limit=1)["items"][0]
    task_id = task["id"]
    original = mission_store.task_detail(task_id)

    denied = await async_client.patch(
        f"/mission-tasks/{task_id}",
        json={
            "primary_owner": "outra.pessoa",
            "cross_reviewer": "revisor.test",
            "internal_deadline": "2026-12-31",
        },
        headers=extensionista_headers,
    )
    assert denied.status_code == 403
    assert "revisão/coordenação" in denied.json()["detail"]

    after_denied = mission_store.task_detail(task_id)
    assert after_denied["primary_owner"] == original["primary_owner"]
    assert after_denied["cross_reviewer"] == original["cross_reviewer"]
    assert after_denied["internal_deadline"] == original["internal_deadline"]

    operational = await async_client.patch(
        f"/mission-tasks/{task_id}",
        json={"current_stage": "Em pesquisa", "note": "Avanço operacional"},
        headers=extensionista_headers,
    )
    assert operational.status_code == 200
    assert operational.json()["current_stage"] == "Em pesquisa"

    allowed = await async_client.patch(
        f"/mission-tasks/{task_id}",
        json={
            "primary_owner": "extensionista.2",
            "cross_reviewer": "revisor.test",
            "internal_deadline": "2026-12-31",
        },
        headers=revisor_headers,
    )
    assert allowed.status_code == 200
    assert allowed.json()["primary_owner"] == "extensionista.2"
    assert allowed.json()["cross_reviewer"] == "revisor.test"
    assert allowed.json()["internal_deadline"] == "2026-12-31"


async def test_mission_task_portal_link_via_api(
    async_client, extensionista_session, seeded_mission
):
    token, _ = extensionista_session
    headers = {"Authorization": f"Bearer {token}"}
    task_id = mission_store.list_tasks(1, limit=1)["items"][0]["id"]

    response = await async_client.patch(
        f"/mission-tasks/{task_id}",
        json={
            "public_url": f"{main.PORTAL_URL}/node/555",
            "edit_url": f"{main.PORTAL_URL}/node/555/edit",
        },
        headers=headers,
    )
    assert response.status_code == 200
    assert response.json()["public_url"] == f"{main.PORTAL_URL}/node/555"
    assert response.json()["edit_url"] == f"{main.PORTAL_URL}/node/555/edit"

    foreign = await async_client.patch(
        f"/mission-tasks/{task_id}",
        json={"public_url": "https://other.example.org/node/777"},
        headers=headers,
    )
    assert foreign.status_code == 422

    not_a_node = await async_client.patch(
        f"/mission-tasks/{task_id}",
        json={"public_url": f"{main.PORTAL_URL}/admin/content"},
        headers=headers,
    )
    assert not_a_node.status_code == 422

    edit_as_public = await async_client.patch(
        f"/mission-tasks/{task_id}",
        json={"public_url": f"{main.PORTAL_URL}/node/555/edit"},
        headers=headers,
    )
    assert edit_as_public.status_code == 422

    mismatched_pair = await async_client.patch(
        f"/mission-tasks/{task_id}",
        json={
            "public_url": f"{main.PORTAL_URL}/node/555",
            "edit_url": f"{main.PORTAL_URL}/node/999/edit",
        },
        headers=headers,
    )
    assert mismatched_pair.status_code == 422

    # Partial PATCH must also match the persisted counterpart (still /555).
    partial_mismatch = await async_client.patch(
        f"/mission-tasks/{task_id}",
        json={"edit_url": f"{main.PORTAL_URL}/node/999/edit"},
        headers=headers,
    )
    assert partial_mismatch.status_code == 422

    bad_port = await async_client.patch(
        f"/mission-tasks/{task_id}",
        json={"public_url": "https://neruds.org:abc/node/1"},
        headers=headers,
    )
    assert bad_port.status_code == 422

    # Equivalent spellings canonicalize to the stored form — no relink churn.
    equivalent = await async_client.patch(
        f"/mission-tasks/{task_id}",
        json={"public_url": f"{main.PORTAL_URL}/node/555/?utm_source=x"},
        headers=headers,
    )
    assert equivalent.status_code == 200
    assert equivalent.json()["public_url"] == f"{main.PORTAL_URL}/node/555"


async def test_create_task_from_portal_gap(
    async_client, extensionista_session, seeded_mission
):
    token, _ = extensionista_session
    headers = {"Authorization": f"Bearer {token}"}

    created = await async_client.post(
        "/missions/1/tasks",
        json={
            "title": "Preencher resumo — Publicação X",
            "content_type": "Publicação Científica",
            "responsible": "extensionista.test",
            "action": "Abrir a ficha no portal e completar os campos ausentes",
            "gaps": "Faltam no portal: Resumo",
            "public_url": f"{main.PORTAL_URL}/node/55",
            "edit_url": f"{main.PORTAL_URL}/node/55/edit",
            "gap_bundle": "publicacao_cientifica",
            "gap_fields": ["field_resumo_publicacao"],
            "note": "Criada a partir da lacuna monitorada",
        },
        headers=headers,
    )
    assert created.status_code == 201
    task = created.json()
    assert task["current_stage"] == "Triagem"
    assert task["status"] == "A fazer"
    assert task["responsible"] == "extensionista.test"
    assert task["gap_bundle"] == "publicacao_cientifica"
    assert task["gap_fields"] == ["field_resumo_publicacao"]
    assert task["public_url"] == f"{main.PORTAL_URL}/node/55"
    assert task["edit_url"] == f"{main.PORTAL_URL}/node/55/edit"
    # App-created rows take negative spreadsheet rows so a re-seed can
    # never overwrite them.
    assert task["spreadsheet_row"] < 0
    assert task["events"][0]["event_type"] == "task_created"

    # A second creation gets a distinct generated row.
    second = await async_client.post(
        "/missions/1/tasks",
        json={"title": "Tarefa manual"},
        headers=headers,
    )
    assert second.status_code == 201
    assert second.json()["spreadsheet_row"] < task["spreadsheet_row"]

    # Equivalent link spellings canonicalize on create too.
    spelled = await async_client.post(
        "/missions/1/tasks",
        json={
            "title": "Link equivalente",
            "public_url": f"{main.PORTAL_URL}/node/77/?utm=x",
            "edit_url": f"{main.PORTAL_URL}/node/77/edit",
        },
        headers=headers,
    )
    assert spelled.status_code == 201
    assert spelled.json()["public_url"] == f"{main.PORTAL_URL}/node/77"


async def test_create_task_rejections(
    async_client, extensionista_session, revisor_session, seeded_mission
):
    token, _ = extensionista_session
    revisor_token, _ = revisor_session
    headers = {"Authorization": f"Bearer {token}"}
    revisor_headers = {"Authorization": f"Bearer {revisor_token}"}

    mismatch = await async_client.post(
        "/missions/1/tasks",
        json={
            "title": "Par divergente",
            "public_url": f"{main.PORTAL_URL}/node/55",
            "edit_url": f"{main.PORTAL_URL}/node/56/edit",
        },
        headers=headers,
    )
    assert mismatch.status_code == 422

    foreign = await async_client.post(
        "/missions/1/tasks",
        json={
            "title": "Ficha externa",
            "public_url": "https://other.example.org/node/9",
        },
        headers=headers,
    )
    assert foreign.status_code == 422

    unknown_bundle = await async_client.post(
        "/missions/1/tasks",
        json={"title": "Tipo ruim", "gap_bundle": "inexistente"},
        headers=headers,
    )
    assert unknown_bundle.status_code == 422

    unknown_field = await async_client.post(
        "/missions/1/tasks",
        json={
            "title": "Campo ruim",
            "gap_bundle": "noticia",
            "gap_fields": ["field_resumo_publicacao"],
        },
        headers=headers,
    )
    assert unknown_field.status_code == 422

    orphan_fields = await async_client.post(
        "/missions/1/tasks",
        json={"title": "Sem tipo", "gap_fields": ["field_doi"]},
        headers=headers,
    )
    assert orphan_fields.status_code == 422

    denied = await async_client.post(
        "/missions/1/tasks",
        json={"title": "Sem permissão", "primary_owner": "outra.pessoa"},
        headers=headers,
    )
    assert denied.status_code == 403

    allowed = await async_client.post(
        "/missions/1/tasks",
        json={"title": "Com permissão", "primary_owner": "ext.1"},
        headers=revisor_headers,
    )
    assert allowed.status_code == 201

    missing = await async_client.post(
        "/missions/999/tasks",
        json={"title": "Missão ausente"},
        headers=headers,
    )
    assert missing.status_code == 404


async def test_mission_sla_filters_reports_exports_and_saved_filters(
    async_client, extensionista_session, seeded_mission
):
    token, _ = extensionista_session
    headers = {"Authorization": f"Bearer {token}"}
    task = mission_store.list_tasks(1, limit=1)["items"][0]
    mission_store.update_task(
        task["id"],
        actor="extensionista.test",
        changes={"internal_deadline": "2020-01-01"},
    )

    res_tasks = await async_client.get(
        "/missions/1/tasks?due_status=overdue",
        headers=headers,
    )
    assert res_tasks.status_code == 200
    assert any(item["id"] == task["id"] for item in res_tasks.json()["items"])

    res_save = await async_client.post(
        "/missions/1/saved-filters",
        json={"name": "P0 atrasadas", "filters": {"priority": "P0", "due_status": "overdue"}},
        headers=headers,
    )
    assert res_save.status_code == 200
    filter_id = res_save.json()["id"]
    assert (await async_client.get("/missions/1/saved-filters", headers=headers)).status_code == 200
    assert (
        await async_client.delete(
            f"/missions/1/saved-filters/{filter_id}",
            headers=headers,
        )
    ).json() == {"ok": True}

    res_report = await async_client.get("/missions/1/weekly-report", headers=headers)
    assert res_report.status_code == 200
    assert res_report.json()["summary"]["overdue"] >= 1

    res_export = await async_client.get("/missions/1/export.xlsx", headers=headers)
    assert res_export.status_code == 200
    assert res_export.headers["content-type"].startswith(
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    )
    assert res_export.content[:2] == b"PK"


async def test_opportunity_manual_capture_endpoint(async_client, extensionista_session):
    token, _ = extensionista_session
    headers = {"Authorization": f"Bearer {token}"}

    payload = {
        "title": "Chamada para Capítulo de Livro NERUDS 2026",
        "url": "https://neruds.org/chamada-capitulo-2026",
        "category": "Chamada para revista",
        "summary": "Submissão de capítulos até novembro.",
    }

    res = await async_client.post("/opportunities/items/manual", json=payload, headers=headers)
    assert res.status_code == 200
    data = res.json()
    assert data["title"] == "Chamada para Capítulo de Livro NERUDS 2026"
    assert data["category"] == "Chamada para revista"
    assert data["status"] == "novo"


async def test_opportunity_approval_requires_reviewer_permission(
    async_client, extensionista_session, revisor_session
):
    extensionista_token, _ = extensionista_session
    revisor_token, _ = revisor_session
    extensionista_headers = {"Authorization": f"Bearer {extensionista_token}"}
    revisor_headers = {"Authorization": f"Bearer {revisor_token}"}

    item = rss_store.add_manual_item(
        title="Edital para aprovação por revisor",
        url="https://example.org/edital-revisor",
        category="Edital",
        summary="Oportunidade aguardando decisão editorial.",
        actor="extensionista.test",
    )
    item_id = item["id"]

    denied = await async_client.patch(
        f"/opportunities/items/{item_id}/decision",
        json={"status": "aprovado_pauta", "note": "Tentativa sem revisão."},
        headers=extensionista_headers,
    )
    assert denied.status_code == 403
    assert "revisão/coordenação" in denied.json()["detail"]
    assert rss_store.item_detail(item_id)["status"] == "novo"

    allowed = await async_client.patch(
        f"/opportunities/items/{item_id}/decision",
        json={"status": "aprovado_pauta", "note": "Pauta aprovada pelo revisor."},
        headers=revisor_headers,
    )
    assert allowed.status_code == 200
    assert allowed.json()["status"] == "aprovado_pauta"
    assert allowed.json()["reviewed_by"] == "revisor.test"


async def test_opportunity_deadline_filter_and_duplicate_draft_rejection(
    async_client, extensionista_session
):
    token, _ = extensionista_session
    headers = {"Authorization": f"Bearer {token}"}
    original = rss_store.add_manual_item(
        title="Edital de extensão 2026",
        url="https://neruds.org/edital-extensao",
        category="Edital",
        actor="user",
        deadline_at=(date.today() + timedelta(days=3)).isoformat(),
    )
    duplicate = rss_store.add_manual_item(
        title="Edital de extensão 2026",
        url="https://other.example.org/edital-extensao",
        category="Edital",
        actor="user",
    )
    rss_store.decide(
        duplicate["id"],
        actor="reviewer",
        status="aprovado_pauta",
    )

    res_items = await async_client.get(
        "/opportunities/items?deadline_status=upcoming", headers=headers
    )
    assert res_items.status_code == 200
    assert [item["id"] for item in res_items.json()["items"]] == [original["id"]]

    res_draft = await async_client.post(
        f"/opportunities/items/{duplicate['id']}/draft", headers=headers
    )
    assert res_draft.status_code == 409
    assert "duplicada" in res_draft.json()["detail"]


async def test_mission_evidence_files(async_client, extensionista_session, seeded_mission):
    token, _ = extensionista_session
    headers = {"Authorization": f"Bearer {token}"}
    task = mission_store.list_tasks(1, limit=1)["items"][0]
    task_id = task["id"]

    res_upload = await async_client.post(
        f"/mission-tasks/{task_id}/evidence-files",
        files={"file": ("relatorio visita.pdf", b"%PDF-1.4 fake", "application/pdf")},
        data={"note": "Relatório da visita"},
        headers=headers,
    )
    assert res_upload.status_code == 201
    evidence = res_upload.json()["evidence"]
    assert evidence["filename"] == "relatorio_visita.pdf"
    assert evidence["content_type"] == "application/pdf"
    assert evidence["uploaded_by"] == "extensionista.test"

    res_list = await async_client.get(
        f"/mission-tasks/{task_id}/evidence-files", headers=headers
    )
    assert res_list.status_code == 200
    assert [f["id"] for f in res_list.json()["files"]] == [evidence["id"]]

    res_dl = await async_client.get(
        f"/mission-evidence/{evidence['id']}", headers=headers
    )
    assert res_dl.status_code == 200
    assert res_dl.content == b"%PDF-1.4 fake"

    res_detail = await async_client.get(f"/mission-tasks/{task_id}", headers=headers)
    assert res_detail.status_code == 200
    assert res_detail.json()["evidence_files"][0]["id"] == evidence["id"]

    res_missing_task = await async_client.post(
        "/mission-tasks/99999/evidence-files",
        files={"file": ("x.txt", b"x", "text/plain")},
        headers=headers,
    )
    assert res_missing_task.status_code == 404

    res_missing_ev = await async_client.get("/mission-evidence/99999", headers=headers)
    assert res_missing_ev.status_code == 404
