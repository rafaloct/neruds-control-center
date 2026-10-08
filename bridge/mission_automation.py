from __future__ import annotations

import re
import unicodedata
from datetime import datetime, timedelta, timezone
from typing import Any, Callable

import rss_store
from mission_store import (
    WORKFLOW,
    _deadline_date,
    _deadline_status,
    connect,
    utcnow,
)

EVIDENCE_REQUIRED_FROM = "Evidência registrada"
DONE_STAGES = {"Concluído", "Bloqueado"}
SUGGESTED_PRIORITIES = ("P0", "P1")

CONTENT_TYPE_BUNDLES = {
    "Ação Extensionista": "acao_extensionista",
    "Basic page": "page",
    "Boletim Periódico": "boletim_periodico",
    "Grupo de Estudos": "grupo_estudos",
    "Notícia": "noticia",
    "Perfil do Pesquisador": "perfil_pesquisador",
    "Projeto de Pesquisa/Extensão": "projeto_pesquisa_extensao",
    "Publicação Científica": "publicacao_cientifica",
    "Relatório": "relatorio",
    "Relatório FNO": "relatorio_fno",
    "Agendamento de Reunião": "reuniao",
}

DEFAULT_URL_CHECK_LIMIT = 25
MAX_URL_CHECK_LIMIT = 100


def init_automation_db() -> None:
    with connect() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS task_url_check (
                task_id INTEGER PRIMARY KEY
                    REFERENCES mission_task(id) ON DELETE CASCADE,
                mission_id INTEGER NOT NULL,
                url TEXT NOT NULL,
                ok INTEGER NOT NULL DEFAULT 0,
                http_code INTEGER,
                error TEXT,
                checked_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_url_check_mission
                ON task_url_check(mission_id, ok);
            """
        )


def _norm_text(value: Any) -> str:
    text = unicodedata.normalize("NFKD", str(value or ""))
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    return re.sub(r"\s+", " ", text).strip().lower()


def _norm_url(value: Any) -> str:
    url = str(value or "").strip().lower()
    if not url:
        return ""
    url = re.sub(r"^https?://(www\.)?", "", url)
    return url.rstrip("/")


def _stage_index(stage: Any) -> int:
    try:
        return WORKFLOW.index(str(stage or ""))
    except ValueError:
        return -1


def _task_brief(row: Any) -> dict[str, Any]:
    deadline = _deadline_date(row["internal_deadline"])
    return {
        "id": row["id"],
        "title": row["title"],
        "priority": row["priority"],
        "content_type": row["content_type"],
        "current_stage": row["current_stage"],
        # Effective owner: gap tasks may only carry the free-text
        # responsible when the creator lacked assignment permission.
        "primary_owner": row["primary_owner"] or row["responsible"],
        "internal_deadline": row["internal_deadline"],
        "deadline_status": _deadline_status(deadline, row["current_stage"]),
        "public_url": row["public_url"],
        "spreadsheet_row": row["spreadsheet_row"],
    }


def suggest_next_tasks(
    mission_id: int,
    owner: str | None = None,
    limit: int = 5,
) -> list[dict[str, Any]]:
    init_automation_db()
    with connect() as conn:
        rows = conn.execute(
            """
            SELECT * FROM mission_task
            WHERE mission_id=?
              AND priority IN ('P0','P1')
              AND (current_stage IS NULL
                   OR current_stage NOT IN ('Concluído','Bloqueado'))
            """,
            (mission_id,),
        ).fetchall()

    def score(row: Any) -> tuple:
        deadline = _deadline_status(
            _deadline_date(row["internal_deadline"]),
            row["current_stage"],
        )
        due_rank = {"overdue": 0, "upcoming": 1}.get(deadline, 2)
        stage_rank = _stage_index(row["current_stage"])
        if stage_rank < 0:
            stage_rank = 0
        owner_rank = 1
        if owner and (row["primary_owner"] or "").strip() == owner.strip():
            owner_rank = 0
        return (
            0 if row["priority"] == "P0" else 1,
            due_rank,
            owner_rank,
            stage_rank,
            row["spreadsheet_row"],
        )

    ordered = sorted(rows, key=score)[: max(1, min(limit, 50))]
    suggestions = []
    for row in ordered:
        item = _task_brief(row)
        reasons = [row["priority"] or "Sem prioridade"]
        if item["deadline_status"] == "overdue":
            reasons.append("prazo vencido")
        elif item["deadline_status"] == "upcoming":
            reasons.append("prazo nos próximos 7 dias")
        if owner and (row["primary_owner"] or "").strip() == owner.strip():
            reasons.append("atribuído a você")
        reasons.append(row["current_stage"] or "Triagem")
        item["reason"] = " · ".join(reasons)
        suggestions.append(item)
    return suggestions


def missing_evidence(mission_id: int) -> dict[str, Any]:
    init_automation_db()
    min_index = _stage_index(EVIDENCE_REQUIRED_FROM)
    with connect() as conn:
        rows = conn.execute(
            """
            SELECT t.* FROM mission_task t
            WHERE t.mission_id=?
              AND (t.evidence IS NULL OR TRIM(t.evidence)='')
              AND NOT EXISTS (
                SELECT 1 FROM mission_event e
                WHERE e.task_id=t.id
                  AND e.evidence_url IS NOT NULL
                  AND TRIM(e.evidence_url)<>''
              )
            """,
            (mission_id,),
        ).fetchall()

    items = [
        _task_brief(row)
        for row in rows
        if _stage_index(row["current_stage"]) >= min_index
    ]
    items.sort(key=lambda item: (0 if item["priority"] == "P0" else 1, item["id"]))
    return {"count": len(items), "items": items[:200]}


def possible_duplicates(mission_id: int) -> dict[str, Any]:
    init_automation_db()
    with connect() as conn:
        tasks = conn.execute(
            """
            SELECT * FROM mission_task
            WHERE mission_id=?
              AND (current_stage IS NULL
                   OR current_stage NOT IN ('Concluído','Bloqueado'))
            """,
            (mission_id,),
        ).fetchall()
        has_review = conn.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='draft_review'"
        ).fetchone()
        drafts = (
            conn.execute(
                "SELECT drupal_nid,title,review_status FROM draft_review"
            ).fetchall()
            if has_review
            else []
        )

    by_title: dict[str, list[Any]] = {}
    by_url: dict[str, list[Any]] = {}
    for row in tasks:
        title_key = _norm_text(row["title"])
        url_key = _norm_url(row["public_url"])
        if title_key:
            by_title.setdefault(title_key, []).append(row)
        if url_key:
            by_url.setdefault(url_key, []).append(row)

    internal = []
    for kind, groups in (("title", by_title), ("url", by_url)):
        for key, rows in groups.items():
            if len(rows) < 2:
                continue
            internal.append(
                {
                    "kind": kind,
                    "key": key,
                    "tasks": [_task_brief(row) for row in rows],
                }
            )
    internal.sort(key=lambda group: (group["kind"] != "url", group["key"]))

    draft_matches = []
    draft_index = [
        (draft["drupal_nid"], draft["title"], _norm_text(draft["title"]), draft["review_status"])
        for draft in drafts
    ]
    for row in tasks:
        title_key = _norm_text(row["title"])
        if not title_key:
            continue
        for nid, draft_title, draft_key, review_status in draft_index:
            similar = draft_key == title_key or (
                len(title_key) >= 15
                and len(draft_key) >= 15
                and (title_key.startswith(draft_key) or draft_key.startswith(title_key))
            )
            if similar:
                draft_matches.append(
                    {
                        "task": _task_brief(row),
                        "drupal_nid": nid,
                        "draft_title": draft_title,
                        "review_status": review_status,
                    }
                )
                break
    return {
        "count": len(internal) + len(draft_matches),
        "internal": internal[:100],
        "drupal_matches": draft_matches[:100],
    }


def _default_fetch(url: str) -> tuple[int | None, str | None]:
    try:
        response = rss_store._safe_fetch(url)
    except Exception as exc:
        return None, str(exc)[:300]
    return response.status_code, None


def check_public_urls(
    mission_id: int,
    *,
    limit: int = DEFAULT_URL_CHECK_LIMIT,
    fetch: Callable[[str], tuple[int | None, str | None]] | None = None,
) -> dict[str, Any]:
    init_automation_db()
    fetcher = fetch or _default_fetch
    bounded = max(1, min(limit, MAX_URL_CHECK_LIMIT))
    with connect() as conn:
        mission = conn.execute(
            "SELECT id FROM mission WHERE id=?", (mission_id,)
        ).fetchone()
        if not mission:
            raise KeyError("mission_not_found")
        candidates = conn.execute(
            """
            SELECT t.id, t.title, t.public_url, c.checked_at
            FROM mission_task t
            LEFT JOIN task_url_check c ON c.task_id=t.id
            WHERE t.mission_id=?
              AND t.public_url IS NOT NULL
              AND TRIM(t.public_url)<>''
            ORDER BY c.checked_at IS NULL DESC, c.checked_at ASC, t.id ASC
            LIMIT ?
            """,
            (mission_id, bounded),
        ).fetchall()

        now = utcnow()
        results = []
        for row in candidates:
            url = str(row["public_url"]).strip()
            code, error = fetcher(url)
            ok = code is not None and 200 <= code < 400
            conn.execute(
                """
                INSERT INTO task_url_check
                  (task_id,mission_id,url,ok,http_code,error,checked_at)
                VALUES (?,?,?,?,?,?,?)
                ON CONFLICT(task_id) DO UPDATE SET
                  url=excluded.url,
                  ok=excluded.ok,
                  http_code=excluded.http_code,
                  error=excluded.error,
                  checked_at=excluded.checked_at
                """,
                (row["id"], mission_id, url, 1 if ok else 0, code, error, now),
            )
            results.append(
                {
                    "task_id": row["id"],
                    "title": row["title"],
                    "url": url,
                    "ok": ok,
                    "http_code": code,
                    "error": error,
                    "checked_at": now,
                }
            )
        conn.commit()

    broken = [item for item in results if not item["ok"]]
    return {
        "checked": len(results),
        "broken": len(broken),
        "results": results,
    }


def url_check_summary(mission_id: int) -> dict[str, Any]:
    init_automation_db()
    with connect() as conn:
        rows = conn.execute(
            """
            SELECT c.*, t.title, t.priority, t.current_stage
            FROM task_url_check c
            JOIN mission_task t ON t.id=c.task_id
            WHERE c.mission_id=?
            ORDER BY c.checked_at DESC
            """,
            (mission_id,),
        ).fetchall()
        pending = conn.execute(
            """
            SELECT COUNT(*) FROM mission_task t
            LEFT JOIN task_url_check c ON c.task_id=t.id
            WHERE t.mission_id=?
              AND t.public_url IS NOT NULL
              AND TRIM(t.public_url)<>''
              AND c.task_id IS NULL
            """,
            (mission_id,),
        ).fetchone()[0]

    items = [
        {
            "task_id": row["task_id"],
            "title": row["title"],
            "url": row["url"],
            "ok": bool(row["ok"]),
            "http_code": row["http_code"],
            "error": row["error"],
            "checked_at": row["checked_at"],
        }
        for row in rows
    ]
    broken = [item for item in items if not item["ok"]]
    last_run = items[0]["checked_at"] if items else None
    return {
        "checked": len(items),
        "pending": int(pending),
        "broken": len(broken),
        "last_run": last_run,
        "issues": broken[:200],
    }


def summary(mission_id: int) -> dict[str, Any]:
    init_automation_db()
    with connect() as conn:
        mission = conn.execute(
            "SELECT id FROM mission WHERE id=?", (mission_id,)
        ).fetchone()
    if not mission:
        raise KeyError("mission_not_found")
    return {
        "suggested_tasks": suggest_next_tasks(mission_id),
        "missing_evidence": missing_evidence(mission_id),
        "possible_duplicates": possible_duplicates(mission_id),
        "url_check": url_check_summary(mission_id),
    }


init_automation_db()
