import pytest
import respx
from httpx import Response

import main
import mission_automation
import mission_store
import review_store


def _first_task(mission_id=1):
    return mission_store.list_tasks(mission_id, limit=1)["items"][0]


def test_suggest_next_tasks_prioritizes_p0(seeded_mission):
    suggestions = mission_automation.suggest_next_tasks(1, limit=10)
    assert suggestions
    priorities = [item["priority"] for item in suggestions]
    assert all(p in ("P0", "P1") for p in priorities)
    assert "P2" not in priorities
    if "P1" in priorities:
        assert priorities.index("P1") > priorities.index("P0") or "P0" not in priorities
    for item in suggestions:
        assert item["reason"]
        assert item["current_stage"] not in ("Concluído", "Bloqueado")


def test_suggest_next_tasks_skips_finished(seeded_mission):
    task = _first_task()
    mission_store.update_task(
        task["id"], actor="test.user", changes={"priority": "P0", "current_stage": "Concluído"}
    )
    suggestions = mission_automation.suggest_next_tasks(1, limit=500)
    assert all(item["id"] != task["id"] for item in suggestions)


def test_missing_evidence_flags_and_clears(seeded_mission):
    task = _first_task()
    # Triagem não exige evidência
    mission_store.update_task(
        task["id"],
        actor="t",
        changes={"current_stage": "Triagem", "evidence": ""},
    )
    assert not any(
        item["id"] == task["id"]
        for item in mission_automation.missing_evidence(1)["items"]
    )

    # Etapa que exige evidência sem evidência registrada
    mission_store.update_task(
        task["id"], actor="t", changes={"current_stage": "Revisão cruzada"}
    )
    flagged = mission_automation.missing_evidence(1)
    assert any(item["id"] == task["id"] for item in flagged["items"])

    # Evidência em texto limpa o sinal
    mission_store.update_task(
        task["id"], actor="t", changes={"evidence": "Relatório conferido"}
    )
    assert not any(
        item["id"] == task["id"]
        for item in mission_automation.missing_evidence(1)["items"]
    )


def test_missing_evidence_accepts_evidence_url_event(seeded_mission):
    task = _first_task()
    mission_store.update_task(
        task["id"],
        actor="t",
        changes={"current_stage": "Revisão cruzada", "evidence": ""},
    )
    mission_store.update_task(
        task["id"], actor="t", changes={}, evidence_url="https://example.org/ev"
    )
    assert not any(
        item["id"] == task["id"]
        for item in mission_automation.missing_evidence(1)["items"]
    )


def test_possible_duplicates_internal_url(seeded_mission):
    tasks = mission_store.list_tasks(1, limit=2)["items"]
    with mission_store.connect() as conn:
        conn.execute(
            "UPDATE mission_task SET public_url=? WHERE id=?",
            (tasks[1]["public_url"], tasks[0]["id"]),
        )
        conn.commit()
    dupes = mission_automation.possible_duplicates(1)
    assert dupes["count"] >= 1
    url_groups = [g for g in dupes["internal"] if g["kind"] == "url"]
    assert any(
        {t["id"] for t in g["tasks"]} == {tasks[0]["id"], tasks[1]["id"]}
        for g in url_groups
    )


def test_possible_duplicates_matches_drupal_draft(seeded_mission):
    task = _first_task()
    review_store.register_draft("999", title=task["title"], author="revisor.test")
    dupes = mission_automation.possible_duplicates(1)
    match = next(
        (m for m in dupes["drupal_matches"] if m["task"]["id"] == task["id"]), None
    )
    assert match is not None
    assert match["drupal_nid"] == "999"


def test_url_check_with_injected_fetch(seeded_mission):
    calls = []

    def fake_fetch(url):
        calls.append(url)
        if "contato" in url:
            return 404, None
        return 200, None

    result = mission_automation.check_public_urls(1, limit=10, fetch=fake_fetch)
    assert result["checked"] == 10
    assert len(calls) == 10
    assert all(u.startswith("http") for u in calls)

    summary = mission_automation.url_check_summary(1)
    assert summary["checked"] == 10
    assert summary["pending"] > 0
    if result["broken"]:
        assert summary["broken"] == result["broken"]
        assert summary["issues"]

    # Recheck não repete tarefas já verificadas quando há pendentes
    calls.clear()
    mission_automation.check_public_urls(1, limit=5, fetch=fake_fetch)
    assert len(calls) == 5


def test_url_check_never_touches_task_stage(seeded_mission):
    task = _first_task()
    before = mission_store.task_detail(task["id"])
    mission_automation.check_public_urls(1, limit=3, fetch=lambda url: (200, None))
    after = mission_store.task_detail(task["id"])
    assert after["current_stage"] == before["current_stage"]
    assert after["status"] == before["status"]


async def test_automation_endpoint(async_client, extensionista_session):
    token, _ = extensionista_session
    headers = {"Authorization": f"Bearer {token}"}
    res = await async_client.get("/missions/1/automation", headers=headers)
    assert res.status_code == 404  # missão ainda não semeada

    mission_store.seed_from_json(force=True)
    res = await async_client.get("/missions/1/automation", headers=headers)
    assert res.status_code == 200
    data = res.json()
    assert "suggested_tasks" in data
    assert "missing_evidence" in data
    assert "possible_duplicates" in data
    assert "url_check" in data


async def test_url_check_endpoint(async_client, extensionista_session, monkeypatch):
    token, _ = extensionista_session
    headers = {"Authorization": f"Bearer {token}"}
    mission_store.seed_from_json(force=True)
    monkeypatch.setattr(
        mission_automation, "_default_fetch", lambda url: (200, None)
    )
    res = await async_client.post(
        "/missions/1/url-check", params={"limit": 3}, headers=headers
    )
    assert res.status_code == 200
    data = res.json()
    assert data["checked"] == 3
    assert data["broken"] == 0
    assert data["summary"]["checked"] == 3


@respx.mock
async def test_drupal_duplicates_endpoint(
    async_client, extensionista_session, respx_mock
):
    token, _ = extensionista_session
    headers = {"Authorization": f"Bearer {token}"}
    mission_store.seed_from_json(force=True)

    noticia = next(
        t
        for t in mission_store.list_tasks(1, limit=500)["items"]
        if t["content_type"] == "Notícia"
    )
    respx_mock.get("https://neruds.org/jsonapi/node/noticia").mock(
        return_value=Response(
            200,
            json={
                "data": [
                    {
                        "id": "uuid-1",
                        "attributes": {
                            "drupal_internal__nid": 42,
                            "title": noticia["title"],
                            "status": True,
                            "path": {"alias": "/alguma-noticia"},
                        },
                    }
                ]
            },
        )
    )

    res = await async_client.get(
        f"/mission-tasks/{noticia['id']}/drupal-duplicates", headers=headers
    )
    assert res.status_code == 200
    data = res.json()
    assert data["bundle"] == "noticia"
    assert data["matches"][0]["nid"] == 42


async def test_drupal_duplicates_unmapped_type(async_client, extensionista_session):
    token, _ = extensionista_session
    headers = {"Authorization": f"Bearer {token}"}
    mission_store.seed_from_json(force=True)
    task = _first_task()
    with mission_store.connect() as conn:
        conn.execute(
            "UPDATE mission_task SET content_type='Tipo Inexistente' WHERE id=?",
            (task["id"],),
        )
        conn.commit()
    res = await async_client.get(
        f"/mission-tasks/{task['id']}/drupal-duplicates", headers=headers
    )
    assert res.status_code == 200
    assert res.json()["matches"] == []


async def test_automation_endpoints_require_auth(async_client):
    assert (await async_client.get("/missions/1/automation")).status_code == 401
    assert (await async_client.post("/missions/1/url-check")).status_code == 401
    assert (
        await async_client.get("/mission-tasks/1/drupal-duplicates")
    ).status_code == 401
