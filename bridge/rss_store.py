from __future__ import annotations

import html
import ipaddress
import json
import re
import socket
import sqlite3
from datetime import datetime, timezone
from typing import Any
from urllib.parse import urljoin, urlparse

import feedparser
import httpx

from mission_store import connect, utcnow

CATEGORIES = [
    "Edital",
    "Chamada para revista",
    "Oportunidade de extensão",
    "Grupo/rede de pesquisa",
    "Bolsa",
    "Evento científico",
    "Notícia institucional",
    "Outro",
]

STATUSES = [
    "novo",
    "em_triagem",
    "verificado",
    "aprovado_pauta",
    "descartado",
    "rascunho_criado",
    "arquivado",
]

KEYWORDS = [
    ("Chamada para revista", ("call for papers", "chamada de artigo", "chamada de artigos", "dossiê", "dossie", "periódico", "periodico", "revista científica", "revista cientifica")),
    ("Oportunidade de extensão", ("extensão", "extensao", "proext", "pibex", "ação extensionista", "acao extensionista")),
    ("Grupo/rede de pesquisa", ("grupo de pesquisa", "rede de pesquisa", "núcleo de pesquisa", "nucleo de pesquisa", "laboratório", "laboratorio")),
    ("Bolsa", ("bolsa", "pibic", "pibiti", "pibex", "estágio", "estagio", "seleção de bolsista", "selecao de bolsista")),
    ("Evento científico", ("congresso", "seminário", "seminario", "simpósio", "simposio", "workshop", "webinar", "encontro científico", "evento científico")),
    ("Edital", ("edital", "chamada pública", "chamada publica", "seleção pública", "selecao publica")),
]


def init_rss_db() -> None:
    with connect() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS feed_source (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                url TEXT NOT NULL UNIQUE,
                feed_url TEXT,
                default_category TEXT,
                active INTEGER NOT NULL DEFAULT 1,
                created_by TEXT NOT NULL,
                created_at TEXT NOT NULL,
                last_checked_at TEXT,
                last_success_at TEXT,
                last_error TEXT
            );

            CREATE TABLE IF NOT EXISTS feed_item (
                id INTEGER PRIMARY KEY,
                source_id INTEGER NOT NULL REFERENCES feed_source(id) ON DELETE CASCADE,
                guid TEXT,
                url TEXT NOT NULL,
                title TEXT NOT NULL,
                summary TEXT,
                author TEXT,
                published_at TEXT,
                category TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'novo',
                source_verified INTEGER NOT NULL DEFAULT 0,
                decision_note TEXT,
                reviewed_by TEXT,
                reviewed_at TEXT,
                drupal_draft_id TEXT,
                raw_json TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                UNIQUE(source_id, guid),
                UNIQUE(source_id, url)
            );

            CREATE TABLE IF NOT EXISTS feed_event (
                id INTEGER PRIMARY KEY,
                item_id INTEGER NOT NULL REFERENCES feed_item(id) ON DELETE CASCADE,
                actor TEXT NOT NULL,
                event_type TEXT NOT NULL,
                note TEXT,
                changes_json TEXT,
                created_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_feed_item_status
                ON feed_item(status, category, published_at);
            CREATE INDEX IF NOT EXISTS idx_feed_source_active
                ON feed_source(active);
            """
        )


def _clean_text(value: Any) -> str:
    if value is None:
        return ""
    text = html.unescape(str(value))
    text = re.sub(r"<script\b[^>]*>.*?</script>", " ", text, flags=re.I | re.S)
    text = re.sub(r"<style\b[^>]*>.*?</style>", " ", text, flags=re.I | re.S)
    text = re.sub(r"<[^>]+>", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def _validate_public_url(url: str) -> str:
    parsed = urlparse(url.strip())
    if parsed.scheme not in {"http", "https"}:
        raise ValueError("A fonte deve usar http ou https.")
    if parsed.username or parsed.password:
        raise ValueError("URL com credenciais não é permitida.")
    if not parsed.hostname:
        raise ValueError("URL sem hostname.")
    if parsed.port not in (None, 80, 443):
        raise ValueError("A fonte RSS deve usar porta web padrão.")

    try:
        infos = socket.getaddrinfo(parsed.hostname, parsed.port or (443 if parsed.scheme == "https" else 80))
    except socket.gaierror as exc:
        raise ValueError("Hostname não pôde ser resolvido.") from exc

    for info in infos:
        address = info[4][0]
        try:
            ip = ipaddress.ip_address(address)
        except ValueError:
            continue
        if not ip.is_global:
            raise ValueError("A fonte deve apontar para um endereço público.")
    return parsed.geturl()


def _safe_fetch(url: str, max_redirects: int = 4) -> httpx.Response:
    current = _validate_public_url(url)
    with httpx.Client(
        timeout=15,
        follow_redirects=False,
        headers={"User-Agent": "NERUDS-Control-Center-RSS/0.3"},
    ) as client:
        for _ in range(max_redirects + 1):
            response = client.get(current)
            if response.status_code in {301, 302, 303, 307, 308}:
                location = response.headers.get("location")
                if not location:
                    return response
                current = _validate_public_url(urljoin(current, location))
                continue
            return response
    raise ValueError("Redirecionamentos demais na fonte.")


def _discover_feed(page_url: str) -> tuple[str, bytes]:
    response = _safe_fetch(page_url)
    response.raise_for_status()
    content_type = response.headers.get("content-type", "").lower()
    body = response.content
    parsed = feedparser.parse(body)

    if parsed.entries and (
        "xml" in content_type
        or "rss" in content_type
        or "atom" in content_type
        or parsed.version
    ):
        return str(response.url), body

    text = response.text
    matches = re.findall(
        r"""<link[^>]+(?:type=["']application/(?:rss|atom)\+xml["'][^>]+href=["']([^"']+)["']|href=["']([^"']+)["'][^>]+type=["']application/(?:rss|atom)\+xml["'])""",
        text,
        flags=re.I,
    )
    for pair in matches:
        href = next((part for part in pair if part), "")
        if not href:
            continue
        candidate = _validate_public_url(urljoin(str(response.url), href))
        feed_response = _safe_fetch(candidate)
        if feed_response.status_code >= 400:
            continue
        feed = feedparser.parse(feed_response.content)
        if feed.entries:
            return str(feed_response.url), feed_response.content

    raise ValueError("Nenhum RSS/Atom foi encontrado nessa URL.")


def classify(title: str, summary: str, default: str | None = None) -> str:
    haystack = f"{title} {summary}".lower()
    for category, keywords in KEYWORDS:
        if any(keyword in haystack for keyword in keywords):
            return category
    if default in CATEGORIES:
        return str(default)
    return "Outro"


def list_sources() -> list[dict[str, Any]]:
    init_rss_db()
    with connect() as conn:
        rows = conn.execute(
            "SELECT * FROM feed_source ORDER BY active DESC, name COLLATE NOCASE"
        ).fetchall()
    return [_source_row(row) for row in rows]


def _source_row(row: sqlite3.Row) -> dict[str, Any]:
    item = dict(row)
    item["active"] = bool(item["active"])
    return item


def add_source(
    name: str,
    url: str,
    actor: str,
    default_category: str | None = None,
) -> dict[str, Any]:
    init_rss_db()
    if default_category and default_category not in CATEGORIES:
        raise ValueError("Categoria inválida.")
    normalized = _validate_public_url(url)
    now = utcnow()
    with connect() as conn:
        try:
            cur = conn.execute(
                """
                INSERT INTO feed_source
                (name,url,default_category,created_by,created_at)
                VALUES (?,?,?,?,?)
                """,
                (name.strip(), normalized, default_category, actor, now),
            )
        except sqlite3.IntegrityError as exc:
            raise ValueError("Essa fonte já foi cadastrada.") from exc
        source_id = int(cur.lastrowid)
        conn.commit()
        row = conn.execute("SELECT * FROM feed_source WHERE id=?", (source_id,)).fetchone()
    return _source_row(row)


def update_source(
    source_id: int,
    *,
    active: bool | None = None,
    default_category: str | None = None,
) -> dict[str, Any]:
    if default_category is not None and default_category not in CATEGORIES:
        raise ValueError("Categoria inválida.")
    with connect() as conn:
        row = conn.execute("SELECT * FROM feed_source WHERE id=?", (source_id,)).fetchone()
        if not row:
            raise KeyError("source_not_found")
        updates = []
        args: list[Any] = []
        if active is not None:
            updates.append("active=?")
            args.append(1 if active else 0)
        if default_category is not None:
            updates.append("default_category=?")
            args.append(default_category)
        if updates:
            args.append(source_id)
            conn.execute(
                f"UPDATE feed_source SET {', '.join(updates)} WHERE id=?",
                args,
            )
            conn.commit()
        row = conn.execute("SELECT * FROM feed_source WHERE id=?", (source_id,)).fetchone()
    return _source_row(row)


def refresh_source(source_id: int) -> dict[str, Any]:
    init_rss_db()
    with connect() as conn:
        source = conn.execute("SELECT * FROM feed_source WHERE id=?", (source_id,)).fetchone()
    if not source:
        raise KeyError("source_not_found")
    if not source["active"]:
        return {"source_id": source_id, "skipped": True, "reason": "inactive"}

    checked_at = utcnow()
    try:
        feed_url, body = _discover_feed(source["feed_url"] or source["url"])
        parsed = feedparser.parse(body)
        inserted = 0
        existing = 0
        with connect() as conn:
            conn.execute(
                """
                UPDATE feed_source
                SET feed_url=?,last_checked_at=?,last_success_at=?,last_error=NULL
                WHERE id=?
                """,
                (feed_url, checked_at, checked_at, source_id),
            )
            for entry in parsed.entries:
                link = str(entry.get("link") or "").strip()
                if not link:
                    continue
                try:
                    link = _validate_public_url(link)
                except ValueError:
                    continue
                title = _clean_text(entry.get("title")) or "Sem título"
                summary = _clean_text(entry.get("summary") or entry.get("description"))
                guid = str(entry.get("id") or entry.get("guid") or link)
                author = _clean_text(entry.get("author"))
                published = str(
                    entry.get("published")
                    or entry.get("updated")
                    or entry.get("created")
                    or ""
                )
                category = classify(
                    title,
                    summary,
                    source["default_category"],
                )
                cur = conn.execute(
                    """
                    INSERT OR IGNORE INTO feed_item
                    (source_id,guid,url,title,summary,author,published_at,category,status,
                     source_verified,raw_json,created_at,updated_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                    (
                        source_id,
                        guid,
                        link,
                        title,
                        summary,
                        author,
                        published,
                        category,
                        "novo",
                        1,
                        json.dumps(dict(entry), ensure_ascii=False, default=str),
                        checked_at,
                        checked_at,
                    ),
                )
                if cur.rowcount:
                    inserted += 1
                else:
                    existing += 1
            conn.commit()
        return {
            "source_id": source_id,
            "feed_url": feed_url,
            "inserted": inserted,
            "existing": existing,
            "entries_seen": len(parsed.entries),
        }
    except Exception as exc:
        with connect() as conn:
            conn.execute(
                "UPDATE feed_source SET last_checked_at=?,last_error=? WHERE id=?",
                (checked_at, f"{exc.__class__.__name__}: {str(exc)[:500]}", source_id),
            )
            conn.commit()
        raise


def refresh_all() -> dict[str, Any]:
    results = []
    for source in list_sources():
        if not source["active"]:
            continue
        try:
            results.append({"ok": True, **refresh_source(source["id"])})
        except Exception as exc:
            results.append(
                {
                    "ok": False,
                    "source_id": source["id"],
                    "error": f"{exc.__class__.__name__}: {str(exc)[:300]}",
                }
            )
    return {"sources": results}


def list_items(
    *,
    status: str | None = None,
    category: str | None = None,
    source_id: int | None = None,
    query: str | None = None,
    limit: int = 100,
    offset: int = 0,
) -> dict[str, Any]:
    init_rss_db()
    where = ["1=1"]
    args: list[Any] = []
    if status:
        where.append("i.status=?")
        args.append(status)
    if category:
        where.append("i.category=?")
        args.append(category)
    if source_id:
        where.append("i.source_id=?")
        args.append(source_id)
    if query:
        where.append("(i.title LIKE ? OR i.summary LIKE ?)")
        q = f"%{query}%"
        args.extend([q, q])
    clause = " AND ".join(where)

    with connect() as conn:
        total = conn.execute(
            f"SELECT COUNT(*) FROM feed_item i WHERE {clause}", args
        ).fetchone()[0]
        rows = conn.execute(
            f"""
            SELECT i.*, s.name AS source_name
            FROM feed_item i
            JOIN feed_source s ON s.id=i.source_id
            WHERE {clause}
            ORDER BY i.id DESC
            LIMIT ? OFFSET ?
            """,
            [*args, max(1, min(limit, 500)), max(0, offset)],
        ).fetchall()
    return {"total": int(total), "items": [_item_row(row) for row in rows]}


def _item_row(row: sqlite3.Row) -> dict[str, Any]:
    item = dict(row)
    item["source_verified"] = bool(item["source_verified"])
    item.pop("raw_json", None)
    return item


def item_detail(item_id: int) -> dict[str, Any]:
    with connect() as conn:
        row = conn.execute(
            """
            SELECT i.*, s.name AS source_name
            FROM feed_item i JOIN feed_source s ON s.id=i.source_id
            WHERE i.id=?
            """,
            (item_id,),
        ).fetchone()
        if not row:
            raise KeyError("item_not_found")
        events = conn.execute(
            "SELECT * FROM feed_event WHERE item_id=? ORDER BY id DESC",
            (item_id,),
        ).fetchall()
    result = _item_row(row)
    result["events"] = [dict(event) for event in events]
    return result


def decide(
    item_id: int,
    actor: str,
    status: str,
    note: str | None = None,
    category: str | None = None,
) -> dict[str, Any]:
    if status not in STATUSES:
        raise ValueError("Status inválido.")
    if category is not None and category not in CATEGORIES:
        raise ValueError("Categoria inválida.")

    with connect() as conn:
        before = conn.execute("SELECT * FROM feed_item WHERE id=?", (item_id,)).fetchone()
        if not before:
            raise KeyError("item_not_found")

        changes: dict[str, Any] = {
            "status": {"from": before["status"], "to": status}
        }
        updates = ["status=?", "reviewed_by=?", "reviewed_at=?", "decision_note=?", "updated_at=?"]
        args: list[Any] = [status, actor, utcnow(), note, utcnow()]
        if category is not None and category != before["category"]:
            updates.append("category=?")
            args.append(category)
            changes["category"] = {"from": before["category"], "to": category}
        args.append(item_id)
        conn.execute(
            f"UPDATE feed_item SET {', '.join(updates)} WHERE id=?",
            args,
        )
        conn.execute(
            """
            INSERT INTO feed_event(item_id,actor,event_type,note,changes_json,created_at)
            VALUES (?,?,?,?,?,?)
            """,
            (
                item_id,
                actor,
                "decision",
                note,
                json.dumps(changes, ensure_ascii=False),
                utcnow(),
            ),
        )
        conn.commit()
    return item_detail(item_id)


def mark_draft(item_id: int, actor: str, drupal_draft_id: str) -> dict[str, Any]:
    with connect() as conn:
        before = conn.execute("SELECT * FROM feed_item WHERE id=?", (item_id,)).fetchone()
        if not before:
            raise KeyError("item_not_found")
        conn.execute(
            """
            UPDATE feed_item
            SET status='rascunho_criado',drupal_draft_id=?,reviewed_by=?,
                reviewed_at=?,updated_at=?
            WHERE id=?
            """,
            (drupal_draft_id, actor, utcnow(), utcnow(), item_id),
        )
        conn.execute(
            """
            INSERT INTO feed_event(item_id,actor,event_type,note,changes_json,created_at)
            VALUES (?,?,?,?,?,?)
            """,
            (
                item_id,
                actor,
                "drupal_draft_created",
                "Rascunho Drupal criado após aprovação da pauta.",
                json.dumps({"drupal_draft_id": drupal_draft_id}, ensure_ascii=False),
                utcnow(),
            ),
        )
        conn.commit()
    return item_detail(item_id)


def dashboard() -> dict[str, Any]:
    with connect() as conn:
        source_count = conn.execute("SELECT COUNT(*) FROM feed_source WHERE active=1").fetchone()[0]
        rows = conn.execute("SELECT status,category FROM feed_item").fetchall()
    by_status: dict[str, int] = {}
    by_category: dict[str, int] = {}
    for row in rows:
        by_status[row["status"]] = by_status.get(row["status"], 0) + 1
        by_category[row["category"]] = by_category.get(row["category"], 0) + 1
    return {
        "active_sources": int(source_count),
        "total_items": len(rows),
        "by_status": by_status,
        "by_category": by_category,
        "categories": CATEGORIES,
        "statuses": STATUSES,
    }


init_rss_db()


def _validate_reference_url(url: str) -> str:
    """Validate a human-reviewed reference URL without fetching or DNS resolution."""
    parsed = urlparse(url.strip())
    if parsed.scheme not in {"http", "https"}:
        raise ValueError("A fonte deve usar http ou https.")
    if parsed.username or parsed.password:
        raise ValueError("URL com credenciais não é permitida.")
    if not parsed.hostname:
        raise ValueError("URL sem hostname.")
    if parsed.port not in (None, 80, 443):
        raise ValueError("A fonte deve usar porta web padrão.")
    return parsed.geturl()


def add_manual_item(
    *,
    title: str,
    url: str,
    category: str,
    actor: str,
    summary: str | None = None,
) -> dict[str, Any]:
    """Capture an official-page opportunity when no RSS/Atom feed is available."""
    init_rss_db()
    if category not in CATEGORIES:
        raise ValueError("Categoria inválida.")
    normalized = _validate_reference_url(url)
    now = utcnow()
    with connect() as conn:
        source = conn.execute(
            "SELECT id FROM feed_source WHERE name='Captura manual de fonte oficial'"
        ).fetchone()
        if source:
            source_id = int(source["id"])
        else:
            cur = conn.execute(
                """
                INSERT INTO feed_source
                (name,url,feed_url,default_category,active,created_by,created_at)
                VALUES (?,?,?,?,0,?,?)
                """,
                (
                    "Captura manual de fonte oficial",
                    "https://neruds.org/",
                    None,
                    None,
                    actor,
                    now,
                ),
            )
            source_id = int(cur.lastrowid)

        guid = f"manual:{normalized}"
        clean_title = _clean_text(title) or "Sem título"
        clean_summary = _clean_text(summary)
        cur = conn.execute(
            """
            INSERT OR IGNORE INTO feed_item
            (source_id,guid,url,title,summary,author,published_at,category,status,
             source_verified,raw_json,created_at,updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            (
                source_id,
                guid,
                normalized,
                clean_title,
                clean_summary,
                actor,
                "",
                category,
                "novo",
                0,
                json.dumps(
                    {"manual": True, "captured_by": actor, "url": normalized},
                    ensure_ascii=False,
                ),
                now,
                now,
            ),
        )
        if not cur.rowcount:
            row = conn.execute(
                "SELECT id FROM feed_item WHERE source_id=? AND url=?",
                (source_id, normalized),
            ).fetchone()
            if not row:
                raise ValueError("A oportunidade já existe.")
            item_id = int(row["id"])
        else:
            item_id = int(cur.lastrowid)

        conn.execute(
            """
            INSERT INTO feed_event(item_id,actor,event_type,note,changes_json,created_at)
            VALUES (?,?,?,?,?,?)
            """,
            (
                item_id,
                actor,
                "manual_capture",
                "URL oficial capturada manualmente porque a fonte não oferece RSS/Atom utilizável.",
                json.dumps({"category": category}, ensure_ascii=False),
                now,
            ),
        )
        conn.commit()
    return item_detail(item_id)
