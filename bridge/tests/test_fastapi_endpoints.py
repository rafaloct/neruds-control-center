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
            text='<form><input type="hidden" name="form_build_id" value="build-123"/><input type="hidden" name="form_id" value="node_noticia_form"/></form>',
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
        return_value=Response(200, text='<form><input type="hidden" name="form_id" value="node_noticia_form"/></form>')
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
