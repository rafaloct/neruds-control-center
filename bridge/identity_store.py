from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR.parent / "data"
DB_PATH = DATA_DIR / "identity.sqlite3"

OFFBOARDING_STEPS = [
    "tasks_reassigned",
    "account_blocked",
    "drafts_reviewed",
    "mailbox_disabled",
    "handover_documented",
]

STEP_LABELS = {
    "tasks_reassigned": "Tarefas abertas transferidas para outro responsável",
    "account_blocked": "Conta Drupal bloqueada",
    "drafts_reviewed": "Rascunhos pendentes revisados ou reatribuídos",
    "mailbox_disabled": "Caixa de e-mail institucional desativada (Poste.io)",
    "handover_documented": "Passagem de bastão documentada (observações/entrega)",
}


def utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()


_SCHEMA = """
CREATE TABLE IF NOT EXISTS identity_account (
    id INTEGER PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    drupal_uid INTEGER,
    mail TEXT,
    active INTEGER NOT NULL DEFAULT 1,
    provisioned_by TEXT,
    provisioned_at TEXT,
    offboarded_by TEXT,
    offboarded_at TEXT,
    notes TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS identity_event (
    id INTEGER PRIMARY KEY,
    account_id INTEGER REFERENCES identity_account(id) ON DELETE SET NULL,
    username TEXT,
    actor TEXT NOT NULL,
    kind TEXT NOT NULL,
    detail_json TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_identity_event_account
    ON identity_event(account_id);
CREATE INDEX IF NOT EXISTS idx_identity_event_created
    ON identity_event(created_at);

CREATE TABLE IF NOT EXISTS identity_check (
    id INTEGER PRIMARY KEY,
    account_id INTEGER NOT NULL REFERENCES identity_account(id) ON DELETE CASCADE,
    step TEXT NOT NULL,
    done INTEGER NOT NULL DEFAULT 0,
    done_by TEXT,
    done_at TEXT,
    UNIQUE(account_id, step)
);
"""


def connect() -> sqlite3.Connection:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    conn.executescript(_SCHEMA)
    return conn


def init_db() -> None:
    with connect():
        pass


def _account_row(row: sqlite3.Row) -> dict[str, Any]:
    item = dict(row)
    item["active"] = bool(item.get("active"))
    return item


def _event_row(row: sqlite3.Row) -> dict[str, Any]:
    item = dict(row)
    detail = item.pop("detail_json", None)
    item["detail"] = json.loads(detail) if detail else {}
    return item


def upsert_account(
    username: str,
    *,
    drupal_uid: int | None = None,
    mail: str | None = None,
    active: bool | None = None,
    provisioned_by: str | None = None,
    notes: str | None = None,
) -> dict[str, Any]:
    now = utcnow()
    with connect() as conn:
        existing = conn.execute(
            "SELECT * FROM identity_account WHERE username = ?", (username,)
        ).fetchone()
        if existing:
            conn.execute(
                """
                UPDATE identity_account
                SET drupal_uid = COALESCE(?, drupal_uid),
                    mail = COALESCE(?, mail),
                    active = COALESCE(?, active),
                    notes = COALESCE(?, notes),
                    updated_at = ?
                WHERE username = ?
                """,
                (drupal_uid, mail, None if active is None else int(active), notes, now, username),
            )
            row = conn.execute(
                "SELECT * FROM identity_account WHERE username = ?", (username,)
            ).fetchone()
            return _account_row(row)

        conn.execute(
            """
            INSERT INTO identity_account (
                username, drupal_uid, mail, active,
                provisioned_by, provisioned_at, notes,
                created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                username,
                drupal_uid,
                mail,
                1 if active is None else int(active),
                provisioned_by,
                now if provisioned_by else None,
                notes,
                now,
                now,
            ),
        )
        account_id = conn.execute("SELECT last_insert_rowid()").fetchone()[0]
        for step in OFFBOARDING_STEPS:
            conn.execute(
                "INSERT OR IGNORE INTO identity_check (account_id, step) VALUES (?, ?)",
                (account_id, step),
            )
        row = conn.execute(
            "SELECT * FROM identity_account WHERE id = ?", (account_id,)
        ).fetchone()
        return _account_row(row)


def get_account(username: str) -> dict[str, Any]:
    with connect() as conn:
        row = conn.execute(
            "SELECT * FROM identity_account WHERE username = ?", (username,)
        ).fetchone()
        if not row:
            raise KeyError(username)
        return _account_row(row)


def get_account_by_uid(uid: int) -> dict[str, Any] | None:
    with connect() as conn:
        row = conn.execute(
            "SELECT * FROM identity_account WHERE drupal_uid = ?", (uid,)
        ).fetchone()
        return _account_row(row) if row else None


def list_accounts() -> list[dict[str, Any]]:
    with connect() as conn:
        rows = conn.execute(
            "SELECT * FROM identity_account ORDER BY username"
        ).fetchall()
        return [_account_row(row) for row in rows]


def mark_offboarded(username: str, *, actor: str) -> dict[str, Any]:
    now = utcnow()
    with connect() as conn:
        row = conn.execute(
            "SELECT * FROM identity_account WHERE username = ?", (username,)
        ).fetchone()
        if not row:
            raise KeyError(username)
        conn.execute(
            """
            UPDATE identity_account
            SET active = 0, offboarded_by = ?, offboarded_at = ?, updated_at = ?
            WHERE username = ?
            """,
            (actor, now, now, username),
        )
        row = conn.execute(
            "SELECT * FROM identity_account WHERE username = ?", (username,)
        ).fetchone()
        return _account_row(row)


def record_event(
    actor: str,
    kind: str,
    *,
    account_id: int | None = None,
    username: str | None = None,
    detail: dict[str, Any] | None = None,
) -> dict[str, Any]:
    with connect() as conn:
        conn.execute(
            """
            INSERT INTO identity_event (account_id, username, actor, kind, detail_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                account_id,
                username,
                actor,
                kind,
                json.dumps(detail or {}, ensure_ascii=False),
                utcnow(),
            ),
        )
        event_id = conn.execute("SELECT last_insert_rowid()").fetchone()[0]
        row = conn.execute(
            "SELECT * FROM identity_event WHERE id = ?", (event_id,)
        ).fetchone()
        return _event_row(row)


def list_events(
    *, account_id: int | None = None, username: str | None = None, limit: int = 100
) -> list[dict[str, Any]]:
    clauses: list[str] = []
    params: list[Any] = []
    if account_id is not None:
        clauses.append("account_id = ?")
        params.append(account_id)
    if username is not None:
        clauses.append("username = ?")
        params.append(username)
    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    params.append(max(1, min(int(limit), 500)))
    with connect() as conn:
        rows = conn.execute(
            f"SELECT * FROM identity_event {where} ORDER BY id DESC LIMIT ?",
            params,
        ).fetchall()
        return [_event_row(row) for row in rows]


def checklist(account_id: int) -> list[dict[str, Any]]:
    with connect() as conn:
        rows = conn.execute(
            "SELECT * FROM identity_check WHERE account_id = ? ORDER BY id",
            (account_id,),
        ).fetchall()
        items = []
        for row in rows:
            item = dict(row)
            item["done"] = bool(item["done"])
            item["label"] = STEP_LABELS.get(item["step"], item["step"])
            items.append(item)
        return items


def set_check(account_id: int, step: str, done: bool, actor: str) -> dict[str, Any]:
    if step not in STEP_LABELS:
        raise KeyError(step)
    now = utcnow()
    with connect() as conn:
        conn.execute(
            "INSERT OR IGNORE INTO identity_check (account_id, step) VALUES (?, ?)",
            (account_id, step),
        )
        conn.execute(
            """
            UPDATE identity_check
            SET done = ?, done_by = ?, done_at = ?
            WHERE account_id = ? AND step = ?
            """,
            (int(done), actor if done else None, now if done else None, account_id, step),
        )
        row = conn.execute(
            "SELECT * FROM identity_check WHERE account_id = ? AND step = ?",
            (account_id, step),
        ).fetchone()
        item = dict(row)
        item["done"] = bool(item["done"])
        item["label"] = STEP_LABELS[step]
        return item


def offboarding_progress(account_id: int) -> dict[str, Any]:
    items = checklist(account_id)
    done = sum(1 for item in items if item["done"])
    return {
        "items": items,
        "done": done,
        "total": len(items),
        "complete": bool(items) and done == len(items),
    }
