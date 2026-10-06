from __future__ import annotations

from typing import Any

from mission_store import connect, utcnow

REVIEW_STATUSES = {
    "pending",
    "changes_requested",
    "approved",
    "published",
}


def init_review_db() -> None:
    with connect() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS draft_review (
                drupal_nid TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                author TEXT NOT NULL,
                owner_uid TEXT,
                review_status TEXT NOT NULL DEFAULT 'pending',
                reviewer TEXT,
                review_note TEXT,
                opportunity_item_id INTEGER,
                mission_task_id INTEGER,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                published_at TEXT
            );

            CREATE TABLE IF NOT EXISTS draft_review_event (
                id INTEGER PRIMARY KEY,
                drupal_nid TEXT NOT NULL,
                actor TEXT NOT NULL,
                event_type TEXT NOT NULL,
                note TEXT,
                created_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_draft_review_status
                ON draft_review(review_status);
            CREATE INDEX IF NOT EXISTS idx_draft_review_event_nid
                ON draft_review_event(drupal_nid, id);
            """
        )
        columns = {
            row["name"]
            for row in conn.execute("PRAGMA table_info(draft_review)").fetchall()
        }
        if "owner_uid" not in columns:
            conn.execute("ALTER TABLE draft_review ADD COLUMN owner_uid TEXT")
        if "opportunity_item_id" not in columns:
            conn.execute("ALTER TABLE draft_review ADD COLUMN opportunity_item_id INTEGER")
        if "mission_task_id" not in columns:
            conn.execute("ALTER TABLE draft_review ADD COLUMN mission_task_id INTEGER")
        conn.commit()


def register_draft(
    drupal_nid: str,
    title: str,
    author: str,
    *,
    owner_uid: str | None = None,
    opportunity_item_id: int | None = None,
    mission_task_id: int | None = None,
) -> dict[str, Any]:
    init_review_db()
    nid = str(drupal_nid or "").strip()
    if not nid:
        raise ValueError("drupal_nid is required")
    now = utcnow()
    with connect() as conn:
        conn.execute(
            """
            INSERT INTO draft_review
              (drupal_nid,title,author,owner_uid,review_status,opportunity_item_id,mission_task_id,created_at,updated_at)
            VALUES (?,?,?,?,'pending',?,?,?,?)
            ON CONFLICT(drupal_nid) DO UPDATE SET
              title=excluded.title,
              author=CASE
                WHEN draft_review.author='' THEN excluded.author
                ELSE draft_review.author
              END,
              owner_uid=COALESCE(excluded.owner_uid, draft_review.owner_uid),
              opportunity_item_id=COALESCE(
                excluded.opportunity_item_id,
                draft_review.opportunity_item_id
              ),
              mission_task_id=COALESCE(
                excluded.mission_task_id,
                draft_review.mission_task_id
              ),
              updated_at=excluded.updated_at
            """,
            (nid, title, author, owner_uid, opportunity_item_id, mission_task_id, now, now),
        )
        conn.execute(
            """
            INSERT INTO draft_review_event
              (drupal_nid,actor,event_type,note,created_at)
            VALUES (?,?,?,?,?)
            """,
            (nid, author, "draft_registered", None, now),
        )
        conn.commit()
    return get_review(nid)


def ensure_draft(
    drupal_nid: str,
    title: str,
    author: str = "Drupal",
    opportunity_item_id: int | None = None,
    mission_task_id: int | None = None,
) -> dict[str, Any]:
    init_review_db()
    nid = str(drupal_nid or "").strip()
    if not nid:
        raise ValueError("drupal_nid is required")
    current = get_review(nid)
    if current:
        return current
    return register_draft(
        nid,
        title,
        author,
        opportunity_item_id=opportunity_item_id,
        mission_task_id=mission_task_id,
    )


def reconcile_draft(
    drupal_nid: str,
    title: str,
    *,
    owner_uid: str | None,
    author: str | None = None,
    published: bool,
) -> dict[str, Any]:
    """Reconcile metadata observed through an authorized Drupal response.

    A username is supplied only when Drupal's UID proves that identity.
    Observing a publication does not invent its publication timestamp.
    """
    current = ensure_draft(drupal_nid, title, author or "Drupal")
    observed_owner = owner_uid or current.get("owner_uid")
    observed_author = current["author"]
    if owner_uid and current.get("owner_uid") not in (None, "", owner_uid):
        observed_author = "Drupal"
    if author is not None:
        observed_author = author

    observed_status = current["review_status"]
    if published:
        observed_status = "published"
    elif observed_status == "published":
        observed_status = "pending"

    if (
        current["title"] == title
        and current.get("owner_uid") == observed_owner
        and current["author"] == observed_author
        and current["review_status"] == observed_status
    ):
        return current

    now = utcnow()
    with connect() as conn:
        conn.execute(
            """
            UPDATE draft_review
            SET title=?,owner_uid=?,author=?,review_status=?,updated_at=?
            WHERE drupal_nid=?
            """,
            (title, observed_owner, observed_author, observed_status, now, str(drupal_nid)),
        )
        conn.execute(
            """
            INSERT INTO draft_review_event
              (drupal_nid,actor,event_type,note,created_at)
            VALUES (?,?,?,?,?)
            """,
            (
                str(drupal_nid),
                "Drupal",
                "drupal_sync",
                "Estado e autoria conferidos na leitura autorizada do portal.",
                now,
            ),
        )
        conn.commit()
    return get_review(str(drupal_nid)) or {}


def get_review(drupal_nid: str) -> dict[str, Any] | None:
    init_review_db()
    with connect() as conn:
        row = conn.execute(
            "SELECT * FROM draft_review WHERE drupal_nid=?",
            (str(drupal_nid),),
        ).fetchone()
        if not row:
            return None
        data = dict(row)
        events = conn.execute(
            """
            SELECT id,actor,event_type,note,created_at
            FROM draft_review_event
            WHERE drupal_nid=?
            ORDER BY id DESC
            LIMIT 100
            """,
            (str(drupal_nid),),
        ).fetchall()
        data["events"] = [dict(item) for item in events]
        return data


def decide(
    drupal_nid: str,
    *,
    actor: str,
    status: str,
    note: str | None,
    title: str | None = None,
) -> dict[str, Any]:
    init_review_db()
    if status not in {"approved", "changes_requested", "pending"}:
        raise ValueError("invalid review status")
    nid = str(drupal_nid)
    current = get_review(nid)
    if not current:
        if not title:
            raise KeyError(nid)
        current = register_draft(nid, title, "Drupal")
    if current["review_status"] == "published":
        raise ValueError("published drafts cannot be reviewed again")

    now = utcnow()
    with connect() as conn:
        conn.execute(
            """
            UPDATE draft_review
            SET review_status=?, reviewer=?, review_note=?, updated_at=?
            WHERE drupal_nid=?
            """,
            (status, actor, note, now, nid),
        )
        conn.execute(
            """
            INSERT INTO draft_review_event
              (drupal_nid,actor,event_type,note,created_at)
            VALUES (?,?,?,?,?)
            """,
            (nid, actor, status, note, now),
        )
        conn.commit()
    return get_review(nid) or {}


def mark_published(drupal_nid: str, actor: str) -> dict[str, Any]:
    init_review_db()
    nid = str(drupal_nid)
    now = utcnow()
    with connect() as conn:
        row = conn.execute(
            "SELECT 1 FROM draft_review WHERE drupal_nid=?",
            (nid,),
        ).fetchone()
        if not row:
            raise KeyError(nid)
        conn.execute(
            """
            UPDATE draft_review
            SET review_status='published', reviewer=?, updated_at=?, published_at=?
            WHERE drupal_nid=?
            """,
            (actor, now, now, nid),
        )
        conn.execute(
            """
            INSERT INTO draft_review_event
              (drupal_nid,actor,event_type,note,created_at)
            VALUES (?,?,?,?,?)
            """,
            (nid, actor, "published", None, now),
        )
        conn.commit()
    return get_review(nid) or {}


init_review_db()
