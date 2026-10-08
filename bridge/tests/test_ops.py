"""Testes de operação: readiness, backup/restore e probes de status."""

import json
import sqlite3

import httpx
import pytest
import respx

import main
import mission_store


def auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


# ---------------------------------------------------------------------------
# Readiness
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_ready_ok(async_client):
    response = await async_client.get("/ready")
    assert response.status_code == 200
    assert response.json()["ready"] is True


@pytest.mark.asyncio
async def test_ready_fails_when_db_unavailable(async_client, monkeypatch):
    def _boom():
        raise sqlite3.OperationalError("unable to open database file")

    monkeypatch.setattr(mission_store, "connect", _boom)
    response = await async_client.get("/ready")
    assert response.status_code == 503


# ---------------------------------------------------------------------------
# Backup / restore ensaiado
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_ops_backup_requires_admin(async_client, extensionista_session):
    token, _ = extensionista_session
    response = await async_client.post("/ops/backup", headers=auth(token))
    assert response.status_code == 403
    response = await async_client.get("/ops/backups", headers=auth(token))
    assert response.status_code == 403
    response = await async_client.get("/ops/status", headers=auth(token))
    assert response.status_code == 403


@pytest.mark.asyncio
async def test_ops_backup_creates_listable_file(async_client, admin_session, seeded_mission):
    token, _ = admin_session
    response = await async_client.post("/ops/backup", headers=auth(token))
    assert response.status_code == 200
    body = response.json()
    assert body["ok"] is True
    assert body["size_bytes"] > 0

    listing = await async_client.get("/ops/backups", headers=auth(token))
    files = [b["file"] for b in listing.json()["backups"]]
    assert body["file"] in files


@pytest.mark.asyncio
async def test_backup_is_restorable(admin_session, seeded_mission):
    """Ensaio de restore: o arquivo de backup abre, passa integrity_check
    e contém as mesmas tarefas da base viva."""
    dest = mission_store.backup_db()

    restored = sqlite3.connect(dest)
    restored.row_factory = sqlite3.Row
    try:
        assert restored.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        restored_tasks = restored.execute(
            "SELECT COUNT(*) FROM mission_task"
        ).fetchone()[0]
    finally:
        restored.close()

    live = mission_store.connect()
    try:
        live_tasks = live.execute("SELECT COUNT(*) FROM mission_task").fetchone()[0]
    finally:
        live.close()

    assert restored_tasks == live_tasks
    assert restored_tasks > 0


@pytest.mark.asyncio
async def test_backup_retention_prunes_old(admin_session):
    keep = 2
    stamps = []
    for _ in range(4):
        dest = mission_store.backup_db(keep=keep)
        stamps.append(dest.name)

    remaining = [b["file"] for b in mission_store.list_backups()]
    assert len(remaining) == keep
    # os mais recentes sobrevivem
    assert stamps[-1] in remaining
    assert stamps[-2] in remaining
    assert stamps[0] not in remaining


# ---------------------------------------------------------------------------
# /ops/status — probes
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@respx.mock
async def test_ops_status_probes(async_client, admin_session, monkeypatch):
    token, _ = admin_session
    monkeypatch.setattr(main, "SELF_HEALTH_URL", "https://bridge.ts.net:8443/health")
    monkeypatch.setattr(main, "SMTP_CONNECT_HOST", "127.0.0.1")
    monkeypatch.setattr(main, "SMTP_PORT", 1)  # porta fechada → probe falha rápido

    respx.get("https://neruds.org/user/login").mock(return_value=httpx.Response(200))
    respx.get("https://bridge.ts.net:8443/health").mock(
        return_value=httpx.Response(200, json={"ok": True})
    )

    response = await async_client.get("/ops/status", headers=auth(token))
    assert response.status_code == 200
    body = response.json()

    probes = {p["name"]: p for p in body["probes"]}
    assert probes["drupal_portal"]["ok"] is True
    assert probes["tailscale_serve"]["ok"] is True
    assert probes["posteio_smtp"]["ok"] is False  # 127.0.0.1:1 recusa
    assert probes["mission_db"]["ok"] is True
    assert body["uptime_seconds"] >= 0
    assert "backup" in body


@pytest.mark.asyncio
@respx.mock
async def test_ops_status_self_probe_skipped_without_env(
    async_client, admin_session, monkeypatch
):
    token, _ = admin_session
    monkeypatch.setattr(main, "SELF_HEALTH_URL", "")
    monkeypatch.setattr(main, "SMTP_CONNECT_HOST", "127.0.0.1")
    monkeypatch.setattr(main, "SMTP_PORT", 1)
    respx.get("https://neruds.org/user/login").mock(return_value=httpx.Response(200))

    response = await async_client.get("/ops/status", headers=auth(token))
    probes = {p["name"]: p for p in response.json()["probes"]}
    assert probes["tailscale_serve"]["status"] == "skipped"


@pytest.mark.asyncio
@respx.mock
async def test_ops_status_portal_down(async_client, admin_session, monkeypatch):
    token, _ = admin_session
    monkeypatch.setattr(main, "SMTP_CONNECT_HOST", "127.0.0.1")
    monkeypatch.setattr(main, "SMTP_PORT", 1)
    respx.get("https://neruds.org/user/login").mock(return_value=httpx.Response(503))

    response = await async_client.get("/ops/status", headers=auth(token))
    probes = {p["name"]: p for p in response.json()["probes"]}
    assert probes["drupal_portal"]["ok"] is False
    assert probes["drupal_portal"]["http_status"] == 503


# ---------------------------------------------------------------------------
# Access log estruturado
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_access_log_writes_json_without_secrets(
    async_client, extensionista_session
):
    token, _ = extensionista_session
    await async_client.get("/health?token=should-not-appear", headers=auth(token))

    log_file = mission_store.DATA_DIR / "logs" / "access.log"
    assert log_file.exists()
    content = log_file.read_text(encoding="utf-8")
    lines = [
        json.loads(line) for line in content.splitlines() if line.strip()
    ]
    entries = [l for l in lines if l.get("event") == "http_request"]
    assert entries, "nenhuma linha http_request registrada"
    last = entries[-1]
    assert last["path"] == "/health"
    assert last["method"] == "GET"
    assert "should-not-appear" not in content
    assert token not in content
