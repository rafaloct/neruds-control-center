import os
import sys
from pathlib import Path

import pytest
import respx
from httpx import ASGITransport, AsyncClient

# Ensure bridge directory is on sys.path
BRIDGE_DIR = Path(__file__).resolve().parent.parent
if str(BRIDGE_DIR) not in sys.path:
    sys.path.insert(0, str(BRIDGE_DIR))

import identity_store
import main
import mission_store
import review_store
import rss_store


@pytest.fixture(autouse=True)
def temp_db(tmp_path, monkeypatch):
    """Isolate SQLite database for each test run."""
    db_file = tmp_path / "test_missions.sqlite3"
    monkeypatch.setattr(mission_store, "DB_PATH", db_file)
    monkeypatch.setattr(mission_store, "DATA_DIR", tmp_path)
    monkeypatch.setattr(identity_store, "DB_PATH", tmp_path / "test_identity.sqlite3")
    monkeypatch.setattr(identity_store, "DATA_DIR", tmp_path)

    # Initialize all database schemas
    mission_store.init_db()
    rss_store.init_rss_db()
    review_store.init_review_db()
    identity_store.init_db()

    # Clear main.py in-memory sessions and portal read cache
    main.SESSIONS.clear()
    main._PORTAL_READ_CACHE.clear()

    yield db_file


@pytest.fixture
def seeded_mission(temp_db):
    """Seed the mission database from mission_seed.json."""
    return mission_store.seed_from_json(force=True)


@pytest.fixture
def extensionista_session():
    """Create a mock Extensionista session (cannot review, cannot publish)."""
    token = "test-token-extensionista"
    session = {
        "username": "extensionista.test",
        "uid": "101",
        "roles": ["authenticated", "extensionista"],
        "can_review": False,
        "can_publish": False,
        "cookies": {"SSESS123": "fake-cookie-extensionista"},
        "csrf": "fake-csrf-token-ext",
        "created_at": main.utcnow() if hasattr(main, "utcnow") else mission_store.utcnow(),
        "last_seen": mission_store.utcnow(),
    }
    main.SESSIONS[token] = session
    return token, session


@pytest.fixture
def revisor_session():
    """Create a mock Revisor session (can review, cannot publish)."""
    token = "test-token-revisor"
    session = {
        "username": "revisor.test",
        "uid": "102",
        "roles": ["authenticated", "revisor"],
        "can_review": True,
        "can_publish": False,
        "cookies": {"SSESS123": "fake-cookie-revisor"},
        "csrf": "fake-csrf-token-rev",
        "created_at": mission_store.utcnow(),
        "last_seen": mission_store.utcnow(),
    }
    main.SESSIONS[token] = session
    return token, session


@pytest.fixture
def publicador_session():
    """Create a mock Publicador/Coordenador session (can review and publish)."""
    token = "test-token-publicador"
    session = {
        "username": "coordenador.test",
        "uid": "103",
        "roles": ["authenticated", "coordenador"],
        "can_review": True,
        "can_publish": True,
        "cookies": {"SSESS123": "fake-cookie-publicador"},
        "csrf": "fake-csrf-token-pub",
        "created_at": mission_store.utcnow(),
        "last_seen": mission_store.utcnow(),
    }
    main.SESSIONS[token] = session
    return token, session


@pytest.fixture
def admin_session():
    """Coordinator session with extensionista account administration rights."""
    token = "test-token-admin"
    session = {
        "username": "coordenador.test",
        "uid": "1",
        "roles": ["authenticated", "coordenador"],
        "can_review": True,
        "can_publish": True,
        "can_admin_users": True,
        "cookies": {"SSESS123": "fake-cookie-admin"},
        "csrf": "fake-csrf-token-admin",
        "created_at": mission_store.utcnow(),
        "last_seen": mission_store.utcnow(),
    }
    main.SESSIONS[token] = session
    return token, session


@pytest.fixture
async def async_client():
    """FastAPI AsyncClient using ASGITransport."""
    transport = ASGITransport(app=main.app)
    async with AsyncClient(transport=transport, base_url="http://testserver") as client:
        yield client
