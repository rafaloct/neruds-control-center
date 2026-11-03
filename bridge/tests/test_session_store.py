"""Tests for persistent bridge sessions (SQLite + encrypted secrets)."""

import json
import sqlite3
from datetime import datetime, timedelta, timezone

import pytest

import session_store


def _session(username="extensionista.test", **overrides):
    base = {
        "username": username,
        "uid": "101",
        "roles": ["authenticated", "extensionista"],
        "can_review": False,
        "can_publish": False,
        "can_admin_users": False,
        "cookies": {"SSESSabc": "drupal-cookie-value"},
        "csrf": "csrf-token-value",
        "created_at": session_store.utcnow(),
        "last_seen": session_store.utcnow(),
    }
    base.update(overrides)
    return base


def test_session_roundtrip_preserves_shape(temp_db):
    session_store.save("tok-1", _session())
    loaded = session_store.get("tok-1")
    assert loaded is not None
    assert loaded["username"] == "extensionista.test"
    assert loaded["uid"] == "101"
    assert loaded["roles"] == ["authenticated", "extensionista"]
    assert loaded["cookies"] == {"SSESSabc": "drupal-cookie-value"}
    assert loaded["csrf"] == "csrf-token-value"
    assert loaded["can_review"] is False


def test_secrets_are_encrypted_at_rest(temp_db):
    session_store.save("tok-secret", _session())
    raw = sqlite3.connect(session_store.DB_PATH).execute(
        "SELECT secrets_enc FROM bridge_session WHERE token = 'tok-secret'"
    ).fetchone()[0]
    assert "drupal-cookie-value" not in raw
    assert "csrf-token-value" not in raw
    assert "SSESSabc" not in raw


def test_session_survives_fresh_connection(temp_db):
    """Simulates a bridge restart: a new connection still finds the session."""
    session_store.save("tok-restart", _session())
    # _connect() creates a new connection each call; get() already exercises it.
    assert session_store.get("tok-restart") is not None
    assert "tok-restart" in session_store.SESSIONS


def test_dict_facade_operations(temp_db):
    store = session_store.SESSIONS
    store["tok-facade"] = _session()
    assert len(store) == 1
    assert store.get("tok-facade")["username"] == "extensionista.test"
    popped = store.pop("tok-facade")
    assert popped["csrf"] == "csrf-token-value"
    assert store.get("tok-facade") is None
    assert len(store) == 0
    assert store.pop("missing") is None


def test_touch_updates_last_seen(temp_db):
    old = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    session_store.save("tok-touch", _session(last_seen=old))
    session_store.touch("tok-touch")
    loaded = session_store.get("tok-touch")
    assert loaded["last_seen"] != old


def test_purge_idle_removes_only_stale(temp_db):
    stale = (datetime.now(timezone.utc) - timedelta(hours=9)).isoformat()
    session_store.save("tok-stale", _session(last_seen=stale))
    session_store.save("tok-fresh", _session(username="fresh.user"))
    removed = session_store.purge_idle(timedelta(hours=8))
    assert removed == 1
    assert session_store.get("tok-stale") is None
    assert session_store.get("tok-fresh") is not None


def test_delete_and_clear(temp_db):
    session_store.save("tok-a", _session())
    session_store.save("tok-b", _session(username="b.user"))
    session_store.delete("tok-a")
    assert session_store.count() == 1
    session_store.clear()
    assert session_store.count() == 0


def test_missing_session_returns_none(temp_db):
    assert session_store.get("does-not-exist") is None


# ---------------------------------------------------------------------------
# Remote app config endpoints
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_get_app_config_defaults(async_client):
    response = await async_client.get("/config/app")
    assert response.status_code == 200
    data = response.json()
    assert data["app_name"] == "NERUDS Control Center"
    assert data["features"]["missions"] is True
    assert data["schema_version"] == 1


@pytest.mark.asyncio
async def test_put_app_config_requires_admin(async_client, extensionista_session):
    token, _ = extensionista_session
    response = await async_client.put(
        "/config/app",
        json={"features": {"missions": False}},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 403


@pytest.mark.asyncio
async def test_put_app_config_requires_auth(async_client):
    response = await async_client.put("/config/app", json={})
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_put_app_config_merges_over_defaults(async_client, admin_session):
    token, _ = admin_session
    response = await async_client.put(
        "/config/app",
        json={
            "features": {"monitoring": False},
            "onboarding": {"steps": ["Passo único"]},
        },
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200
    data = response.json()
    assert data["features"]["monitoring"] is False
    assert data["features"]["missions"] is True  # default preserved
    assert data["onboarding"]["steps"] == ["Passo único"]
    assert data["onboarding"]["enabled"] is True  # default preserved

    # And a fresh GET reflects it (file persisted)
    get_resp = await async_client.get("/config/app")
    assert get_resp.json()["features"]["monitoring"] is False


@pytest.mark.asyncio
async def test_put_app_config_rejects_non_object(async_client, admin_session):
    token, _ = admin_session
    response = await async_client.put(
        "/config/app",
        content=b"[1,2,3]",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    assert response.status_code == 422


# ---------------------------------------------------------------------------
# Login rate limiting
# ---------------------------------------------------------------------------


def test_login_rate_limit_blocks_after_cap(temp_db):
    import main

    class _Client:
        host = "203.0.113.10"

    class _Req:
        headers = {}
        client = _Client()

    req = _Req()
    for _ in range(main.LOGIN_RATE_MAX):
        main._enforce_login_rate(req)
    with pytest.raises(Exception) as exc:
        main._enforce_login_rate(req)
    assert getattr(exc.value, "status_code", None) == 429


def test_login_rate_limit_uses_cf_connecting_ip(temp_db):
    import main

    class _Client:
        host = "10.0.0.1"

    class _Req:
        headers = {"cf-connecting-ip": "198.51.100.7"}
        client = _Client()

    assert main._client_ip(_Req()) == "198.51.100.7"
