"""Persistent bridge sessions backed by SQLite.

Replaces the previous in-memory ``SESSIONS`` dict so tokens survive bridge
restarts and the same Drupal identity can sign in from web, desktop and
mobile clients.

Passwords are never stored — only the Drupal session cookies and CSRF token
needed to proxy editorial calls, and they are encrypted at rest with Fernet
using ``NERUDS_SESSION_KEY`` (a urlsafe-base64 32-byte key). When the env var
is absent an ephemeral per-process key is generated, which preserves the old
behavior: sessions work but disappear on restart.
"""

from __future__ import annotations

import json
import logging
import os
import secrets
import sqlite3
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterator

from cryptography.fernet import Fernet, InvalidToken

BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR.parent / "data"
DB_PATH = DATA_DIR / "sessions.sqlite3"

_LOG = logging.getLogger("neruds_bridge.sessions")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS bridge_session (
    token TEXT PRIMARY KEY,
    username TEXT NOT NULL,
    uid TEXT,
    roles_json TEXT NOT NULL DEFAULT '[]',
    can_review INTEGER NOT NULL DEFAULT 0,
    can_publish INTEGER NOT NULL DEFAULT 0,
    can_admin_users INTEGER NOT NULL DEFAULT 0,
    secrets_enc TEXT NOT NULL,
    created_at TEXT NOT NULL,
    last_seen TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_bridge_session_last_seen
    ON bridge_session(last_seen);
"""


def utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()


# ---------------------------------------------------------------------------
# Encryption at rest
# ---------------------------------------------------------------------------

_FERNET: Fernet | None = None
_FERNET_LOCK = threading.Lock()


def _fernet() -> Fernet:
    global _FERNET
    with _FERNET_LOCK:
        if _FERNET is None:
            key = os.getenv("NERUDS_SESSION_KEY", "").strip()
            if not key:
                key = Fernet.generate_key().decode()
                _LOG.warning(
                    "NERUDS_SESSION_KEY ausente: sessões criptografadas com chave "
                    "efêmera e serão invalidadas no restart."
                )
            try:
                _FERNET = Fernet(key.encode() if isinstance(key, str) else key)
            except (ValueError, TypeError) as exc:
                raise RuntimeError(
                    "NERUDS_SESSION_KEY inválida. Gere com: "
                    "python -c \"from cryptography.fernet import Fernet; "
                    "print(Fernet.generate_key().decode())\""
                ) from exc
        return _FERNET


def reset_crypto_for_tests() -> None:
    global _FERNET
    _FERNET = None


def _encrypt(payload: dict[str, Any]) -> str:
    return _fernet().encrypt(json.dumps(payload).encode()).decode()


def _decrypt(blob: str) -> dict[str, Any] | None:
    try:
        return json.loads(_fernet().decrypt(blob.encode()).decode())
    except (InvalidToken, ValueError):
        return None


# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------


def _connect() -> sqlite3.Connection:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    with _connect() as conn:
        conn.executescript(_SCHEMA)


init_db()


def _row_to_session(row: sqlite3.Row) -> dict[str, Any] | None:
    payload = _decrypt(row["secrets_enc"])
    if payload is None:
        return None
    try:
        roles = json.loads(row["roles_json"])
    except (TypeError, ValueError):
        roles = []
    return {
        "token": row["token"],
        "username": row["username"],
        "uid": row["uid"],
        "roles": roles,
        "can_review": bool(row["can_review"]),
        "can_publish": bool(row["can_publish"]),
        "can_admin_users": bool(row["can_admin_users"]),
        "cookies": payload.get("cookies", {}),
        "csrf": payload.get("csrf", ""),
        "created_at": row["created_at"],
        "last_seen": row["last_seen"],
    }


def save(token: str, session: dict[str, Any]) -> None:
    """Insert or replace a session row."""
    blob = _encrypt(
        {
            "cookies": session.get("cookies", {}),
            "csrf": session.get("csrf", ""),
        }
    )
    with _connect() as conn:
        conn.execute(
            """
            INSERT INTO bridge_session (
                token, username, uid, roles_json, can_review, can_publish,
                can_admin_users, secrets_enc, created_at, last_seen
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(token) DO UPDATE SET
                username = excluded.username,
                uid = excluded.uid,
                roles_json = excluded.roles_json,
                can_review = excluded.can_review,
                can_publish = excluded.can_publish,
                can_admin_users = excluded.can_admin_users,
                secrets_enc = excluded.secrets_enc,
                created_at = excluded.created_at,
                last_seen = excluded.last_seen
            """,
            (
                token,
                session.get("username", ""),
                None if session.get("uid") is None else str(session["uid"]),
                json.dumps(session.get("roles", [])),
                int(bool(session.get("can_review"))),
                int(bool(session.get("can_publish"))),
                int(bool(session.get("can_admin_users"))),
                blob,
                session.get("created_at", utcnow()),
                session.get("last_seen", utcnow()),
            ),
        )


def get(token: str) -> dict[str, Any] | None:
    with _connect() as conn:
        row = conn.execute(
            "SELECT * FROM bridge_session WHERE token = ?", (token,)
        ).fetchone()
    if row is None:
        return None
    session = _row_to_session(row)
    if session is None:
        delete(token)
    return session


def touch(token: str, last_seen: str | None = None) -> None:
    with _connect() as conn:
        conn.execute(
            "UPDATE bridge_session SET last_seen = ? WHERE token = ?",
            (last_seen or utcnow(), token),
        )


def delete(token: str) -> None:
    with _connect() as conn:
        conn.execute("DELETE FROM bridge_session WHERE token = ?", (token,))


def clear() -> None:
    with _connect() as conn:
        conn.execute("DELETE FROM bridge_session")


def count() -> int:
    with _connect() as conn:
        return int(
            conn.execute("SELECT COUNT(*) FROM bridge_session").fetchone()[0]
        )


def purge_idle(idle_ttl: timedelta) -> int:
    """Delete sessions whose last_seen is older than *idle_ttl*. Returns count."""
    cutoff = (datetime.now(timezone.utc) - idle_ttl).isoformat()
    with _connect() as conn:
        cur = conn.execute(
            "DELETE FROM bridge_session WHERE last_seen < ?", (cutoff,)
        )
        return cur.rowcount


# ---------------------------------------------------------------------------
# Dict-like facade kept for main.py/tests compatibility
# ---------------------------------------------------------------------------


class SessionStore:
    """Minimal mutable-mapping surface over the SQLite store."""

    def __setitem__(self, token: str, session: dict[str, Any]) -> None:
        save(token, session)

    def __getitem__(self, token: str) -> dict[str, Any]:
        session = get(token)
        if session is None:
            raise KeyError(token)
        return session

    def __delitem__(self, token: str) -> None:
        delete(token)

    def __contains__(self, token: object) -> bool:
        return isinstance(token, str) and get(token) is not None

    def __len__(self) -> int:
        return count()

    def __iter__(self) -> Iterator[str]:
        with _connect() as conn:
            rows = conn.execute("SELECT token FROM bridge_session").fetchall()
        return iter([r["token"] for r in rows])

    def get(self, token: str, default: Any = None) -> Any:
        session = get(token)
        return session if session is not None else default

    def pop(self, token: str, default: Any = None) -> Any:
        session = get(token)
        delete(token)
        return session if session is not None else default

    def clear(self) -> None:
        clear()

    def touch(self, token: str, last_seen: str | None = None) -> None:
        touch(token, last_seen)

    def new_token(self) -> str:
        return secrets.token_urlsafe(32)


SESSIONS = SessionStore()
