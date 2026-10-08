import pytest
import respx
from httpx import Response

import identity_store
import mission_store


PORTAL = "https://neruds.org"

ROSTER_PAYLOAD = {
    "accounts": [
        {
            "uid": 2,
            "name": "extensionista.1",
            "mail": "extensionista.1@neruds.org",
            "active": True,
            "roles": ["authenticated", "extensionista"],
            "created": 1728000000,
            "last_access": 1728600000,
            "last_login": 1728500000,
            "authored_nodes": 12,
            "pending_drafts": 2,
        },
        {
            "uid": 3,
            "name": "extensionista.2",
            "mail": "extensionista.2@neruds.org",
            "active": True,
            "roles": ["authenticated", "extensionista"],
            "created": 1728000100,
            "last_access": None,
            "last_login": None,
            "authored_nodes": 0,
            "pending_drafts": 0,
        },
    ],
    "actor": "coordenador.test",
}


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


async def test_identity_requires_admin_permission(
    async_client, extensionista_session, revisor_session
):
    ext_token, _ = extensionista_session
    rev_token, _ = revisor_session
    for token in (ext_token, rev_token):
        res = await async_client.get("/identity/roster", headers=_auth(token))
        assert res.status_code == 403
        assert "administer neruds extensionistas" in res.json()["detail"]

        res = await async_client.post(
            "/identity/accounts",
            json={"name": "extensionista.9", "mail": "e9@neruds.org"},
            headers=_auth(token),
        )
        assert res.status_code == 403

        res = await async_client.post(
            "/identity/accounts/2/status",
            json={"active": False},
            headers=_auth(token),
        )
        assert res.status_code == 403


@respx.mock
async def test_roster_enriches_drupal_accounts(
    async_client, admin_session, respx_mock
):
    token, _ = admin_session
    respx_mock.get(f"{PORTAL}/neruds-control/extensionistas").mock(
        return_value=Response(200, json=ROSTER_PAYLOAD)
    )

    res = await async_client.get("/identity/roster", headers=_auth(token))
    assert res.status_code == 200
    data = res.json()
    assert len(data["accounts"]) == 2
    first = data["accounts"][0]
    assert first["name"] == "extensionista.1"
    assert first["pending_drafts"] == 2
    assert "open_tasks" in first


@respx.mock
async def test_roster_counts_open_mission_tasks(
    async_client, admin_session, seeded_mission, respx_mock
):
    token, _ = admin_session
    mission = mission_store.mission_list()[0]
    tasks = mission_store.list_tasks(mission["id"], limit=5)["items"]
    task = tasks[0]
    mission_store.update_task(
        task["id"],
        actor="coordenador.test",
        changes={"primary_owner": "extensionista.1"},
    )
    mission_store.update_task(
        task["id"],
        actor="coordenador.test",
        changes={"current_stage": "Concluído"},
    )
    other = tasks[1]
    mission_store.update_task(
        other["id"],
        actor="coordenador.test",
        changes={"primary_owner": "extensionista.1"},
    )

    respx_mock.get(f"{PORTAL}/neruds-control/extensionistas").mock(
        return_value=Response(200, json=ROSTER_PAYLOAD)
    )

    res = await async_client.get("/identity/roster", headers=_auth(token))
    first = res.json()["accounts"][0]
    assert first["open_tasks"] == 1


@respx.mock
async def test_provision_account_records_event(async_client, admin_session, respx_mock):
    token, _ = admin_session
    created = {
        "uid": 9,
        "name": "extensionista.9",
        "mail": "extensionista.9@neruds.org",
        "active": True,
        "roles": ["authenticated", "extensionista"],
        "temporary_password": "TempPass-123",
        "created_by": "coordenador.test",
    }
    respx_mock.post(f"{PORTAL}/neruds-control/extensionistas").mock(
        return_value=Response(201, json=created)
    )

    res = await async_client.post(
        "/identity/accounts",
        json={"name": "extensionista.9", "mail": "extensionista.9@neruds.org"},
        headers=_auth(token),
    )
    assert res.status_code == 201
    data = res.json()
    assert data["drupal"]["temporary_password"] == "TempPass-123"
    assert data["account"]["username"] == "extensionista.9"
    assert data["account"]["drupal_uid"] == 9

    events = identity_store.list_events(username="extensionista.9")
    assert any(e["kind"] == "provisioned" for e in events)


@respx.mock
async def test_provision_conflict_propagates(async_client, admin_session, respx_mock):
    token, _ = admin_session
    respx_mock.post(f"{PORTAL}/neruds-control/extensionistas").mock(
        return_value=Response(409, json={"detail": "Nome ou e-mail já cadastrado."})
    )

    res = await async_client.post(
        "/identity/accounts",
        json={"name": "extensionista.1", "mail": "extensionista.1@neruds.org"},
        headers=_auth(token),
    )
    assert res.status_code == 409


@respx.mock
async def test_block_and_reactivate(async_client, admin_session, respx_mock):
    token, _ = admin_session
    blocked = dict(ROSTER_PAYLOAD["accounts"][0], active=False)
    respx_mock.post(
        f"{PORTAL}/neruds-control/extensionistas/2/status"
    ).mock(return_value=Response(200, json=blocked))

    res = await async_client.post(
        "/identity/accounts/2/status",
        json={"active": False},
        headers=_auth(token),
    )
    assert res.status_code == 200
    assert res.json()["account"]["active"] is False

    events = identity_store.list_events(username="extensionista.1")
    assert any(e["kind"] == "blocked" for e in events)


@respx.mock
async def test_password_reset_returns_one_time_link(
    async_client, admin_session, respx_mock
):
    token, _ = admin_session
    respx_mock.post(
        f"{PORTAL}/neruds-control/extensionistas/2/password-reset"
    ).mock(
        return_value=Response(
            200,
            json={
                "uid": 2,
                "name": "extensionista.1",
                "reset_url": "https://neruds.org/user/reset/2/xyz/login",
                "issued_by": "coordenador.test",
            },
        )
    )

    res = await async_client.post(
        "/identity/accounts/2/password-reset", headers=_auth(token)
    )
    assert res.status_code == 200
    assert res.json()["reset_url"].startswith("https://")

    events = identity_store.list_events(username="extensionista.1")
    assert any(e["kind"] == "password_reset_issued" for e in events)
    for e in events:
        assert "reset_url" not in str(e["detail"])


@respx.mock
async def test_offboarding_blocks_and_transfers(
    async_client, admin_session, seeded_mission, respx_mock
):
    token, _ = admin_session
    mission = mission_store.mission_list()[0]
    tasks = mission_store.list_tasks(mission["id"], limit=5)["items"]
    for task in tasks[:2]:
        mission_store.update_task(
            task["id"],
            actor="coordenador.test",
            changes={"primary_owner": "extensionista.1"},
        )
    # A gap task may only carry the free-text responsible; the transfer
    # must rewrite it too or clearing primary_owner would fall back to
    # the disabled account.
    fallback_task = mission_store.create_task(
        mission["id"],
        actor="extensionista.1",
        fields={"title": "Lacuna sem dono formal", "responsible": "extensionista.1"},
    )
    # Gap tasks can live on any mission — the transfer must reach beyond
    # the first one.
    with mission_store.connect() as conn:
        cur = conn.execute(
            "INSERT INTO mission (code,title,workflow_json,created_at,updated_at)"
            " VALUES ('MIN-2','Segunda missão','[]','x','x')"
        )
        conn.commit()
        second_mission = int(cur.lastrowid)
    mission_store.create_task(
        second_mission,
        actor="extensionista.1",
        fields={"title": "Lacuna noutra missão", "responsible": "extensionista.1"},
    )

    respx_mock.get(f"{PORTAL}/neruds-control/extensionistas").mock(
        return_value=Response(200, json=ROSTER_PAYLOAD)
    )
    respx_mock.post(
        f"{PORTAL}/neruds-control/extensionistas/2/status"
    ).mock(
        return_value=Response(
            200, json=dict(ROSTER_PAYLOAD["accounts"][0], active=False)
        )
    )

    res = await async_client.post(
        "/identity/accounts/2/offboarding",
        json={"transfer_to": "extensionista.2"},
        headers=_auth(token),
    )
    assert res.status_code == 200
    data = res.json()
    assert data["tasks_transferred"] == 4
    assert data["account"]["active"] is False
    assert data["account"]["offboarded_by"] == "coordenador.test"
    assert data["checklist"]["done"] >= 2

    moved = mission_store.task_detail(tasks[0]["id"])
    assert moved["primary_owner"] == "extensionista.2"
    moved_fallback = mission_store.task_detail(fallback_task["id"])
    assert moved_fallback["primary_owner"] == "extensionista.2"
    assert moved_fallback["responsible"] == "extensionista.2"

    events = identity_store.list_events(username="extensionista.1")
    assert any(e["kind"] == "offboarded" for e in events)


@respx.mock
async def test_offboarding_without_transfer_keeps_advisory(
    async_client, admin_session, seeded_mission, respx_mock
):
    token, _ = admin_session
    mission = mission_store.mission_list()[0]
    task = mission_store.list_tasks(mission["id"], limit=1)["items"][0]
    mission_store.update_task(
        task["id"],
        actor="coordenador.test",
        changes={"primary_owner": "extensionista.1"},
    )

    respx_mock.get(f"{PORTAL}/neruds-control/extensionistas").mock(
        return_value=Response(200, json=ROSTER_PAYLOAD)
    )
    respx_mock.post(
        f"{PORTAL}/neruds-control/extensionistas/2/status"
    ).mock(
        return_value=Response(
            200, json=dict(ROSTER_PAYLOAD["accounts"][0], active=False)
        )
    )

    res = await async_client.post(
        "/identity/accounts/2/offboarding", json={}, headers=_auth(token)
    )
    assert res.status_code == 200
    data = res.json()
    assert data["tasks_transferred"] == 0
    assert any("transfer_to" in adv for adv in data["advisories"])


async def test_checklist_toggle(async_client, admin_session):
    token, _ = admin_session
    record = identity_store.upsert_account(
        "extensionista.1", drupal_uid=2, provisioned_by="coordenador.test"
    )

    res = await async_client.get("/identity/accounts/2/checklist", headers=_auth(token))
    assert res.status_code == 200
    assert res.json()["done"] == 0
    assert res.json()["total"] == len(identity_store.OFFBOARDING_STEPS)

    res = await async_client.post(
        "/identity/accounts/2/checklist",
        json={"step": "mailbox_disabled", "done": True},
        headers=_auth(token),
    )
    assert res.status_code == 200
    assert res.json()["done"] == 1

    res = await async_client.post(
        "/identity/accounts/2/checklist",
        json={"step": "not_a_step", "done": True},
        headers=_auth(token),
    )
    assert res.status_code == 422


async def test_identity_events_history(async_client, admin_session):
    token, _ = admin_session
    identity_store.record_event(
        "coordenador.test", "provisioned", username="extensionista.1"
    )
    identity_store.record_event(
        "coordenador.test", "blocked", username="extensionista.1"
    )

    res = await async_client.get("/identity/events", headers=_auth(token))
    assert res.status_code == 200
    items = res.json()["items"]
    assert len(items) >= 2
    assert items[0]["kind"] == "blocked"

    res = await async_client.get(
        "/identity/events?username=extensionista.1", headers=_auth(token)
    )
    assert len(res.json()["items"]) == 2


def test_store_upsert_and_checklist():
    record = identity_store.upsert_account(
        "extensionista.5",
        drupal_uid=5,
        mail="e5@neruds.org",
        provisioned_by="coordenador.test",
    )
    assert record["active"] is True
    assert record["provisioned_by"] == "coordenador.test"

    again = identity_store.upsert_account(
        "extensionista.5", drupal_uid=5, active=False
    )
    assert again["id"] == record["id"]
    assert again["active"] is False
    assert again["mail"] == "e5@neruds.org"

    progress = identity_store.offboarding_progress(record["id"])
    assert progress["total"] == len(identity_store.OFFBOARDING_STEPS)

    with pytest.raises(KeyError):
        identity_store.set_check(record["id"], "bogus_step", True, "actor")

    with pytest.raises(KeyError):
        identity_store.get_account("extensionista.404")
