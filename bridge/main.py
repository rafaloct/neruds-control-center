from __future__ import annotations

import asyncio
import io
import json
import logging
import os
import re
import secrets
import smtplib
import socket
import ssl
import subprocess
import time
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from logging.handlers import TimedRotatingFileHandler
from email.message import EmailMessage
from html import escape, unescape
from html.parser import HTMLParser
from typing import Any
from urllib.parse import urljoin, urlparse
from weakref import WeakValueDictionary

import httpx

import content_map
import identity_store
import manage_schema
import mission_automation
import mission_store
import portal_links
import review_store
import rss_store
import session_store
from dotenv import load_dotenv
from fastapi import (
    Body,
    Depends,
    FastAPI,
    File,
    Form,
    Header,
    HTTPException,
    Query,
    Request,
    UploadFile,
)
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel, Field

load_dotenv()

PORTAL_URL = os.getenv("NERUDS_PORTAL_URL", "https://neruds.org").rstrip("/")
VPS_TAILSCALE_HOST = os.getenv("NERUDS_VPS_TAILSCALE_HOST", "100.111.132.36")

_PORTAL_NODE_PATH = portal_links.NODE_PATH_RE


def _portal_url_path(url: str) -> str | None:
    """Portal-relative path when *url* shares the configured portal's
    scheme, origin and base path; None otherwise."""
    return portal_links.portal_url_path(url, PORTAL_URL)


def _portal_node_parts(url: str) -> tuple[str, bool] | None:
    """Return (nid, is_edit) when *url* is a /node/{nid}[/edit] portal page."""
    return portal_links.portal_node_parts(url, PORTAL_URL)


def _portal_node_nid(url: str) -> str | None:
    parts = _portal_node_parts(url)
    return parts[0] if parts else None


def _portal_node_link(url: str, *, require_edit: bool) -> bool:
    """True when *url* is a portal /node link of exactly the expected kind —
    the /edit suffix must be present for edit_url and absent for public_url."""
    return portal_links.portal_node_link(
        url, require_edit=require_edit, portal_url=PORTAL_URL
    )


ALLOWED_ORIGINS = [
    origin.strip()
    for origin in os.getenv(
        "NERUDS_ALLOWED_ORIGINS",
        "https://largeo.tail2faed0.ts.net:8444",
    ).split(",")
    if origin.strip()
]

SMTP_HOST = os.getenv("NERUDS_SMTP_HOST", "mail.neruds.org")
SMTP_CONNECT_HOST = os.getenv("NERUDS_SMTP_CONNECT_HOST", SMTP_HOST)
SMTP_PORT = int(os.getenv("NERUDS_SMTP_PORT", "587"))
SMTP_USER = os.getenv("NERUDS_SMTP_USER", "")
SMTP_PASSWORD = os.getenv("NERUDS_SMTP_PASSWORD", "")
SMTP_FROM = os.getenv("NERUDS_SMTP_FROM", SMTP_USER)
SMTP_REVIEW_TO = os.getenv("NERUDS_SMTP_REVIEW_TO", "")
SMTP_STARTTLS = os.getenv("NERUDS_SMTP_STARTTLS", "true").lower() == "true"

# Sessions persist in SQLite (data/sessions.sqlite3) with Drupal cookies and
# CSRF encrypted at rest, so logins survive restarts and work across web,
# desktop and mobile clients. Passwords are never stored. Drupal remains the
# source of truth for identity/permissions.
SESSION_IDLE_TTL = timedelta(hours=int(os.getenv("NERUDS_SESSION_IDLE_HOURS", "8")))
SESSIONS = session_store.SESSIONS
# Serialize requests for the same opportunity in this bridge process.
_OPPORTUNITY_DRAFT_LOCKS: WeakValueDictionary[int, asyncio.Lock] = WeakValueDictionary()

# ---------------------------------------------------------------------------
# Observabilidade: access log estruturado + backup agendado do mission store
# ---------------------------------------------------------------------------

_BRIDGE_STARTED_AT = datetime.now(timezone.utc)
_ACCESS_LOGGER = logging.getLogger("neruds_bridge.access")
_ACCESS_LOGGER.propagate = False


def _access_log_dir():
    path = mission_store.DATA_DIR / "logs"
    path.mkdir(parents=True, exist_ok=True)
    return path


_ACCESS_LOG_BOUND_DIR: Any = None


def _configure_access_log() -> None:
    global _ACCESS_LOG_BOUND_DIR
    log_dir = _access_log_dir()
    if _ACCESS_LOGGER.handlers and _ACCESS_LOG_BOUND_DIR == log_dir:
        return
    for handler in list(_ACCESS_LOGGER.handlers):
        _ACCESS_LOGGER.removeHandler(handler)
        handler.close()
    handler = TimedRotatingFileHandler(
        log_dir / "access.log",
        when="midnight",
        backupCount=14,
        encoding="utf-8",
    )
    handler.setFormatter(logging.Formatter("%(message)s"))
    _ACCESS_LOGGER.addHandler(handler)
    _ACCESS_LOGGER.setLevel(logging.INFO)
    _ACCESS_LOG_BOUND_DIR = log_dir


def _access_log(event: str, **fields: Any) -> None:
    _configure_access_log()
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "event": event,
        **fields,
    }
    _ACCESS_LOGGER.info(json.dumps(record, ensure_ascii=False, default=str))


class AccessLogMiddleware:
    """ASGI middleware que registra uma linha JSON por requisição HTTP.

    Nunca registra corpos, query strings, cookies ou cabeçalhos de
    autorização — somente método, rota, status e duração.
    """

    def __init__(self, app: Any) -> None:
        self.app = app

    async def __call__(self, scope, receive, send) -> None:  # noqa: ANN001
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        start = time.monotonic()
        status = 500

        async def send_wrapped(message):  # noqa: ANN001
            nonlocal status
            if message["type"] == "http.response.start":
                status = message["status"]
            await send(message)

        try:
            await self.app(scope, receive, send_wrapped)
        finally:
            # Segmentos puramente numéricos são identificadores (uid, nid,
            # task_id) — redigidos para não persistir PII no log.
            path = re.sub(r"/\d+(?=/|$)", "/:id", scope.get("path", ""))
            _access_log(
                "http_request",
                method=scope.get("method", ""),
                path=path,
                status=status,
                duration_ms=round((time.monotonic() - start) * 1000, 1),
            )


async def _backup_loop() -> None:
    while True:
        try:
            if not mission_store.check_ready():
                # Store ausente/vazio = perda de dados; arquivar isso
                # poderia expulsar o último backup bom pela retenção.
                _access_log("backup_skipped_store_unready")
            elif mission_store.backup_due():
                dest = await asyncio.to_thread(mission_store.backup_db)
                _access_log("backup_completed", file=dest.name)
        except Exception as exc:  # backup failure must not kill the service
            _access_log("backup_failed", error=type(exc).__name__)
        await asyncio.sleep(3600)


@asynccontextmanager
async def _lifespan(app: FastAPI):  # noqa: ARG001
    _configure_access_log()
    session_store.init_db()
    purged = session_store.purge_idle(SESSION_IDLE_TTL)
    _access_log("service_started", version="0.6.0", sessions_purged=purged)
    task = asyncio.create_task(_backup_loop())
    try:
        yield
    finally:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        _access_log("service_stopped")


app = FastAPI(
    title="NERUDS Control Bridge",
    version="0.6.0",
    lifespan=_lifespan,
    description=(
        "Bridge do NERUDS entre Flutter, Drupal e serviços internos. "
        "Autenticação editorial é delegada ao Drupal."
    ),
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=False,
    allow_methods=["GET", "POST", "PATCH", "DELETE"],
    allow_headers=["*"],
)
app.add_middleware(AccessLogMiddleware)


class HiddenInputParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.fields: dict[str, str] = {}
        self._hidden_body_format: str | None = None
        self._format_select_seen = False
        self._in_format_select = False
        self._format_select_disabled = False
        self._format_group_disabled = False
        self._format_options: list[tuple[str, bool]] = []
        self._guideline_format_ids: set[str] = set()

    @property
    def body_format(self) -> str | None:
        if (
            self._format_select_seen
            and not self._format_select_disabled
            and self._format_options
        ):
            return next(
                (value for value, selected in self._format_options if selected),
                self._format_options[0][0],
            )
        if self._hidden_body_format is not None:
            return self._hidden_body_format
        if len(self._guideline_format_ids) == 1:
            return next(iter(self._guideline_format_ids))
        return None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag = tag.lower()
        data = dict(attrs)
        name = data.get("name")
        guideline_format = data.get("data-drupal-format-id")
        if guideline_format:
            self._guideline_format_ids.add(guideline_format)
        if tag == "select" and name == "body[0][format]":
            self._format_select_seen = True
            self._in_format_select = True
            self._format_select_disabled = "disabled" in data
            self._format_group_disabled = False
            self._format_options = []
        elif tag == "optgroup" and self._in_format_select:
            self._format_group_disabled = "disabled" in data
        elif tag == "option" and self._in_format_select:
            value = data.get("value") or ""
            if value and "disabled" not in data and not self._format_group_disabled:
                self._format_options.append((value, "selected" in data))

        if tag != "input" or not name:
            return
        input_type = (data.get("type") or "").lower()
        if input_type == "hidden":
            self.fields[name] = data.get("value") or ""
            if name == "body[0][format]" and "disabled" not in data:
                self._hidden_body_format = data.get("value") or None
        elif input_type == "submit" and name == "op" and name not in self.fields:
            self.fields[name] = data.get("value") or ""

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "select":
            self._in_format_select = False
        elif tag.lower() == "optgroup":
            self._format_group_disabled = False


class LoginRequest(BaseModel):
    username: str = Field(min_length=1, max_length=128)
    password: str = Field(min_length=1, max_length=512)


class NewsDraftRequest(BaseModel):
    title: str = Field(min_length=3, max_length=255)
    summary: str = Field(default="", max_length=4000)
    body: str = Field(min_length=1)
    publication_date: str | None = None
    opportunity_item_id: int | None = None
    mission_task_id: int | None = None


# Tipos de conteúdo criáveis pelo app. `required` descreve os campos
# obrigatórios do Drupal para que o cliente monte o formulário guiado;
# `drupal` é a chave POST esperada pelo formulário nativo /node/add/{bundle}.
CONTENT_BUNDLES: dict[str, dict[str, Any]] = {
    "noticia": {
        "label": "Notícia",
        "required": [
            {
                "key": "data",
                "label": "Data da notícia",
                "kind": "date",
                "drupal": "field_data_noticia[0][value][date]",
            }
        ],
    },
    "relatorio": {"label": "Relatório", "required": []},
    "acao_extensionista": {"label": "Ação Extensionista", "required": []},
    "publicacao": {"label": "Publicação", "required": []},
    "evento_cientifico": {
        "label": "Evento Científico",
        "required": [
            {
                "key": "data",
                "label": "Data do evento",
                "kind": "date",
                "drupal": "field_data_evento[0][value][date]",
            },
            {
                "key": "local",
                "label": "Local do evento",
                "kind": "text",
                "drupal": "field_local_evento[0][value]",
            },
        ],
    },
    "grupo_estudos": {"label": "Grupo de Estudos", "required": []},
    "projeto_pesquisa_extensao": {
        "label": "Projeto de Pesquisa e Extensão",
        "required": [
            {
                "key": "coordenador",
                "label": "Coordenador",
                "kind": "text",
                "drupal": "field_coordenador[0][value]",
            }
        ],
    },
}

# Cache curto de permissão de criação por token (o formulário Drupal decide).
_CREATE_ACCESS_CACHE: dict[str, tuple[float, dict[str, bool]]] = {}
_CREATE_ACCESS_TTL = 600.0


class ContentDraftRequest(BaseModel):
    title: str = Field(min_length=3, max_length=255)
    summary: str = Field(default="", max_length=4000)
    body: str = Field(default="")
    data: str | None = None
    local: str | None = None
    coordenador: str | None = None
    opportunity_item_id: int | None = None
    mission_task_id: int | None = None


class MissionTaskPatch(BaseModel):
    priority: str | None = None
    status: str | None = None
    current_stage: str | None = None
    evidence: str | None = None
    confirmed_source: str | None = None
    consultation_date: str | None = None
    observations: str | None = None
    responsible: str | None = None
    primary_owner: str | None = None
    cross_reviewer: str | None = None
    public_check_ok: bool | None = None
    internal_deadline: str | None = None
    public_url: str | None = None
    edit_url: str | None = None
    note: str | None = None
    evidence_url: str | None = None


class MissionTaskCreate(BaseModel):
    """Task born from the monitoring board — a real portal gap becomes
    tracked work. gap_bundle/gap_fields record which monitored fields were
    missing so the task can be reconciled against the portal later."""

    title: str = Field(min_length=1, max_length=300)
    content_type: str | None = None
    priority: str | None = None
    status: str | None = None
    responsible: str | None = None
    primary_owner: str | None = None
    cross_reviewer: str | None = None
    internal_deadline: str | None = None
    action: str | None = None
    gaps: str | None = None
    observations: str | None = None
    public_url: str | None = None
    edit_url: str | None = None
    gap_bundle: str | None = None
    gap_fields: list[str] = Field(default_factory=list, max_length=50)
    note: str | None = None


class SavedMissionFilterCreate(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    filters: dict[str, str] = Field(default_factory=dict)


class ChecklistPatch(BaseModel):
    completed: bool
    note: str | None = None


class WorkItemPatch(BaseModel):
    completed: bool | None = None
    status: str | None = None
    evidence: str | None = None
    note: str | None = None


class FeedSourceCreate(BaseModel):
    name: str = Field(min_length=2, max_length=160)
    url: str = Field(min_length=8, max_length=2048)
    default_category: str | None = None


class FeedSourcePatch(BaseModel):
    active: bool | None = None
    default_category: str | None = None


class FeedDecision(BaseModel):
    status: str
    note: str | None = None
    category: str | None = None
    deadline_at: str | None = Field(default=None, max_length=32)
    fit_tags: list[str] | None = None


class ManualOpportunityCreate(BaseModel):
    title: str = Field(min_length=3, max_length=300)
    url: str = Field(min_length=8, max_length=2048)
    category: str
    summary: str | None = Field(default=None, max_length=5000)
    deadline_at: str | None = Field(default=None, max_length=32)


class DraftReviewDecision(BaseModel):
    status: str
    note: str | None = Field(default=None, max_length=4000)


class IdentityAccountCreate(BaseModel):
    name: str = Field(min_length=2, max_length=60)
    mail: str = Field(min_length=5, max_length=254)
    password: str | None = Field(default=None, min_length=8, max_length=128)


class IdentityStatusPatch(BaseModel):
    active: bool


class IdentityCheckPatch(BaseModel):
    step: str = Field(min_length=2, max_length=60)
    done: bool


class IdentityOffboard(BaseModel):
    transfer_to: str | None = Field(default=None, max_length=60)
    note: str | None = Field(default=None, max_length=2000)


def tcp_reachable(host: str, port: int, timeout: float = 1.2) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def plain_to_basic_html(value: str) -> str:
    paragraphs = [part.strip() for part in re.split(r"\n\s*\n", value) if part.strip()]
    if not paragraphs:
        return ""
    return "\n".join(
        f"<p>{escape(part).replace(chr(10), '<br>')}</p>" for part in paragraphs
    )


def bearer_token(authorization: str | None) -> str:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Sessão ausente.")
    return authorization.split(" ", 1)[1].strip()


def require_session(authorization: str | None = Header(default=None)) -> dict[str, Any]:
    token = bearer_token(authorization)
    session = SESSIONS.get(token)
    if not session:
        raise HTTPException(status_code=401, detail="Sessão expirada ou inválida.")

    now = datetime.now(timezone.utc)
    try:
        last_seen = datetime.fromisoformat(session["last_seen"])
    except (KeyError, TypeError, ValueError):
        last_seen = now - SESSION_IDLE_TTL - timedelta(seconds=1)

    if now - last_seen > SESSION_IDLE_TTL:
        SESSIONS.pop(token, None)
        raise HTTPException(status_code=401, detail="Sessão expirada por inatividade.")

    SESSIONS.touch(token, now.isoformat())
    session["last_seen"] = now.isoformat()
    return session


def drupal_client(session: dict[str, Any], follow_redirects: bool = True) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        base_url=PORTAL_URL,
        cookies=session["cookies"],
        timeout=15,
        follow_redirects=follow_redirects,
        headers={"User-Agent": "NERUDS-Control-Center/0.2"},
    )


async def notify_review(title: str, author: str) -> dict[str, Any]:
    if not (SMTP_FROM and SMTP_REVIEW_TO):
        return {"sent": False, "reason": "smtp_not_configured"}

    def _send() -> None:
        msg = EmailMessage()
        msg["Subject"] = f"[NERUDS] Rascunho aguardando revisão: {title}"
        msg["From"] = SMTP_FROM
        msg["To"] = SMTP_REVIEW_TO
        msg.set_content(
            "Um novo rascunho foi criado no Portal NERUDS.\n\n"
            f"Título: {title}\n"
            f"Autor/editor: {author}\n"
            f"Portal: {PORTAL_URL}\n\n"
            "Acesse o fluxo editorial para revisar antes da publicação."
        )
        context = ssl.create_default_context()
        with smtplib.SMTP(SMTP_CONNECT_HOST, SMTP_PORT, timeout=12) as smtp:
            if SMTP_CONNECT_HOST != SMTP_HOST:
                smtp._host = SMTP_HOST
            smtp.ehlo()
            if SMTP_STARTTLS:
                smtp.starttls(context=context)
                smtp.ehlo()
            if SMTP_USER and SMTP_PASSWORD:
                smtp.login(SMTP_USER, SMTP_PASSWORD)
            smtp.send_message(msg)

    try:
        await asyncio.to_thread(_send)
        return {"sent": True}
    except Exception as exc:
        # Do not fail content creation because mail is unavailable.
        return {"sent": False, "reason": exc.__class__.__name__}


def _node_urls(nid: Any, alias: Any = None) -> dict[str, str | None]:
    node_id = str(nid or "").strip()
    public_url = f"{PORTAL_URL}/node/{node_id}" if node_id.isdecimal() else None
    if isinstance(alias, str) and alias.startswith("/") and not alias.startswith("//"):
        public_url = f"{PORTAL_URL}{alias}"
    return {
        "public_url": public_url,
        "edit_url": f"{PORTAL_URL}/node/{node_id}/edit" if node_id.isdecimal() else None,
    }


def _readable_field(value: Any) -> str:
    if isinstance(value, dict):
        if value.get("format") == "plain_text":
            raw = value.get("value")
            return raw if isinstance(raw, str) else ""
        value = value.get("value") or value.get("processed") or ""
    if not isinstance(value, str):
        return ""
    value = re.sub(r"<(script|style)\b[^>]*>.*?</\1>", "", value, flags=re.I | re.S)
    value = re.sub(r"<br\s*/?>|</(?:p|div|li|h[1-6])>", "\n", value, flags=re.I)
    value = unescape(re.sub(r"<[^>]+>", "", value))
    return "\n".join(
        re.sub(r"[ \t]+", " ", line).strip()
        for line in value.splitlines()
        if line.strip()
    )


def _news_owner_uid(item: dict[str, Any]) -> str | None:
    relationship = (item.get("relationships") or {}).get("uid") or {}
    owner = relationship.get("data") or {}
    if not isinstance(owner, dict):
        return None
    raw = (owner.get("meta") or {}).get("drupal_internal__target_id")
    uid = str(raw) if raw is not None else ""
    return uid if uid.isdecimal() else None


def _owns_review(
    session: dict[str, Any],
    review: dict[str, Any] | None,
    owner_uid: str | None = None,
) -> bool:
    known_uid = owner_uid or (review or {}).get("owner_uid")
    if known_uid is not None:
        return str(known_uid) == str(session.get("uid") or "")
    # Preserve ownership of bridge drafts predating UID storage. A native
    # placeholder never proves that the person currently reading is the author.
    author = (review or {}).get("author")
    return bool(author and author != "Drupal" and author == session["username"])


def _news_queue_item(item: dict[str, Any], session: dict[str, Any]) -> dict[str, Any]:
    attrs = item.get("attributes") or {}
    nid = attrs.get("drupal_internal__nid")
    owner_uid = _news_owner_uid(item)
    published = attrs.get("status") in (True, 1, "1")
    review = None
    if nid is not None:
        author = (
            session["username"]
            if owner_uid is not None and owner_uid == str(session.get("uid") or "")
            else None
        )
        review = review_store.reconcile_draft(
            str(nid),
            attrs.get("title") or "Sem título",
            owner_uid=owner_uid,
            author=author,
            published=published,
        )
    body = attrs.get("body") or {}
    body_summary = (
        {"value": body.get("summary"), "format": body.get("format")}
        if isinstance(body, dict)
        else ""
    )
    path = attrs.get("path") or {}
    return {
        "id": item.get("id"),
        "nid": nid,
        "title": attrs.get("title") or "Sem título",
        "changed": attrs.get("changed", ""),
        "created": attrs.get("created", ""),
        "moderation_state": attrs.get("moderation_state", ""),
        "status": "published" if published else (review or {}).get("review_status", "pending"),
        "published": published,
        "body": _readable_field(body),
        "summary": _readable_field(attrs.get("field_resumo_noticia"))
        or _readable_field(body_summary),
        "owner_uid": owner_uid or (review or {}).get("owner_uid"),
        "is_owner": _owns_review(session, review, owner_uid),
        **_node_urls(nid, path.get("alias") if isinstance(path, dict) else None),
        "review": review,
    }


async def _authorized_news_item(nid: int, session: dict[str, Any]) -> dict[str, Any]:
    async with drupal_client(session) as client:
        response = await client.get(
            "/jsonapi/node/noticia",
            params={"filter[drupal_internal__nid]": str(nid), "page[limit]": "1"},
        )
        if response.status_code >= 400:
            raise HTTPException(
                status_code=response.status_code,
                detail="Drupal não autorizou a leitura deste rascunho.",
            )
        for item in response.json().get("data", []):
            if str((item.get("attributes") or {}).get("drupal_internal__nid")) == str(nid):
                return _news_queue_item(item, session)
    raise HTTPException(status_code=404, detail="Rascunho não encontrado no portal.")


async def _create_bundle_draft_internal(
    bundle: str,
    *,
    title: str,
    summary: str,
    body: str,
    extras: dict[str, str] | None = None,
    session: dict[str, Any],
    opportunity_item_id: int | None = None,
    mission_task_id: int | None = None,
) -> dict[str, Any]:
    label = CONTENT_BUNDLES.get(bundle, {}).get("label", bundle)
    async with drupal_client(session) as client:
        form = await client.get(f"/node/add/{bundle}")
        if form.status_code != 200:
            raise HTTPException(
                status_code=form.status_code,
                detail=f"Drupal recusou o acesso ao formulário de {label}.",
            )

        parser = HiddenInputParser()
        parser.feed(form.text)
        text_format = parser.body_format
        fields = parser.fields
        use_html = text_format is not None and text_format != "plain_text"
        fields.update(
            {
                "title[0][value]": title,
                "body[0][summary]": plain_to_basic_html(summary)
                if use_html
                else summary,
                "body[0][value]": plain_to_basic_html(body)
                if use_html
                else body,
                "status[value]": "0",
                "form_id": fields.get("form_id", f"node_{bundle}_form"),
                "op": fields.get("op", "Salvar"),
            }
        )
        if text_format is None:
            fields.pop("body[0][format]", None)
        else:
            fields["body[0][format]"] = text_format
        fields.update({k: v for k, v in (extras or {}).items() if v != ""})

        response = await client.post(
            f"/node/add/{bundle}",
            data=fields,
            follow_redirects=False,
        )
        if response.status_code not in (302, 303):
            raise HTTPException(
                status_code=response.status_code if response.status_code >= 400 else 422,
                detail={
                    "message": "Drupal não salvou o rascunho pelo formulário nativo.",
                    "response": response.text[:1200],
                },
            )

        location = response.headers.get("location", "")
        match = re.search(r"/node/([1-9][0-9]*)(?:[/?#]|$)", location)
        node_id = match.group(1) if match else None
        jsonapi_id = None

        if not node_id:
            lookup = await client.get(
                f"/jsonapi/node/{bundle}",
                params={
                    "filter[title]": title,
                    "sort": "-created",
                    "page[limit]": "5",
                },
            )
            if lookup.status_code == 200:
                for item in lookup.json().get("data", []):
                    attrs = item.get("attributes", {})
                    if attrs.get("title") != title:
                        continue
                    if _news_owner_uid(item) != str(session.get("uid") or ""):
                        continue
                    if attrs.get("status") in (True, 1, "1"):
                        continue
                    internal_nid = str(attrs.get("drupal_internal__nid") or "")
                    if internal_nid.isascii() and internal_nid.isdecimal() and int(internal_nid) > 0:
                        node_id = internal_nid
                    jsonapi_id = item.get("id")
                    break

        if node_id is None:
            raise HTTPException(
                status_code=502,
                detail="Drupal retornou sem confirmar o identificador numérico da notícia. "
                "Confira o registro no portal antes de repetir.",
            )
        draft_id = node_id
        if draft_id:
            review_store.register_draft(
                str(draft_id),
                title,
                session["username"],
                owner_uid=str(session["uid"]) if session.get("uid") is not None else None,
                opportunity_item_id=opportunity_item_id,
                mission_task_id=mission_task_id,
            )

        return {
            "id": draft_id,
            "drupal_internal_nid": node_id,
            "jsonapi_id": jsonapi_id,
            "type": f"node--{bundle}",
            "location": location,
            **_node_urls(node_id),
            "owner_uid": str(session["uid"]) if session.get("uid") is not None else None,
            "is_owner": True,
        }


async def _create_news_draft_internal(
    *,
    title: str,
    summary: str,
    body: str,
    publication_date: str | None,
    session: dict[str, Any],
    opportunity_item_id: int | None = None,
    mission_task_id: int | None = None,
) -> dict[str, Any]:
    return await _create_bundle_draft_internal(
        "noticia",
        title=title,
        summary=summary,
        body=body,
        extras={
            "field_data_noticia[0][value][date]": (
                publication_date or datetime.now().date().isoformat()
            ),
            **(
                {"field_data_publicacao[0][value][date]": publication_date}
                if publication_date
                else {}
            ),
        },
        session=session,
        opportunity_item_id=opportunity_item_id,
        mission_task_id=mission_task_id,
    )


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "ok": True,
        "service": "neruds-control-bridge",
        "mode": "editorial-mvp",
        "version": "0.6.0",
        "time": datetime.now(timezone.utc).isoformat(),
        "active_sessions": len(SESSIONS),
    }


@app.get("/ready")
def ready() -> dict[str, Any]:
    """Readiness: o processo só está pronto se o mission store existir e
    o schema da missão responder. Liveness simples continua em /health."""
    try:
        ok = mission_store.check_ready()
    except Exception as exc:
        raise HTTPException(
            status_code=503, detail=f"mission store indisponível: {type(exc).__name__}"
        ) from exc
    if not ok:
        raise HTTPException(
            status_code=503, detail="mission store ausente ou schema inválido"
        )
    return {
        "ready": True,
        "db": True,
        "time": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/capabilities")
def capabilities() -> dict[str, Any]:
    return {
        "portal_read": True,
        "drupal_session_login": True,
        "news_draft": True,
        "draft_queue": True,
        "smtp_notifications": bool(SMTP_FROM and SMTP_REVIEW_TO),
        "drush": False,
        "backup": True,
        "server_update": False,
        "notes": [
            "Identidade e permissões editoriais são delegadas ao Drupal.",
            "Senha Drupal não é persistida pelo bridge.",
            "Operações de infraestrutura continuam separadas do fluxo editorial.",
        ],
    }


# ---------------------------------------------------------------------------
# Config remota do aplicativo — atualizável sem rebuild/redeploy do cliente
# ---------------------------------------------------------------------------

# data/app_config.json é mesclado sobre os defaults; também pode ser editado
# diretamente no servidor. Não colocar segredos aqui: o GET é público.
APP_CONFIG_PATH = mission_store.DATA_DIR / "app_config.json"

_DEFAULT_APP_CONFIG: dict[str, Any] = {
    "schema_version": 1,
    "app_name": "NERUDS Control Center",
    "portal_url": PORTAL_URL,
    "min_app_version": "1.0.0",
    "features": {
        "missions": True,
        "opportunities": True,
        "monitoring": True,
        "editorial": True,
        "identity_admin": True,
        "manage": True,
    },
    "onboarding": {
        "enabled": True,
        "steps": [
            "Conheça sua missão na aba Missão.",
            "Registre evidências e peça revisão cruzada.",
            "Acompanhe pendências no painel de atenção.",
        ],
    },
    "links": {
        "portal": PORTAL_URL,
        "support_mail": "admin@neruds.org",
    },
}


def _load_app_config() -> dict[str, Any]:
    merged = json.loads(json.dumps(_DEFAULT_APP_CONFIG))
    try:
        if APP_CONFIG_PATH.exists():
            stored = json.loads(APP_CONFIG_PATH.read_text(encoding="utf-8"))
            if isinstance(stored, dict):
                _deep_merge(merged, stored)
    except (OSError, ValueError) as exc:
        _access_log("app_config_load_error", error=type(exc).__name__)
    return merged


def _deep_merge(base: dict[str, Any], overlay: dict[str, Any]) -> dict[str, Any]:
    for key, value in overlay.items():
        if (
            key in base
            and isinstance(base[key], dict)
            and isinstance(value, dict)
        ):
            _deep_merge(base[key], value)
        else:
            base[key] = value
    return base


@app.get("/config/app")
def get_app_config() -> dict[str, Any]:
    """Config remota consumida pelos clientes na inicialização."""
    return _load_app_config()


@app.put("/config/app")
async def put_app_config(
    request: Request,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    _require_user_admin(session)
    try:
        payload = await request.json()
    except ValueError as exc:
        raise HTTPException(status_code=422, detail="JSON inválido.") from exc
    if not isinstance(payload, dict):
        raise HTTPException(
            status_code=422, detail="O corpo deve ser um objeto JSON."
        )
    payload.pop("schema_version", None)
    APP_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = APP_CONFIG_PATH.with_suffix(".tmp")
    tmp.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    tmp.replace(APP_CONFIG_PATH)
    _access_log("app_config_updated", actor=session["username"])
    return _load_app_config()


# ---------------------------------------------------------------------------
# Assistente IA (OpenRouter) — chave fica só no ambiente do servidor.
# ---------------------------------------------------------------------------

OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY", "").strip()
OPENROUTER_MODEL = os.getenv("OPENROUTER_MODEL", "openai/gpt-4o-mini")
OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"

_AI_ACTIONS: dict[str, str] = {
    "improve": (
        "Reescreva o texto abaixo como redator do portal NERUDS, em "
        "português claro e direto, sem inventar fatos. Mantenha datas, "
        "nomes e números exatamente como estão. Responda só com o texto."
    ),
    "summarize": (
        "Resuma o texto abaixo em até 3 frases em português, para uso "
        "como resumo em cards e listagens do portal NERUDS."
    ),
    "title": (
        "Sugira um título curto e factual (máx. 12 palavras) em português "
        "para o conteúdo abaixo, no estilo do portal NERUDS."
    ),
    "fields": (
        "Dado o texto de campo abaixo, extraia em JSON as chaves: "
        "title, summary, data (AAAA-MM-DD ou vazio), local, autores. "
        "Responda somente o JSON."
    ),
    "draft": (
        "Escreva um rascunho curto e factual em português para o campo "
        "indicado, no estilo editorial do portal NERUDS (núcleo de "
        "estudos rurais e socioecológicos). Use apenas as informações "
        "do contexto; sem inventar nomes, datas ou números. Responda "
        "só com o texto do campo, sem comentários."
    ),
}

_AI_RATE: dict[str, list[float]] = {}
_AI_RATE_MAX = int(os.getenv("NERUDS_AI_RATE_MAX", "20"))
_AI_RATE_WINDOW = 300.0


class AiAssistRequest(BaseModel):
    action: str
    text: str = Field(min_length=1, max_length=12000)
    context: str = Field(default="", max_length=2000)


@app.post("/ai/assist")
async def ai_assist(
    payload: AiAssistRequest,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    """Proxy restrito para o OpenRouter — ações fixas, sem chat livre."""
    if not OPENROUTER_API_KEY:
        raise HTTPException(
            status_code=503,
            detail="Assistente IA não configurado no servidor.",
        )
    system = _AI_ACTIONS.get(payload.action)
    if system is None:
        raise HTTPException(status_code=422, detail="Ação não suportada.")

    user = session.get("username") or "anon"
    now = time.monotonic()
    calls = [t for t in _AI_RATE.get(user, []) if now - t < _AI_RATE_WINDOW]
    if len(calls) >= _AI_RATE_MAX:
        raise HTTPException(
            status_code=429,
            detail="Limite de usos do assistente atingido. Tente em alguns minutos.",
        )
    calls.append(now)
    _AI_RATE[user] = calls

    prompt = payload.text if not payload.context else (
        f"Contexto: {payload.context}\n\n{payload.text}"
    )
    try:
        async with httpx.AsyncClient(timeout=45) as client:
            response = await client.post(
                OPENROUTER_URL,
                headers={
                    "Authorization": f"Bearer {OPENROUTER_API_KEY}",
                    "HTTP-Referer": "https://app.neruds.org",
                    "X-Title": "NERUDS Control Center",
                },
                json={
                    "model": OPENROUTER_MODEL,
                    "messages": [
                        {"role": "system", "content": system},
                        {"role": "user", "content": prompt},
                    ],
                    "temperature": 0.4,
                    "max_tokens": 900,
                },
            )
    except httpx.HTTPError:
        raise HTTPException(
            status_code=502, detail="Assistente IA indisponível no momento."
        )
    if response.status_code != 200:
        raise HTTPException(
            status_code=502,
            detail=f"OpenRouter respondeu {response.status_code}.",
        )
    data = response.json()
    content = (
        ((data.get("choices") or [{}])[0].get("message") or {})
        .get("content") or ""
    ).strip()
    return {"ok": True, "action": payload.action, "result": content}


# ---------------------------------------------------------------------------
# Operações: probes de dependências e backup sob demanda (somente admin)
# ---------------------------------------------------------------------------

# URL tailnet do próprio bridge (ex.: https://host.tailnet.ts.net:8443/health).
# Quando definida, /ops/status prova a cadeia completa Tailscale Serve.
SELF_HEALTH_URL = os.getenv("NERUDS_SELF_HEALTH_URL", "")


async def _probe_http(name: str, url: str, timeout: float = 5.0) -> dict[str, Any]:
    if not url:
        return {"name": name, "status": "skipped"}
    start = time.monotonic()
    try:
        async with httpx.AsyncClient(timeout=timeout, follow_redirects=False) as client:
            response = await client.get(url)
        return {
            "name": name,
            # Somente 200 é saudável: um 403/404 do portal também quebraria
            # o fluxo real de login — não pode ficar verde no painel.
            "ok": response.status_code == 200,
            "http_status": response.status_code,
            "duration_ms": round((time.monotonic() - start) * 1000, 1),
        }
    except Exception as exc:
        return {
            "name": name,
            "ok": False,
            "error": type(exc).__name__,
            "duration_ms": round((time.monotonic() - start) * 1000, 1),
        }


async def _probe_tcp(name: str, host: str, port: int, timeout: float = 5.0) -> dict[str, Any]:
    """Conexão TCP + banner do serviço. Para SMTP, saudável exige greeting
    220 — um socket aberto sem banner não sustentaria o fluxo de envio."""
    start = time.monotonic()
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(host, port), timeout
        )
        try:
            banner = await asyncio.wait_for(reader.readline(), timeout)
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass
        ok = banner.startswith(b"220")
        return {
            "name": name,
            "ok": ok,
            "error": None if ok else "smtp_banner_invalid",
            "duration_ms": round((time.monotonic() - start) * 1000, 1),
        }
    except Exception as exc:
        return {
            "name": name,
            "ok": False,
            "error": type(exc).__name__,
            "duration_ms": round((time.monotonic() - start) * 1000, 1),
        }


def _probe_db() -> dict[str, Any]:
    start = time.monotonic()
    try:
        ok = mission_store.check_ready()
        return {
            "name": "mission_db",
            "ok": ok,
            "duration_ms": round((time.monotonic() - start) * 1000, 1),
        }
    except Exception as exc:
        return {
            "name": "mission_db",
            "ok": False,
            "error": type(exc).__name__,
        }


@app.get("/ops/status")
async def ops_status(session: dict[str, Any] = Depends(require_session)) -> dict[str, Any]:
    _require_user_admin(session)
    portal, tailnet, mail, db = await asyncio.gather(
        _probe_http("drupal_portal", f"{PORTAL_URL}/user/login"),
        _probe_http("tailscale_serve", SELF_HEALTH_URL),
        _probe_tcp("posteio_smtp", SMTP_CONNECT_HOST, SMTP_PORT),
        asyncio.to_thread(_probe_db),
    )
    backups = mission_store.list_backups()
    return {
        "time": datetime.now(timezone.utc).isoformat(),
        "version": "0.6.0",
        "uptime_seconds": round(
            (datetime.now(timezone.utc) - _BRIDGE_STARTED_AT).total_seconds()
        ),
        "probes": [portal, tailnet, mail, db],
        "backup": {
            "keep": mission_store.backup_keep(),
            "count": len(backups),
            "latest": backups[0] if backups else None,
        },
    }


@app.post("/ops/backup")
async def ops_backup(session: dict[str, Any] = Depends(require_session)) -> dict[str, Any]:
    _require_user_admin(session)
    if not mission_store.check_ready():
        raise HTTPException(
            status_code=503,
            detail="Mission store ausente ou vazio — backup recusado.",
        )
    try:
        dest = await asyncio.to_thread(mission_store.backup_db)
    except Exception as exc:
        raise HTTPException(
            status_code=500, detail=f"Falha no backup: {type(exc).__name__}"
        ) from exc
    _access_log("backup_manual", file=dest.name)
    return {
        "ok": True,
        "file": dest.name,
        "size_bytes": dest.stat().st_size,
    }


@app.get("/ops/backups")
def ops_backups(session: dict[str, Any] = Depends(require_session)) -> dict[str, Any]:
    _require_user_admin(session)
    return {"backups": mission_store.list_backups()}


# Rate limit em memória para /auth/login: o bridge é público e cada tentativa
# bate no Drupal — sem teto, vira vetor de brute-force no portal.
_LOGIN_ATTEMPTS: dict[str, list[float]] = {}
LOGIN_RATE_MAX = int(os.getenv("NERUDS_LOGIN_RATE_MAX", "10"))
LOGIN_RATE_WINDOW = float(os.getenv("NERUDS_LOGIN_RATE_WINDOW_SECONDS", "300"))


def _client_ip(request: Request) -> str:
    cf_ip = request.headers.get("cf-connecting-ip", "").strip()
    if cf_ip:
        return cf_ip
    forwarded = request.headers.get("x-forwarded-for", "")
    if forwarded:
        return forwarded.split(",", 1)[0].strip()
    return request.client.host if request.client else "unknown"


def _enforce_login_rate(request: Request) -> None:
    ip = _client_ip(request)
    now = time.monotonic()
    attempts = [t for t in _LOGIN_ATTEMPTS.get(ip, []) if now - t < LOGIN_RATE_WINDOW]
    if len(attempts) >= LOGIN_RATE_MAX:
        raise HTTPException(
            status_code=429,
            detail="Muitas tentativas de login. Aguarde alguns minutos.",
        )
    attempts.append(now)
    _LOGIN_ATTEMPTS[ip] = attempts


@app.post("/auth/login")
async def login(payload: LoginRequest, request: Request) -> dict[str, Any]:
    _enforce_login_rate(request)
    async with httpx.AsyncClient(
        base_url=PORTAL_URL,
        timeout=15,
        follow_redirects=True,
        headers={"User-Agent": "NERUDS-Control-Center/0.2"},
    ) as client:
        form = await client.get("/user/login")
        form.raise_for_status()

        parser = HiddenInputParser()
        parser.feed(form.text)
        fields = parser.fields
        fields.update(
            {
                "name": payload.username,
                "pass": payload.password,
                "form_id": fields.get("form_id", "user_login_form"),
                "op": fields.get("op", "Entrar"),
            }
        )

        response = await client.post("/user/login", data=fields)
        body_lower = response.text.lower()
        still_login = (
            "user-login-form" in body_lower
            and (
                "/user/login" in str(response.url)
                or "unrecognized username or password" in body_lower
                or "nome de usuário" in body_lower
            )
        )
        if still_login:
            raise HTTPException(status_code=401, detail="Usuário ou senha Drupal inválidos.")

        probe = await client.get("/user", follow_redirects=False)
        location = probe.headers.get("location", "")
        if "/user/login" in location:
            raise HTTPException(status_code=401, detail="Drupal não confirmou a sessão.")

        csrf = await client.get("/session/token")
        csrf.raise_for_status()

        identity: dict[str, Any] = {}
        identity_response = await client.get("/neruds-control/session")
        if identity_response.status_code == 200:
            try:
                identity = identity_response.json()
            except ValueError:
                identity = {}

        token = secrets.token_urlsafe(32)
        SESSIONS[token] = {
            "username": payload.username,
            "uid": identity.get("uid"),
            "roles": identity.get("roles", []),
            "can_review": bool(identity.get("can_review", False)),
            "can_publish": bool(identity.get("can_publish", False)),
            "can_admin_users": bool(identity.get("can_admin_users", False)),
            "cookies": dict(client.cookies),
            "csrf": csrf.text.strip(),
            "created_at": datetime.now(timezone.utc).isoformat(),
            "last_seen": datetime.now(timezone.utc).isoformat(),
        }

        return {
            "token": token,
            "username": payload.username,
            "uid": identity.get("uid"),
            "roles": identity.get("roles", []),
            "can_review": bool(identity.get("can_review", False)),
            "can_publish": bool(identity.get("can_publish", False)),
            "can_admin_users": bool(identity.get("can_admin_users", False)),
            "drupal_user_location": location or str(response.url),
        }


@app.post("/auth/logout")
async def logout(
    authorization: str | None = Header(default=None),
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, bool]:
    token = bearer_token(authorization)
    try:
        async with drupal_client(session) as client:
            await client.get("/user/logout")
    finally:
        SESSIONS.pop(token, None)
    return {"ok": True}


@app.get("/auth/me")
async def me(session: dict[str, Any] = Depends(require_session)) -> dict[str, Any]:
    async with drupal_client(session, follow_redirects=False) as client:
        probe = await client.get("/user")
        return {
            "username": session["username"],
            "uid": session.get("uid"),
            "roles": session.get("roles", []),
            "can_review": bool(session.get("can_review", False)),
            "can_publish": bool(session.get("can_publish", False)),
            "can_admin_users": bool(session.get("can_admin_users", False)),
            "drupal_location": probe.headers.get("location", ""),
            "created_at": session["created_at"],
            "last_seen": session["last_seen"],
        }


@app.get("/portal/snapshot")
async def portal_snapshot() -> dict[str, Any]:
    async with httpx.AsyncClient(
        timeout=12,
        follow_redirects=True,
        headers={"User-Agent": "NERUDS-Control-Center/0.2"},
    ) as client:
        home = await client.get(f"{PORTAL_URL}/")
        home.raise_for_status()

        root = await client.get(f"{PORTAL_URL}/jsonapi")
        root.raise_for_status()
        root_json = root.json()

        content_types = sorted(
            key.removeprefix("node--")
            for key in root_json.get("links", {})
            if key.startswith("node--")
        )

        node_types = await client.get(
            f"{PORTAL_URL}/jsonapi/node_type/node_type",
            params={"page[limit]": 100},
        )
        labels: dict[str, str] = {}
        workflows: dict[str, str] = {}
        if node_types.status_code == 200:
            for item in node_types.json().get("data", []):
                attrs = item.get("attributes", {})
                bundle = attrs.get("drupal_internal__type")
                if not bundle:
                    continue
                labels[bundle] = attrs.get("name") or bundle
                third_party = attrs.get("third_party_settings") or {}
                workflow = (third_party.get("workflows") or {}).get("workflow")
                if workflow:
                    workflows[bundle] = workflow

        news = await client.get(
            f"{PORTAL_URL}/jsonapi/node/noticia",
            params={"sort": "-created", "page[limit]": 5},
        )
        latest_news = []
        if news.status_code == 200:
            for item in news.json().get("data", []):
                attrs = item.get("attributes", {})
                latest_news.append(
                    {
                        "id": item.get("id"),
                        "title": attrs.get("title", "Sem título"),
                        "created": attrs.get("created", ""),
                        "state": attrs.get("moderation_state", ""),
                        "published": attrs.get("status", False),
                        "public_url": _node_urls(
                            attrs.get("drupal_internal__nid"),
                            (attrs.get("path") or {}).get("alias"),
                        )["public_url"],
                    }
                )

        return {
            "online": True,
            "generator": home.headers.get("x-generator", "Drupal"),
            "portal_url": PORTAL_URL,
            "content_types": content_types,
            "content_type_labels": labels,
            "workflows": workflows,
            "latest_news": latest_news,
        }


# --- Real-structure read layer (issue #22) -------------------------------
# Everything below is read-only against the portal. Field names come from the
# versioned content_map, which was generated from the portal's real form
# displays — never inferred.
_PORTAL_READ_TTL = timedelta(seconds=int(os.getenv("NERUDS_PORTAL_CACHE_SECONDS", "300")))
_PORTAL_READ_CACHE: dict[str, tuple[datetime, Any]] = {}


def _portal_cache_get(key: str) -> Any | None:
    entry = _PORTAL_READ_CACHE.get(key)
    if not entry:
        return None
    expires, value = entry
    if datetime.now(timezone.utc) >= expires:
        _PORTAL_READ_CACHE.pop(key, None)
        return None
    return value


def _portal_cache_set(key: str, value: Any) -> Any:
    _PORTAL_READ_CACHE[key] = (
        datetime.now(timezone.utc) + _PORTAL_READ_TTL,
        value,
    )
    return value


async def _portal_nodes(
    client: httpx.AsyncClient,
    bundle: str,
    *,
    drafts: bool = False,
    owner: str = "",
) -> dict[str, Any]:
    """JSON:API items for a monitored bundle, cached with its fetch time.

    Draft-aware reads are cached per requesting user — unpublished
    visibility is per-session and must not cross accounts.
    """
    key = f"nodes:{bundle}:{owner}" if drafts else f"nodes:{bundle}"
    cached = _portal_cache_get(key)
    if cached is not None:
        return cached
    meta = content_map.MONITORED_TYPES[bundle]
    result = await _jsonapi_items(
        client, bundle, list(meta["fields"]), published_only=not drafts
    )
    result["fetched_at"] = datetime.now(timezone.utc).isoformat()
    return _portal_cache_set(key, result)


async def _jsonapi_items(
    client: httpx.AsyncClient,
    bundle: str,
    fields: list[str],
    *,
    published_only: bool = True,
    include: str | None = None,
) -> dict[str, Any]:
    """Fetch all JSON:API items for a bundle, following links.next."""
    sparse = "title,path,status,created,changed,drupal_internal__nid"
    for name in fields:
        sparse += f",{name}"
    params: dict[str, str] = {
        "fields[node--%s]" % bundle: sparse,
        "page[limit]": "50",
    }
    if published_only:
        params["filter[status]"] = "1"
    if include:
        params["include"] = include
    items: list[dict[str, Any]] = []
    included: list[dict[str, Any]] = []
    url: str | None = f"/jsonapi/node/{bundle}"
    req_params: dict[str, str] | None = params
    while url:
        response = await client.get(url, params=req_params)
        if response.status_code >= 400:
            raise HTTPException(
                status_code=response.status_code,
                detail=f"Drupal não autorizou a leitura de {bundle}.",
            )
        payload = response.json()
        items.extend(payload.get("data", []))
        included.extend(payload.get("included") or [])
        url = (payload.get("links") or {}).get("next", {}).get("href")
        req_params = None  # the next link already carries the query string
    return {"data": items, "included": included}


def _field_empty(item: dict[str, Any], name: str, kind: str) -> bool:
    """Whether a monitored field is empty in a JSON:API item."""
    if kind == "relationship":
        rel = (item.get("relationships") or {}).get(name) or {}
        data = rel.get("data")
        return data is None or data == []
    value = (item.get("attributes") or {}).get(name)
    if value is None:
        return True
    if isinstance(value, str):
        return not value.strip()
    if isinstance(value, dict):
        inner = value.get("uri") or value.get("value") or ""
        return not str(inner).strip()
    if isinstance(value, list):
        return not value
    return False


def _node_ref(item: dict[str, Any]) -> dict[str, Any]:
    attrs = item.get("attributes") or {}
    nid = attrs.get("drupal_internal__nid")
    path = attrs.get("path") or {}
    urls = _node_urls(nid, path.get("alias") if isinstance(path, dict) else None)
    return {
        "nid": nid,
        "title": attrs.get("title") or "Sem título",
        "view_url": urls["public_url"],
        "edit_url": urls["edit_url"],
        "published": bool(attrs.get("status")),
    }


def _term_names(included: list[dict[str, Any]]) -> dict[str, str]:
    """Map taxonomy term JSON:API ids to human names."""
    names: dict[str, str] = {}
    for term in included:
        if isinstance(term, dict) and term.get("type", "").startswith("taxonomy_term--"):
            names[str(term.get("id"))] = (term.get("attributes") or {}).get("name", "")
    return names


def _rel_term_names(
    item: dict[str, Any], field: str, names: dict[str, str]
) -> list[str]:
    rel = (item.get("relationships") or {}).get(field) or {}
    data = rel.get("data") or []
    if isinstance(data, dict):
        data = [data]
    return [names[str(t.get("id"))] for t in data if str(t.get("id")) in names]


@app.get("/portal/lacunas")
async def portal_lacunas(
    tipo: str | None = Query(default=None),
    campo: str | None = Query(default=None),
    limite_nodes: int = Query(default=20, ge=1, le=200),
    incluir_rascunhos: bool = Query(default=False),
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    """Compute real field gaps per monitored bundle via JSON:API."""
    if tipo and tipo not in content_map.MONITORED_TYPES:
        raise HTTPException(status_code=422, detail="Tipo não monitorado.")
    bundles = [tipo] if tipo else list(content_map.MONITORED_TYPES)
    if campo:
        if tipo and campo not in content_map.MONITORED_TYPES[tipo]["fields"]:
            raise HTTPException(
                status_code=422, detail="Campo não monitorado neste tipo."
            )
        if not tipo:
            bundles = [
                b
                for b in bundles
                if campo in content_map.MONITORED_TYPES[b]["fields"]
            ]
            if not bundles:
                raise HTTPException(
                    status_code=422, detail="Campo não monitorado em nenhum tipo."
                )
    async with drupal_client(session) as client:
        result_types = []
        fetched_ats: list[str] = []
        for bundle in bundles:
            meta = content_map.MONITORED_TYPES[bundle]
            fields = meta["fields"]
            if campo:
                fields = {campo: fields[campo]}
            cached = await _portal_nodes(
                client,
                bundle,
                drafts=incluir_rascunhos,
                owner=session["username"] if incluir_rascunhos else "",
            )
            fetched_ats.append(cached["fetched_at"])
            items = cached["data"]
            field_rows = []
            for fname, fmeta in fields.items():
                missing = [
                    _node_ref(item)
                    for item in items
                    if _field_empty(item, fname, fmeta["kind"])
                ]
                if missing:
                    field_rows.append(
                        {
                            "field": fname,
                            "label": fmeta["label"],
                            "kind": fmeta["kind"],
                            "missing": len(missing),
                            "nodes": missing[:limite_nodes],
                        }
                    )
            view_path = meta.get("view_path")
            result_types.append(
                {
                    "type": bundle,
                    "label": meta["label"],
                    "published": len(items),
                    "listing_url": f"{PORTAL_URL}{view_path}" if view_path else None,
                    "fields": field_rows,
                }
            )
    return {
        "fetched_at": min(fetched_ats) if fetched_ats else datetime.now(timezone.utc).isoformat(),
        "types": result_types,
    }


@app.get("/portal/eventos")
async def portal_eventos(
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    """Scientific events with real dates from evento_cientifico."""
    # Draft visibility is per-session (own/any unpublished permissions), so
    # the cache must be scoped to the requesting user.
    cache_key = f"ep:eventos:{session['username']}"
    cached = _portal_cache_get(cache_key)
    if cached is not None:
        return cached
    async with drupal_client(session) as client:
        # Monitoring needs drafts too — the portal currently has zero
        # published events. JSON:API already restricts unpublished content
        # to sessions whose role allows viewing it.
        fetched = await _jsonapi_items(
            client,
            "evento_cientifico",
            [
                "field_data_evento",
                "field_local_evento",
                "field_link_inscricao",
                "field_descricao_evento",
                "field_organizadores",
                # storage-level fields: not rendered in the default form,
                # but returned when they carry real values
                "field_chamada_trabalhos",
                "field_link_submissao",
            ],
            published_only=False,
        )
    today = datetime.now(timezone.utc).date()
    events = []
    for item in fetched["data"]:
        attrs = item.get("attributes") or {}
        ref = _node_ref(item)
        raw_date = attrs.get("field_data_evento")
        event_date = None
        if raw_date:
            try:
                event_date = datetime.fromisoformat(str(raw_date).replace("Z", "+00:00"))
            except ValueError:
                event_date = None
        link = attrs.get("field_link_inscricao") or {}
        submission = attrs.get("field_link_submissao") or {}
        events.append(
            {
                **ref,
                "published": attrs.get("status", True) is not False,
                "date": raw_date,
                "days_until": (event_date.date() - today).days if event_date else None,
                "past": bool(event_date and event_date.date() < today),
                "local": attrs.get("field_local_evento"),
                "organizers": attrs.get("field_organizadores"),
                "signup_url": link.get("uri") if isinstance(link, dict) else None,
                "call_open": bool(attrs.get("field_chamada_trabalhos")),
                "submission_url": (
                    submission.get("uri") if isinstance(submission, dict) else None
                ),
                "description": _readable_field(attrs.get("field_descricao_evento")),
            }
        )
    events.sort(key=lambda e: (e["past"], e["date"] or "9999"))
    return _portal_cache_set(
        cache_key,
        {
            "fetched_at": datetime.now(timezone.utc).isoformat(),
            "events": events,
            "listing_url": f"{PORTAL_URL}/eventos",
        },
    )


_SHORTLINK = re.compile(
    r'<link[^>]+rel="shortlink"[^>]+href="([^"]+)"', re.IGNORECASE
)
_SHORTLINK_ALT = re.compile(
    r'<link[^>]+href="([^"]+)"[^>]+rel="shortlink"', re.IGNORECASE
)


@app.get("/portal/nodes/{nid}/tipo")
async def portal_node_type(
    nid: int,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    """Resolve o tipo real do nó — o app usa para abrir edição/ficha
    diretamente sem perguntar o setor ao operador."""
    async with drupal_client(session) as client:
        for bundle in content_map.MONITORED_TYPES:
            response = await client.get(
                f"/jsonapi/node/{bundle}",
                params={
                    "filter[drupal_internal__nid]": nid,
                    "page[limit]": "1",
                },
            )
            if response.status_code == 200 and response.json().get("data"):
                return {"nid": nid, "type": bundle}
        # bundles gerenciáveis que a monitoração não cobre
        for bundle in manage_schema.MANAGE_SCHEMAS:
            if bundle in content_map.MONITORED_TYPES:
                continue
            response = await client.get(
                f"/jsonapi/node/{bundle}",
                params={
                    "filter[drupal_internal__nid]": nid,
                    "page[limit]": "1",
                },
            )
            if response.status_code == 200 and response.json().get("data"):
                return {"nid": nid, "type": bundle}
    raise HTTPException(status_code=404, detail="Registro não encontrado.")


@app.get("/portal/node-lookup")
async def portal_node_lookup(
    url: str = Query(min_length=1),
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    """Resolve a same-portal URL to its node — /node paths directly,
    Pathauto aliases via the page's shortlink or a redirect target."""
    path = _portal_url_path(url)
    if path is None:
        raise HTTPException(
            status_code=422,
            detail="O endereço informado não pertence ao portal configurado.",
        )
    direct = _PORTAL_NODE_PATH.match(path)
    if direct:
        nid = direct.group(1)
        return {
            "nid": nid,
            "public_url": f"{PORTAL_URL}/node/{nid}",
            "edit_url": f"{PORTAL_URL}/node/{nid}/edit",
        }
    async with drupal_client(session, follow_redirects=False) as client:
        # `path` is portal-relative; httpx appends it to base_url, which
        # already carries the configured portal base path.
        response = await client.get(path)
        # Follow redirects manually: every Location must stay inside the
        # configured portal, otherwise a redirect endpoint could drive the
        # bridge into fetching arbitrary internal/external hosts.
        redirects = 0
        while response.is_redirect:
            if redirects >= 5:
                raise HTTPException(
                    status_code=422,
                    detail="O endereço passou por redirecionamentos demais.",
                )
            target = urljoin(
                str(response.url), response.headers.get("location", "")
            )
            next_path = _portal_url_path(target)
            if next_path is None:
                raise HTTPException(
                    status_code=422,
                    detail="O endereço redireciona para fora do portal "
                    "configurado.",
                )
            response = await client.get(next_path)
            redirects += 1
    if response.status_code != 200:
        raise HTTPException(
            status_code=response.status_code,
            detail="O portal não respondeu a esta ficha.",
        )
    candidates = [str(response.url)]
    candidates.extend(
        _SHORTLINK.findall(response.text) + _SHORTLINK_ALT.findall(response.text)
    )
    for candidate in candidates:
        # Relative hrefs resolve against the fetched page URL, like a
        # browser would — not against the portal root.
        parts = _portal_node_parts(urljoin(str(response.url), candidate))
        if parts:
            nid = parts[0]
            return {
                "nid": nid,
                "public_url": f"{PORTAL_URL}/node/{nid}",
                "edit_url": f"{PORTAL_URL}/node/{nid}/edit",
            }
    raise HTTPException(
        status_code=422,
        detail="Este endereço do portal não identifica uma ficha /node.",
    )


@app.get("/portal/nodes/{nid}/lacunas")
async def portal_node_lacunas(
    nid: int,
    tipo: str = Query(min_length=1),
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    """Re-check the monitored fields of a single node — reconciliation
    must read the portal's current state, so this is never cached."""
    meta = content_map.MONITORED_TYPES.get(tipo)
    if meta is None:
        raise HTTPException(status_code=422, detail="Tipo não monitorado.")
    sparse = "title,path,status,drupal_internal__nid"
    for name in meta["fields"]:
        sparse += f",{name}"
    async with drupal_client(session) as client:
        response = await client.get(
            f"/jsonapi/node/{tipo}",
            params={
                "filter[drupal_internal__nid]": str(nid),
                "fields[node--%s]" % tipo: sparse,
                "page[limit]": "1",
            },
        )
        if response.status_code >= 400:
            raise HTTPException(
                status_code=502,
                detail="Drupal não respondeu à consulta da ficha.",
            )
        items = response.json().get("data") or []
        actual_type = None
        if not items:
            # The node may exist under another bundle — e.g. the task was
            # relinked to a node of a different monitored type. Probe all
            # bundles in parallel (serially this could take minutes of
            # upstream timeouts) and report the match so the UI does not
            # mistake a type mismatch for a deleted ficha.
            others = [
                other for other in content_map.MONITORED_TYPES if other != tipo
            ]
            probes = await asyncio.gather(
                *(
                    client.get(
                        f"/jsonapi/node/{other}",
                        params={
                            "filter[drupal_internal__nid]": str(nid),
                            f"fields[node--{other}]": "drupal_internal__nid",
                            "page[limit]": "1",
                        },
                    )
                    for other in others
                ),
                return_exceptions=True,
            )
            for other, probe in zip(others, probes):
                if (
                    isinstance(probe, httpx.Response)
                    and probe.status_code < 400
                    and probe.json().get("data")
                ):
                    actual_type = other
                    break
    if not items:
        result: dict[str, Any] = {
            "nid": nid,
            "type": tipo,
            "found": False,
            "missing_fields": [],
            "missing_labels": [],
        }
        if actual_type:
            result["actual_type"] = actual_type
        return result
    item = items[0]
    attrs = item.get("attributes") or {}
    missing = [
        (fname, fmeta["label"])
        for fname, fmeta in meta["fields"].items()
        if _field_empty(item, fname, fmeta["kind"])
    ]
    ref = _node_ref(item)
    return {
        "nid": attrs.get("drupal_internal__nid") or nid,
        "type": tipo,
        "found": True,
        "published": bool(attrs.get("status")),
        "title": ref["title"],
        "view_url": ref["view_url"],
        "edit_url": ref["edit_url"],
        "missing_fields": [name for name, _ in missing],
        "missing_labels": [label for _, label in missing],
    }


# Bundles whose storage has field_doi — the known shared-DOI case spans
# noticia, grupo_estudos, publicacao and publicacao_cientifica.
DOI_BUNDLES = (
    "grupo_estudos",
    "noticia",
    "publicacao",
    "publicacao_cientifica",
)


_DOI_SHAPE = re.compile(r"^10\.\d{4,9}/\S+$")


_DOI_PREFIXES = (
    "https://doi.org/",
    "http://doi.org/",
    "https://dx.doi.org/",
    "http://dx.doi.org/",
    "doi:",
    "doi ",
)


def _normalize_doi(value: Any) -> str:
    text = str(value or "").strip().lower()
    # Prefixes may stack ("DOI: https://doi.org/10.x/…") — keep stripping
    # until none of them match anymore.
    while True:
        stripped = text.strip()
        for prefix in _DOI_PREFIXES:
            if stripped.startswith(prefix):
                stripped = stripped[len(prefix):].strip()
                break
        if stripped == text:
            break
        text = stripped
    text = text.rstrip(".;,/")
    return text if _DOI_SHAPE.match(text) else ""


@app.get("/portal/duplicatas")
async def portal_duplicatas(
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    """Flag nodes sharing a DOI across bundles — a signal for human
    review only; the bridge never merges or deletes portal records."""
    # Field visibility is per-session (Drupal cookies), so the cache must
    # be scoped to the requesting user like the other portal reads.
    cache_key = f"portal:duplicatas:{session['username']}"
    cached = _portal_cache_get(cache_key)
    if cached is not None:
        return cached
    groups: dict[str, list[dict[str, Any]]] = {}
    async with drupal_client(session) as client:
        # Drafts reusing a DOI are the case worth flagging — JSON:API
        # already hides unpublished content the session cannot see.
        # Serially these reads could exceed the app's request timeout.
        scans = await asyncio.gather(
            *(
                _jsonapi_items(
                    client, bundle, ["field_doi"], published_only=False
                )
                for bundle in DOI_BUNDLES
            )
        )
        for bundle, fetched in zip(DOI_BUNDLES, scans):
            for item in fetched["data"]:
                attrs = item.get("attributes") or {}
                doi = _normalize_doi(attrs.get("field_doi"))
                if not doi:
                    continue
                ref = _node_ref(item)
                ref["type"] = bundle
                ref["type_label"] = content_map.MONITORED_TYPES.get(
                    bundle, {}
                ).get("label", bundle)
                groups.setdefault(doi, []).append(ref)
    duplicates = [
        {"doi": doi, "nodes": nodes}
        for doi, nodes in groups.items()
        if len(nodes) >= 2
    ]
    duplicates.sort(key=lambda group: -len(group["nodes"]))
    return _portal_cache_set(
        cache_key,
        {
            "fetched_at": datetime.now(timezone.utc).isoformat(),
            "groups": duplicates,
        },
    )


@app.get("/portal/projetos")
async def portal_projetos(
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    """Research/extension projects and extension actions with real fields."""
    cached = _portal_cache_get("ep:projetos")
    if cached is not None:
        return cached
    async with drupal_client(session) as client:
        projetos = await _jsonapi_items(
            client,
            "projeto_pesquisa_extensao",
            [
                "field_coordenador",
                "field_data_inicio",
                "field_data_fim",
                "field_resumo",
                "field_status_projeto",
                "field_tipo_projeto",
                "field_eixos_tematicos",
                "field_linhas_pesquisa",
                "field_ods_interesse",
            ],
            include=(
                "field_status_projeto,field_tipo_projeto,"
                "field_eixos_tematicos,field_linhas_pesquisa,"
                "field_ods_interesse"
            ),
        )
        acoes = await _jsonapi_items(
            client,
            "acao_extensionista",
            [
                "field_local_acao",
                "field_municipio",
                "field_tipo_acao",
                "field_numero_participantes",
            ],
            include="field_municipio,field_tipo_acao",
        )
    names = _term_names(projetos["included"] + acoes["included"])
    out_projetos = []
    for item in projetos["data"]:
        attrs = item.get("attributes") or {}
        out_projetos.append(
            {
                **_node_ref(item),
                "coordinator": attrs.get("field_coordenador"),
                "start": attrs.get("field_data_inicio"),
                "end": attrs.get("field_data_fim"),
                "summary": _readable_field(attrs.get("field_resumo")),
                "status": _rel_term_names(item, "field_status_projeto", names),
                "kind": _rel_term_names(item, "field_tipo_projeto", names),
                "eixos": _rel_term_names(item, "field_eixos_tematicos", names),
                "linhas_pesquisa": _rel_term_names(
                    item, "field_linhas_pesquisa", names
                ),
                "ods": _rel_term_names(item, "field_ods_interesse", names),
            }
        )
    out_acoes = []
    for item in acoes["data"]:
        attrs = item.get("attributes") or {}
        out_acoes.append(
            {
                **_node_ref(item),
                "local": attrs.get("field_local_acao"),
                "participants": attrs.get("field_numero_participantes"),
                "municipality": _rel_term_names(item, "field_municipio", names),
                "kind": _rel_term_names(item, "field_tipo_acao", names),
            }
        )
    return _portal_cache_set(
        "ep:projetos",
        {
            "fetched_at": datetime.now(timezone.utc).isoformat(),
            "projetos": out_projetos,
            "acoes": out_acoes,
            "listing_url": f"{PORTAL_URL}/projetos",
            "map_url": f"{PORTAL_URL}/mapa-projetos",
        },
    )


# The portal's own RSS views (/feed/noticias, /feed/eventos, ...) currently
# return HTTP 500. Until they are fixed portal-side, "what is new" is served
# from JSON:API — same data, guaranteed to exist.
_PORTAL_SECTION_TYPES = {
    "noticias": "noticia",
    "eventos": "evento_cientifico",
    "projetos": "projeto_pesquisa_extensao",
    "publicacoes": "publicacao_cientifica",
}


@app.get("/portal/feeds")
async def portal_feeds(
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    """Latest published items per section, via JSON:API sorted by -created."""
    cached = _portal_cache_get("ep:feeds")
    if cached is not None:
        return cached
    async with drupal_client(session) as client:
        sections: dict[str, Any] = {}
        for key, bundle in _PORTAL_SECTION_TYPES.items():
            try:
                response = await client.get(
                    f"/jsonapi/node/{bundle}",
                    params={
                        "fields[node--%s]" % bundle: "title,path,created,drupal_internal__nid",
                        "filter[status]": "1",
                        "sort": "-created",
                        "page[limit]": "10",
                    },
                )
            except httpx.RequestError:
                sections[key] = {"ok": False, "items": []}
                continue
            if response.status_code >= 400:
                sections[key] = {"ok": False, "items": []}
                continue
            items = []
            for item in response.json().get("data", []):
                ref = _node_ref(item)
                items.append(
                    {
                        "nid": ref["nid"],
                        "title": ref["title"],
                        "link": ref["view_url"],
                        "published": (item.get("attributes") or {}).get("created", ""),
                    }
                )
            sections[key] = {"ok": True, "items": items}
    result = {
        "fetched_at": datetime.now(timezone.utc).isoformat(),
        "sections": sections,
    }
    # Transient section failures are not cached — the next request retries them.
    if all(s["ok"] for s in sections.values()):
        _portal_cache_set("ep:feeds", result)
    return result


@app.get("/content/news/drafts")
async def news_drafts(
    status: str | None = Query(default=None),
    mine_only: bool = Query(default=False),
    query: str | None = Query(default=None),
    limit: int = Query(default=50, ge=1, le=200),
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    if status and status not in review_store.REVIEW_STATUSES:
        raise HTTPException(status_code=422, detail="Status de revisão inválido.")
    params: dict[str, str] | None = {"sort": "-changed", "page[limit]": "50"}
    if status:
        params["filter[status]"] = "1" if status == "published" else "0"
    async with drupal_client(session) as client:
        # Follow links.next collecting matching drafts up to `limit` — the
        # review filters below run after Drupal's publication filter, so a
        # raw page cap would undercount them. `truncated` means unexamined
        # items could still match.
        drafts: list[dict[str, Any]] = []
        truncated = False
        url: str | None = "/jsonapi/node/noticia"
        while url and not truncated:
            response = await client.get(url, params=params)
            if response.status_code >= 400:
                raise HTTPException(
                    status_code=response.status_code,
                    detail="Drupal não autorizou a leitura dos rascunhos.",
                )
            payload = response.json()
            url = (payload.get("links") or {}).get("next", {}).get("href")
            params = None  # the next link already carries the query string
            page_items = payload.get("data", [])
            for index, item in enumerate(page_items):
                draft = _news_queue_item(item, session)
                if status and draft["status"] != status:
                    continue
                if mine_only and not draft["is_owner"]:
                    continue
                if query and query.strip():
                    needle = query.strip().casefold()
                    title = draft["title"].casefold()
                    author = (draft["review"] or {}).get("author", "").casefold()
                    if needle not in title and needle not in author:
                        continue
                drafts.append(draft)
                if len(drafts) >= limit:
                    truncated = url is not None or index < len(page_items) - 1
                    break
        return {
            "items": drafts,
            "truncated": truncated,
            "can_review": bool(session.get("can_review", False)),
            "can_publish": bool(session.get("can_publish", False)),
        }


@app.post("/content/news/draft")
async def create_news_draft(
    payload: NewsDraftRequest,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    created = await _create_news_draft_internal(
        title=payload.title,
        summary=payload.summary,
        body=payload.body,
        publication_date=payload.publication_date,
        session=session,
        opportunity_item_id=payload.opportunity_item_id,
        mission_task_id=payload.mission_task_id,
    )
    notification = await notify_review(payload.title, session["username"])
    return {
        "ok": True,
        "id": created.get("id"),
        "type": created.get("type"),
        "title": payload.title,
        "published": False,
        "notification": notification,
        "public_url": created.get("public_url"),
        "edit_url": created.get("edit_url"),
        "owner_uid": created.get("owner_uid"),
        "is_owner": created.get("is_owner", False),
    }


async def _create_access_map(session: dict[str, Any]) -> dict[str, bool]:
    """Quais bundles a sessão pode criar — decidido pelo próprio Drupal.

    Cache de 10 min por token: montar a lista custa um GET por tipo."""
    token = session.get("token") or ""
    now = time.monotonic()
    cached = _CREATE_ACCESS_CACHE.get(token)
    if cached and now - cached[0] < _CREATE_ACCESS_TTL:
        return cached[1]
    access: dict[str, bool] = {}
    # Probe cobre criáveis clássicos + todos os bundles gerenciáveis —
    # antes só CONTENT_BUNDLES era testado e schemas gerenciáveis
    # (ex.: perfil_pesquisador) apareciam como não-criáveis.
    probed = list(dict.fromkeys(
        [*CONTENT_BUNDLES, *manage_schema.MANAGE_SCHEMAS]
    ))
    async with drupal_client(session) as client:
        headers = {"Content-Type": "application/vnd.api+json"}
        if session.get("csrf"):
            headers["X-CSRF-Token"] = session["csrf"]
        for bundle in probed:
            # /node/add/{bundle} é rota admin — 403 até para quem tem
            # 'create {bundle} content'. POST vazio na JSON:API distingue
            # permissão: 403 = sem create; 400/422 = pode criar mas a
            # validação reprovou o payload vazio.
            try:
                probe = await client.post(
                    f"/jsonapi/node/{bundle}",
                    json={"data": {"type": f"node--{bundle}", "attributes": {}}},
                    headers=headers,
                )
                access[bundle] = probe.status_code != 403
            except Exception:
                access[bundle] = False
    _CREATE_ACCESS_CACHE[token] = (now, access)
    return access


@app.get("/content/types")
async def content_types(
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    """Tipos de conteúdo que a sessão pode criar, com metadados do formulário."""
    access = await _create_access_map(session)
    types = [
        {
            "bundle": bundle,
            "label": meta["label"],
            "required": meta["required"],
        }
        for bundle, meta in CONTENT_BUNDLES.items()
        if access.get(bundle)
    ]
    return {"types": types}


@app.post("/content/{bundle}/draft")
async def create_bundle_draft(
    bundle: str,
    payload: ContentDraftRequest,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    meta = CONTENT_BUNDLES.get(bundle)
    if meta is None:
        raise HTTPException(status_code=404, detail="Tipo de conteúdo não suportado.")

    missing = [
        spec["label"]
        for spec in meta["required"]
        if not (getattr(payload, spec["key"], None) or "").strip()
    ]
    if missing:
        raise HTTPException(
            status_code=422,
            detail=f"Campos obrigatórios de {meta['label']}: {', '.join(missing)}.",
        )
    access = await _create_access_map(session)
    if not access.get(bundle):
        raise HTTPException(
            status_code=403,
            detail=f"Esta conta não pode criar {meta['label']} no portal.",
        )

    extras = {
        spec["drupal"]: (getattr(payload, spec["key"], None) or "").strip()
        for spec in meta["required"]
    }
    if bundle == "noticia":
        extras.setdefault(
            "field_data_noticia[0][value][date]",
            payload.data or datetime.now().date().isoformat(),
        )
    body = payload.body.strip() or (payload.summary.strip() or payload.title)
    created = await _create_bundle_draft_internal(
        bundle,
        title=payload.title,
        summary=payload.summary,
        body=body,
        extras=extras,
        session=session,
        opportunity_item_id=payload.opportunity_item_id,
        mission_task_id=payload.mission_task_id,
    )
    notification = await notify_review(payload.title, session["username"])
    return {
        "ok": True,
        "id": created.get("id"),
        "bundle": bundle,
        "type": created.get("type"),
        "title": payload.title,
        "published": False,
        "notification": notification,
        "public_url": created.get("public_url"),
        "edit_url": created.get("edit_url"),
        "owner_uid": created.get("owner_uid"),
        "is_owner": created.get("is_owner", False),
    }


# ---------------------------------------------------------------------------
# Gateway de gestão genérico (/manage) — schema-driven, ver manage_schema.py.
# ---------------------------------------------------------------------------

_JSONAPI_TYPES = {"Content-Type": "application/vnd.api+json",
                  "Accept": "application/vnd.api+json"}


def _manage_schema_or_404(bundle: str) -> dict[str, Any]:
    schema = manage_schema.schema_for(bundle)
    if schema is None:
        raise HTTPException(status_code=404, detail="Setor não suportado.")
    return schema


def _jsonapi_write_headers(session: dict[str, Any]) -> dict[str, str]:
    headers = dict(_JSONAPI_TYPES)
    if session.get("csrf"):
        headers["X-CSRF-Token"] = session["csrf"]
    return headers


def _entity_ref_type(target: str) -> tuple[str, str]:
    """'node:perfil_pesquisador' -> ('node', 'perfil_pesquisador')."""
    entity, _, bundle = (target or "").partition(":")
    return entity or "node", bundle


async def _resolve_ref_uuid(
    client: httpx.AsyncClient, target: str, raw_id: Any
) -> dict[str, str] | None:
    """Resolve um id numérico (nid/tid) ou uuid para o item JSON:API."""
    entity, bundle = _entity_ref_type(target)
    if isinstance(raw_id, dict) and raw_id.get("id"):
        return {
            "type": f"{entity}--{bundle}",
            "id": str(raw_id["id"]),
        }
    raw = str(raw_id or "").strip()
    if not raw:
        return None
    if not raw.isdecimal():
        return {"type": f"{entity}--{bundle}", "id": raw}
    if entity == "node":
        response = await client.get(
            f"/jsonapi/node/{bundle}",
            params={
                "filter[drupal_internal__nid]": raw,
                "page[limit]": "1",
            },
        )
    else:
        response = await client.get(
            f"/jsonapi/taxonomy_term/{bundle}",
            params={
                "filter[drupal_internal__tid]": raw,
                "page[limit]": "1",
            },
        )
    if response.status_code != 200:
        return None
    data = response.json().get("data") or []
    if not data:
        return None
    return {"type": f"{entity}--{bundle}", "id": data[0]["id"]}


async def _node_uuid(client: httpx.AsyncClient, bundle: str, nid: int) -> str:
    response = await client.get(
        f"/jsonapi/node/{bundle}",
        params={
            "filter[drupal_internal__nid]": nid,
            "page[limit]": "1",
        },
    )
    if response.status_code != 200:
        raise HTTPException(
            status_code=response.status_code,
            detail="Drupal não respondeu à consulta do registro.",
        )
    data = response.json().get("data") or []
    if not data:
        raise HTTPException(status_code=404, detail="Registro não encontrado.")
    return data[0]["id"]


async def _build_node_payload(
    bundle: str,
    values: dict[str, Any],
    client: httpx.AsyncClient,
    *,
    uuid: str | None = None,
) -> dict[str, Any]:
    schema = _manage_schema_or_404(bundle)
    attrs: dict[str, Any] = {}
    rels: dict[str, Any] = {}
    for spec in schema["fields"]:
        name = spec["name"]
        if name not in values:
            continue
        value = values[name]
        if value is None or (isinstance(value, str) and not value.strip()):
            continue
        kind = spec["kind"]
        if kind == "reference":
            items = value if isinstance(value, list) else [value]
            refs = []
            for item in items:
                ref = await _resolve_ref_uuid(client, spec.get("target", ""), item)
                if ref:
                    refs.append(ref)
            rels[name] = {"data": refs if spec.get("multiple") else (refs[0] if refs else None)}
        elif kind in ("image", "file"):
            items = value if isinstance(value, list) else [value]
            refs = [
                {"type": "file--file", "id": str(item["id"] if isinstance(item, dict) else item)}
                for item in items
            ]
            rels[name] = {"data": refs if spec.get("multiple") else (refs[0] if refs else None)}
        elif kind == "link":
            attrs[name] = {"uri": value if isinstance(value, str) else value.get("uri", "")}
        elif kind == "longtext":
            if isinstance(value, dict):
                attrs[name] = value
            else:
                attrs[name] = {"value": value, "format": "plain_text"}
        elif kind == "daterange":
            period = value if isinstance(value, dict) else {}
            attrs[name] = {
                "value": period.get("start") or None,
                "end_value": period.get("end") or None,
            }
        elif kind == "number":
            attrs[name] = int(value)
        elif kind == "bool":
            attrs[name] = bool(value)
        else:
            attrs[name] = value
    data: dict[str, Any] = {"type": f"node--{bundle}", "attributes": attrs}
    if rels:
        data["relationships"] = rels
    if uuid:
        data["id"] = uuid
    return {"data": data}


def _manage_item(item: dict[str, Any]) -> dict[str, Any]:
    attrs = item.get("attributes", {})
    return {
        "nid": attrs.get("drupal_internal__nid"),
        "uuid": item.get("id"),
        "title": attrs.get("title") or "(sem título)",
        "status": bool(attrs.get("status")),
        "changed": attrs.get("changed"),
    }


@app.get("/manage/schemas")
async def manage_schemas(
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    """Schemas dos setores + o que a sessão pode criar (Drupal decide)."""
    access = await _create_access_map(session)
    return {
        "schemas": {
            bundle: {
                "label": schema["label"],
                "label_singular": schema["label_singular"],
                "icon": schema["icon"],
                "fields": schema["fields"],
                "steps": schema.get("steps", []),
            }
            for bundle, schema in manage_schema.MANAGE_SCHEMAS.items()
            if bundle in manage_schema.MANAGE_SCHEMAS
        },
        "can_create": {
            bundle: bool(access.get(bundle))
            for bundle in manage_schema.MANAGE_SCHEMAS
        },
    }


@app.get("/manage/options/{entity}/{target}")
async def manage_options(
    entity: str,
    target: str,
    limit: int = 50,
    search: str | None = None,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    """Opções para campos de referência (dropdowns dinâmicos no app)."""
    if entity == "node" and target not in manage_schema.MANAGE_SCHEMAS:
        raise HTTPException(status_code=404, detail="Tipo de referência não suportado.")
    limit = max(1, min(limit, 100))
    async with drupal_client(session) as client:
        if entity == "node":
            params: dict[str, Any] = {
                "page[limit]": str(limit),
                "filter[status]": "1",
                "sort": "title",
                f"fields[node--{target}]": "title,drupal_internal__nid",
            }
            if search:
                params["filter[title][operator]"] = "CONTAINS"
                params["filter[title][value]"] = search
            response = await client.get(f"/jsonapi/node/{target}", params=params)
            if response.status_code != 200:
                raise HTTPException(status_code=response.status_code,
                                    detail="Consulta de opções recusada.")
            return {
                "options": [
                    {
                        "id": it.get("attributes", {}).get("drupal_internal__nid"),
                        "uuid": it.get("id"),
                        "label": it.get("attributes", {}).get("title") or "",
                    }
                    for it in response.json().get("data", [])
                ]
            }
        if entity == "taxonomy_term":
            params = {
                "page[limit]": str(limit),
                "sort": "name",
                f"fields[taxonomy_term--{target}]": "name,drupal_internal__tid",
            }
            if search:
                params["filter[name][operator]"] = "CONTAINS"
                params["filter[name][value]"] = search
            response = await client.get(
                f"/jsonapi/taxonomy_term/{target}", params=params
            )
            if response.status_code != 200:
                raise HTTPException(status_code=response.status_code,
                                    detail="Consulta de opções recusada.")
            return {
                "options": [
                    {
                        "id": it.get("attributes", {}).get("drupal_internal__tid"),
                        "uuid": it.get("id"),
                        "label": it.get("attributes", {}).get("name") or "",
                    }
                    for it in response.json().get("data", [])
                ]
            }
    raise HTTPException(status_code=404, detail="Tipo de referência não suportado.")


# --- Taxonomia: CRUD de termos por vocabulário -------------------------------


def _vocab_or_404(vocab: str) -> dict[str, str]:
    meta = manage_schema.TAXONOMY_VOCABS.get(vocab)
    if meta is None:
        raise HTTPException(status_code=404, detail="Vocabulário não suportado.")
    return meta


def _term_item(item: dict[str, Any]) -> dict[str, Any]:
    attrs = item.get("attributes", {})
    tid = attrs.get("drupal_internal__tid")
    return {
        "tid": tid,
        # ManageItem genérico do app lê "nid" — termos reaproveitam o shape.
        "nid": tid,
        "uuid": item.get("id"),
        "title": attrs.get("name") or "(sem nome)",
        "status": True,
        "changed": attrs.get("changed"),
    }


async def _term_uuid(client: httpx.AsyncClient, vocab: str, tid: int) -> str:
    response = await client.get(
        f"/jsonapi/taxonomy_term/{vocab}",
        params={
            "filter[drupal_internal__tid]": tid,
            "page[limit]": "1",
        },
    )
    if response.status_code != 200:
        raise HTTPException(status_code=response.status_code,
                            detail="Drupal não respondeu à consulta do termo.")
    data = response.json().get("data") or []
    if not data:
        raise HTTPException(status_code=404, detail="Termo não encontrado.")
    return data[0]["id"]


async def _build_term_payload(
    vocab: str,
    values: dict[str, Any],
    client: httpx.AsyncClient,
    *,
    uuid: str | None = None,
) -> dict[str, Any]:
    attrs: dict[str, Any] = {}
    rels: dict[str, Any] = {}
    if values.get("name"):
        attrs["name"] = str(values["name"]).strip()
    if values.get("description") not in (None, ""):
        desc = values["description"]
        attrs["description"] = (
            desc if isinstance(desc, dict)
            else {"value": desc, "format": "plain_text"}
        )
    if values.get("weight") not in (None, ""):
        attrs["weight"] = int(values["weight"])
    if values.get("parent") not in (None, ""):
        ref = await _resolve_ref_uuid(
            client, f"taxonomy_term:{vocab}", values["parent"]
        )
        rels["parent"] = {"data": ref}
    data: dict[str, Any] = {
        "type": f"taxonomy_term--{vocab}", "attributes": attrs
    }
    if rels:
        data["relationships"] = rels
    if uuid:
        data["id"] = uuid
    return {"data": data}


@app.get("/manage/taxonomy")
async def manage_vocabularies(
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    return {
        "vocabularies": [
            {"vid": vid, "label": meta["label"]}
            for vid, meta in manage_schema.TAXONOMY_VOCABS.items()
        ]
    }


@app.get("/manage/taxonomy/{vocab}")
async def manage_terms(
    vocab: str,
    search: str | None = None,
    limit: int = 50,
    offset: int = 0,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    _vocab_or_404(vocab)
    limit = max(1, min(limit, 100))
    params: dict[str, Any] = {
        "page[limit]": str(limit),
        "page[offset]": str(max(0, offset)),
        "sort": "weight,name",
    }
    if search:
        params["filter[name][operator]"] = "CONTAINS"
        params["filter[name][value]"] = search
    async with drupal_client(session) as client:
        response = await client.get(
            f"/jsonapi/taxonomy_term/{vocab}", params=params
        )
    if response.status_code != 200:
        raise HTTPException(status_code=response.status_code,
                            detail="Consulta ao vocabulário recusada.")
    data = response.json()
    return {
        "items": [_term_item(it) for it in data.get("data", [])],
        "has_next": bool((data.get("links") or {}).get("next")),
        "offset": offset,
        "limit": limit,
    }


@app.post("/manage/taxonomy/{vocab}")
async def manage_term_create(
    vocab: str,
    payload: dict[str, Any] = Body(default={}),
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    _vocab_or_404(vocab)
    values = payload.get("values") or {}
    if not str(values.get("name") or "").strip():
        raise HTTPException(status_code=422, detail="Informe o nome do termo.")
    async with drupal_client(session) as client:
        body = await _build_term_payload(vocab, values, client)
        response = await client.post(
            f"/jsonapi/taxonomy_term/{vocab}",
            json=body,
            headers=_jsonapi_write_headers(session),
        )
    if response.status_code not in (200, 201):
        raise HTTPException(
            status_code=response.status_code if response.status_code >= 400 else 422,
            detail={"message": "Portal recusou a criação do termo.",
                    "response": response.text[:600]},
        )
    return {"ok": True, **_term_item(response.json().get("data") or {})}


@app.patch("/manage/taxonomy/{vocab}/{tid}")
async def manage_term_update(
    vocab: str,
    tid: int,
    payload: dict[str, Any] = Body(default={}),
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    _vocab_or_404(vocab)
    async with drupal_client(session) as client:
        uuid = await _term_uuid(client, vocab, tid)
        body = await _build_term_payload(
            vocab, payload.get("values") or {}, client, uuid=uuid
        )
        response = await client.patch(
            f"/jsonapi/taxonomy_term/{vocab}/{uuid}",
            json=body,
            headers=_jsonapi_write_headers(session),
        )
    if response.status_code != 200:
        raise HTTPException(
            status_code=response.status_code if response.status_code >= 400 else 422,
            detail={"message": "Portal recusou a atualização do termo.",
                    "response": response.text[:600]},
        )
    return {"ok": True, **_term_item(response.json().get("data") or {})}


@app.delete("/manage/taxonomy/{vocab}/{tid}")
async def manage_term_delete(
    vocab: str,
    tid: int,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    _vocab_or_404(vocab)
    async with drupal_client(session) as client:
        uuid = await _term_uuid(client, vocab, tid)
        response = await client.delete(
            f"/jsonapi/taxonomy_term/{vocab}/{uuid}",
            headers={"X-CSRF-Token": session.get("csrf") or ""},
        )
    if response.status_code != 204:
        raise HTTPException(status_code=response.status_code,
                            detail="Portal recusou excluir o termo.")
    return {"ok": True, "tid": tid, "deleted": True}


# --- Moderação: fila unificada de aprovação ----------------------------------


@app.get("/manage/moderation/pending")
async def manage_moderation_pending(
    bundle: str | None = None,
    limit_per_bundle: int = 10,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    """Rascunhos pendentes por setor — o JSON:API já filtra o que a conta
    pode enxergar (extensionista vê só os próprios; coordenação vê tudo)."""
    if not session.get("can_review") and not session.get("can_publish") \
            and "coordenador" not in (session.get("roles") or []):
        raise HTTPException(
            status_code=403,
            detail="Esta conta não tem permissão de revisão.",
        )
    bundles = [bundle] if bundle else list(manage_schema.MANAGE_SCHEMAS)
    limit = max(1, min(limit_per_bundle, 50))
    items: list[dict[str, Any]] = []
    async with drupal_client(session) as client:
        for b in bundles:
            if b not in manage_schema.MANAGE_SCHEMAS:
                raise HTTPException(status_code=404,
                                    detail="Setor não suportado.")
            response = await client.get(
                f"/jsonapi/node/{b}",
                params={
                    "filter[status]": "0",
                    "page[limit]": str(limit),
                    "sort": "changed",
                },
            )
            if response.status_code != 200:
                continue
            for it in response.json().get("data", []):
                items.append({
                    "bundle": b,
                    "bundle_label":
                        manage_schema.MANAGE_SCHEMAS[b]["label_singular"],
                    **_manage_item(it),
                })
    return {"items": items}


@app.post("/manage/moderation/{bundle}/{nid}/approve")
async def manage_moderation_approve(
    bundle: str,
    nid: int,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    """Publica o rascunho — o Drupal decide se a conta pode (403 repassado)."""
    _manage_schema_or_404(bundle)
    async with drupal_client(session) as client:
        uuid = await _node_uuid(client, bundle, nid)
        response = await client.patch(
            f"/jsonapi/node/{bundle}/{uuid}",
            json={
                "data": {
                    "type": f"node--{bundle}",
                    "id": uuid,
                    "attributes": {"status": True},
                }
            },
            headers=_jsonapi_write_headers(session),
        )
    if response.status_code != 200:
        raise HTTPException(
            status_code=response.status_code,
            detail={
                "message": "Portal recusou a publicação.",
                "response": response.text[:600],
            },
        )
    return {
        "ok": True,
        **_manage_item(response.json().get("data") or {}),
        "approved": True,
    }


# --- Usuários e papéis (access control) --------------------------------------


def _user_item(item: dict[str, Any], included: list | None = None) -> dict[str, Any]:
    attrs = item.get("attributes", {})
    roles_data = (
        (item.get("relationships", {}).get("roles") or {}).get("data") or []
    )
    return {
        "uid": attrs.get("drupal_internal__uid"),
        "uuid": item.get("id"),
        "name": attrs.get("name"),
        "mail": attrs.get("mail"),
        "status": bool(attrs.get("status")),
        "roles": [r.get("id") for r in roles_data if r.get("id")],
        "changed": attrs.get("changed"),
    }


@app.get("/manage/users/roles")
async def manage_user_roles(
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    async with drupal_client(session) as client:
        response = await client.get("/jsonapi/user_role/user_role")
    if response.status_code != 200:
        raise HTTPException(status_code=response.status_code,
                            detail="Consulta de papéis recusada.")
    return {
        "roles": [
            {
                "id": it.get("id"),
                "label": (it.get("attributes") or {}).get("label")
                or it.get("id"),
            }
            for it in response.json().get("data", [])
        ]
    }


@app.get("/manage/users")
async def manage_users_list(
    search: str | None = None,
    status: str | None = None,
    limit: int = 50,
    offset: int = 0,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    limit = max(1, min(limit, 100))
    params: dict[str, Any] = {
        "page[limit]": str(limit),
        "page[offset]": str(max(0, offset)),
        "sort": "created",
    }
    if search:
        params["filter[name][operator]"] = "CONTAINS"
        params["filter[name][value]"] = search
    if status == "active":
        params["filter[status]"] = "1"
    elif status == "blocked":
        params["filter[status]"] = "0"
    async with drupal_client(session) as client:
        response = await client.get("/jsonapi/user/user", params=params)
    if response.status_code != 200:
        raise HTTPException(status_code=response.status_code,
                            detail="Consulta de usuários recusada.")
    data = response.json()
    return {
        "items": [_user_item(it) for it in data.get("data", [])],
        "has_next": bool((data.get("links") or {}).get("next")),
    }


async def _user_uuid(client: httpx.AsyncClient, uid: int) -> str:
    response = await client.get(
        "/jsonapi/user/user",
        params={"filter[drupal_internal__uid]": uid, "page[limit]": "1"},
    )
    if response.status_code != 200:
        raise HTTPException(status_code=response.status_code,
                            detail="Drupal não respondeu à consulta do usuário.")
    data = response.json().get("data") or []
    if not data:
        raise HTTPException(status_code=404, detail="Usuário não encontrado.")
    return data[0]["id"]


@app.patch("/manage/users/{uid}")
async def manage_user_update(
    uid: int,
    payload: dict[str, Any] = Body(default={}),
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    attrs: dict[str, Any] = {}
    for key in ("name", "mail"):
        if payload.get(key) not in (None, ""):
            attrs[key] = payload[key]
    if payload.get("status") is not None:
        attrs["status"] = bool(payload["status"])
    rels: dict[str, Any] = {}
    if payload.get("roles") is not None:
        rels["roles"] = {
            "data": [
                {"type": "user_role--user_role", "id": str(r)}
                for r in payload["roles"]
            ]
        }
    async with drupal_client(session) as client:
        uuid = await _user_uuid(client, uid)
        data: dict[str, Any] = {"type": "user--user", "id": uuid,
                                "attributes": attrs}
        if rels:
            data["relationships"] = rels
        response = await client.patch(
            f"/jsonapi/user/user/{uuid}",
            json={"data": data},
            headers=_jsonapi_write_headers(session),
        )
    if response.status_code != 200:
        raise HTTPException(
            status_code=response.status_code if response.status_code >= 400 else 422,
            detail={"message": "Portal recusou a atualização do usuário.",
                    "response": response.text[:600]},
        )
    return {"ok": True, **_user_item(response.json().get("data") or {})}


# --- Biblioteca de mídia (media entities) ------------------------------------

MEDIA_TYPES = {"image": "field_media_image",
               "document": "field_media_document"}


@app.get("/manage/media/{media_type}")
async def manage_media_list(
    media_type: str,
    search: str | None = None,
    limit: int = 30,
    offset: int = 0,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    field = MEDIA_TYPES.get(media_type)
    if field is None:
        raise HTTPException(status_code=404, detail="Tipo de mídia não suportado.")
    limit = max(1, min(limit, 100))
    params: dict[str, Any] = {
        "page[limit]": str(limit),
        "page[offset]": str(max(0, offset)),
        "sort": "-created",
        "include": field,
    }
    if search:
        params["filter[name][operator]"] = "CONTAINS"
        params["filter[name][value]"] = search
    async with drupal_client(session) as client:
        response = await client.get(f"/jsonapi/media/{media_type}", params=params)
    if response.status_code != 200:
        raise HTTPException(status_code=response.status_code,
                            detail="Consulta à biblioteca recusada.")
    data = response.json()
    files = {
        it.get("id"): it
        for it in data.get("included", [])
        if it.get("type") == "file--file"
    }
    items = []
    for it in data.get("data", []):
        attrs = it.get("attributes", {})
        file_uuid = (
            (it.get("relationships", {}).get(field) or {}).get("data") or {}
        ).get("id")
        file_entity = files.get(file_uuid) or {}
        file_uri = (file_entity.get("attributes") or {}).get("uri") or {}
        items.append({
            "uuid": it.get("id"),
            "mid": attrs.get("drupal_internal__mid"),
            "name": attrs.get("name"),
            "file_uuid": file_uuid,
            "file_url": file_uri.get("url"),
        })
    return {"items": items}


@app.post("/manage/media/{media_type}")
async def manage_media_create(
    media_type: str,
    payload: dict[str, Any] = Body(default={}),
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    """Cria a entidade media a partir do uuid de arquivo já enviado."""
    field = MEDIA_TYPES.get(media_type)
    if field is None:
        raise HTTPException(status_code=404, detail="Tipo de mídia não suportado.")
    values = payload.get("values") or {}
    name = str(values.get("name") or "").strip()
    file_uuid = str(values.get("file_uuid") or "").strip()
    if not name or not file_uuid:
        raise HTTPException(status_code=422,
                            detail="Informe name e file_uuid.")
    body = {
        "data": {
            "type": f"media--{media_type}",
            "attributes": {"name": name, "status": True},
            "relationships": {
                field: {"data": {"type": "file--file", "id": file_uuid}}
            },
        }
    }
    async with drupal_client(session) as client:
        response = await client.post(
            f"/jsonapi/media/{media_type}",
            json=body,
            headers=_jsonapi_write_headers(session),
        )
    if response.status_code not in (200, 201):
        raise HTTPException(
            status_code=response.status_code,
            detail={"message": "Portal recusou a criação da mídia.",
                    "response": response.text[:600]},
        )
    data = response.json().get("data") or {}
    return {"ok": True, "uuid": data.get("id"), "name": name}


@app.post("/manage/media/{media_type}/files")
async def manage_media_upload(
    media_type: str,
    request: Request,
    filename: str,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    """Upload direto para o campo da media — devolve o uuid do arquivo."""
    field = MEDIA_TYPES.get(media_type)
    if field is None:
        raise HTTPException(status_code=404, detail="Tipo de mídia não suportado.")
    content = await request.body()
    if not content:
        raise HTTPException(status_code=422, detail="Arquivo vazio.")
    async with drupal_client(session) as client:
        response = await client.post(
            f"/jsonapi/media/{media_type}/{field}",
            content=content,
            headers={
                "X-CSRF-Token": session.get("csrf") or "",
                "Content-Type": "application/octet-stream",
                "Content-Disposition": f'attachment; filename="{filename}"',
                "Accept": "application/vnd.api+json",
            },
        )
    if response.status_code not in (200, 201):
        raise HTTPException(
            status_code=response.status_code,
            detail={"message": "Upload recusado pelo portal.",
                    "response": response.text[:600]},
        )
    data = response.json().get("data") or {}
    return {"ok": True, "id": data.get("id"), "name": filename}


@app.get("/manage/{bundle}")
async def manage_list(
    bundle: str,
    status: str | None = None,
    search: str | None = None,
    rel: str | None = None,
    rel_id: str | None = None,
    limit: int = 20,
    offset: int = 0,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    _manage_schema_or_404(bundle)
    limit = max(1, min(limit, 50))
    params: dict[str, Any] = {
        "page[limit]": str(limit),
        "page[offset]": str(max(0, offset)),
        "sort": "-changed",
    }
    if status == "published":
        params["filter[status]"] = "1"
    elif status == "draft":
        params["filter[status]"] = "0"
    if search:
        params["filter[title][operator]"] = "CONTAINS"
        params["filter[title][value]"] = search
    if rel and rel_id:
        params[f"filter[{rel}.id]"] = rel_id
    async with drupal_client(session) as client:
        response = await client.get(f"/jsonapi/node/{bundle}", params=params)
    if response.status_code != 200:
        raise HTTPException(
            status_code=response.status_code,
            detail="Consulta ao setor recusada pelo portal.",
        )
    data = response.json()
    items = [_manage_item(it) for it in data.get("data", [])]
    has_next = bool((data.get("links") or {}).get("next"))
    return {"items": items, "has_next": has_next, "offset": offset, "limit": limit}


@app.get("/manage/{bundle}/{nid}")
async def manage_detail(
    bundle: str,
    nid: int,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    schema = _manage_schema_or_404(bundle)
    field_names = ",".join(
        [f["name"] for f in schema["fields"]] + ["status", "changed"]
    )
    async with drupal_client(session) as client:
        uuid = await _node_uuid(client, bundle, nid)
        response = await client.get(
            f"/jsonapi/node/{bundle}/{uuid}",
            params={f"fields[node--{bundle}]": field_names},
        )
    if response.status_code != 200:
        raise HTTPException(status_code=response.status_code,
                            detail="Registro não acessível.")
    item = response.json().get("data") or {}
    result = _manage_item(item)
    result["values"] = item.get("attributes", {})
    result["relationships"] = item.get("relationships", {})
    return result


@app.post("/manage/{bundle}")
async def manage_create(
    bundle: str,
    payload: dict[str, Any] = Body(default={}),
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    _manage_schema_or_404(bundle)
    access = await _create_access_map(session)
    if not access.get(bundle):
        raise HTTPException(
            status_code=403,
            detail="Esta conta não pode criar itens neste setor.",
        )
    values = payload.get("values") or {}
    if not payload.get("published"):
        # Via formulário nativo: nasce rascunho (status=0) e entra na fila
        # de revisão — o guard do Drupal limita status no JSON:API.
        created = await _create_bundle_draft_internal(
            bundle,
            title=str(values.get("title") or ""),
            summary=str(values.get("field_resumo_noticia") or ""),
            body=str(values.get("body") or ""),
            extras={
                (
                    f"{f['name']}[0][value][date]"
                    if f["kind"] == "date"
                    else f"{f['name']}[0][uri]"
                    if f["kind"] == "link"
                    else f"{f['name']}[0][value]"
                ): str(values[f["name"]])
                for f in (_manage_schema_or_404(bundle)["fields"])
                if f["kind"] in ("text", "date", "number", "email", "link")
                and f["name"] != "title"
                and f["name"].startswith("field_")
                and values.get(f["name"]) not in (None, "")
            },
            session=session,
        )
        return {
            "ok": True,
            "nid": int(created.get("drupal_internal_nid") or 0),
            "uuid": created.get("jsonapi_id") or "",
            "title": created.get("title") or values.get("title") or "",
            "status": False,
        }
    async with drupal_client(session) as client:
        body = await _build_node_payload(bundle, values, client)
        body["data"]["attributes"]["status"] = True
        response = await client.post(
            f"/jsonapi/node/{bundle}",
            json=body,
            headers=_jsonapi_write_headers(session),
        )
    if response.status_code not in (200, 201):
        raise HTTPException(
            status_code=response.status_code if response.status_code >= 400 else 422,
            detail={
                "message": "Portal recusou a criação do registro.",
                "response": response.text[:800],
            },
        )
    data = response.json().get("data") or {}
    return {"ok": True, **_manage_item(data)}


def _strip_longtext_formats(body: dict[str, Any]) -> bool:
    """Remove a chave `format` de campos texto longo — sem ela o Drupal
    mantém o formato que já estava no registro. Retorna True se mudou."""
    attrs = (body.get("data") or {}).get("attributes") or {}
    changed = False
    for name, value in list(attrs.items()):
        if isinstance(value, dict) and "format" in value:
            attrs[name] = {k: v for k, v in value.items() if k != "format"}
            changed = True
    return changed


@app.patch("/manage/{bundle}/{nid}")
async def manage_update(
    bundle: str,
    nid: int,
    payload: dict[str, Any] = Body(default={}),
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    _manage_schema_or_404(bundle)
    async with drupal_client(session) as client:
        uuid = await _node_uuid(client, bundle, nid)
        body = await _build_node_payload(
            bundle, payload.get("values") or {}, client, uuid=uuid
        )
        if "published" in payload:
            body["data"]["attributes"]["status"] = bool(payload["published"])
        response = await client.patch(
            f"/jsonapi/node/{bundle}/{uuid}",
            json=body,
            headers=_jsonapi_write_headers(session),
        )
        if (
            response.status_code == 422
            and 'format' in response.text
            and _strip_longtext_formats(body)
        ):
            # A conta não pode usar o formato pedido (ex.: basic_html) —
            # retenta deixando o Drupal preservar o formato existente.
            response = await client.patch(
                f"/jsonapi/node/{bundle}/{uuid}",
                json=body,
                headers=_jsonapi_write_headers(session),
            )
    if response.status_code != 200:
        raise HTTPException(
            status_code=response.status_code if response.status_code >= 400 else 422,
            detail={
                "message": "Portal recusou a atualização do registro.",
                "response": response.text[:800],
            },
        )
    data = response.json().get("data") or {}
    return {"ok": True, **_manage_item(data)}


@app.delete("/manage/{bundle}/{nid}")
async def manage_delete(
    bundle: str,
    nid: int,
    hard: bool = False,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    """Despublica por padrão; ?hard=1 remove de fato (Drupal decide a permissão)."""
    _manage_schema_or_404(bundle)
    async with drupal_client(session) as client:
        uuid = await _node_uuid(client, bundle, nid)
        if not hard:
            response = await client.patch(
                f"/jsonapi/node/{bundle}/{uuid}",
                json={
                    "data": {
                        "type": f"node--{bundle}",
                        "id": uuid,
                        "attributes": {"status": False},
                    }
                },
                headers=_jsonapi_write_headers(session),
            )
            if response.status_code != 200:
                raise HTTPException(
                    status_code=response.status_code,
                    detail="Portal recusou despublicar o registro.",
                )
            return {"ok": True, "nid": nid, "published": False}
        response = await client.delete(
            f"/jsonapi/node/{bundle}/{uuid}",
            headers={"X-CSRF-Token": session.get("csrf") or ""},
        )
    if response.status_code != 204:
        raise HTTPException(
            status_code=response.status_code,
            detail="Portal recusou excluir o registro.",
        )
    return {"ok": True, "nid": nid, "deleted": True}


@app.post("/manage/{bundle}/files/{field}")
async def manage_upload_file(
    bundle: str,
    field: str,
    request: Request,
    filename: str,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    """Upload binário para campo file/image — devolve o uuid do arquivo."""
    _manage_schema_or_404(bundle)
    spec = manage_schema.spec_for(bundle, field)
    if spec is None or spec.get("kind") not in ("file", "image"):
        raise HTTPException(status_code=404, detail="Campo de arquivo não suportado.")
    content = await request.body()
    if not content:
        raise HTTPException(status_code=422, detail="Arquivo vazio.")
    async with drupal_client(session) as client:
        response = await client.post(
            f"/jsonapi/node/{bundle}/{field}",
            content=content,
            headers={
                "X-CSRF-Token": session.get("csrf") or "",
                "Content-Type": "application/octet-stream",
                "Content-Disposition": f'attachment; filename="{filename}"',
                "Accept": "application/vnd.api+json",
            },
        )
    if response.status_code not in (200, 201):
        raise HTTPException(
            status_code=response.status_code,
            detail={"message": "Upload recusado pelo portal.",
                    "response": response.text[:600]},
        )
    data = response.json().get("data") or {}
    return {
        "ok": True,
        "id": data.get("id"),
        "name": filename,
        "url": ((data.get("attributes") or {}).get("uri") or {}).get("url"),
    }


@app.patch("/content/news/drafts/{nid}/review")
async def review_news_draft(
    nid: int,
    payload: DraftReviewDecision,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    current = review_store.get_review(str(nid))
    if not current:
        raise HTTPException(status_code=404, detail="Rascunho não registrado para revisão.")

    if payload.status in {"approved", "changes_requested"}:
        if not session.get("can_review", False):
            raise HTTPException(
                status_code=403,
                detail="Sua conta não tem permissão para revisar notícias.",
            )
    elif payload.status == "pending":
        if not session.get("can_review", False):
            observed = await _authorized_news_item(nid, session)
            if not observed["is_owner"]:
                raise HTTPException(
                    status_code=403,
                    detail="Sua conta não tem permissão para reenviar o rascunho de terceiros.",
                )
    else:
        raise HTTPException(status_code=422, detail="Status de revisão inválido.")

    if payload.status == "changes_requested" and not (payload.note or "").strip():
        raise HTTPException(
            status_code=422,
            detail="Informe o que precisa ser ajustado antes de devolver.",
        )

    try:
        review = review_store.decide(
            str(nid),
            actor=session["username"],
            status=payload.status,
            note=(payload.note or "").strip() or None,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))

    return {"ok": True, "review": review}


@app.post("/content/news/drafts/{nid}/publish")
async def publish_news_draft(
    nid: int,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    if not session.get("can_publish", False):
        raise HTTPException(
            status_code=403,
            detail="Sua conta não tem permissão para publicar notícias.",
        )

    review = review_store.get_review(str(nid))
    if not review:
        raise HTTPException(status_code=404, detail="Rascunho não registrado para revisão.")
    if review.get("review_status") != "approved":
        raise HTTPException(
            status_code=409,
            detail="O rascunho precisa estar aprovado antes da publicação.",
        )

    async with drupal_client(session) as client:
        response = await client.post(
            f"/neruds-control/news/{nid}/publish",
            headers={
                "X-CSRF-Token": session["csrf"],
                "Accept": "application/json",
            },
            follow_redirects=False,
        )
        if response.status_code >= 400:
            try:
                detail: Any = response.json()
            except ValueError:
                detail = response.text[:1200]
            raise HTTPException(
                status_code=response.status_code,
                detail={
                    "message": "Drupal recusou a publicação.",
                    "drupal": detail,
                },
            )
        result = response.json()

    review = review_store.mark_published(str(nid), session["username"])
    return {
        "ok": True,
        "nid": nid,
        "published": bool(result.get("published", True)),
        "review": review,
    }


@app.get("/mail/status")
async def mail_status(session: dict[str, Any] = Depends(require_session)) -> dict[str, Any]:
    port_open = await asyncio.to_thread(tcp_reachable, SMTP_CONNECT_HOST, SMTP_PORT, 2.0)
    tls_ok = False
    tls_error = None

    def _probe_tls() -> None:
        context = ssl.create_default_context()
        with smtplib.SMTP(SMTP_CONNECT_HOST, SMTP_PORT, timeout=8) as smtp:
            if SMTP_CONNECT_HOST != SMTP_HOST:
                smtp._host = SMTP_HOST
            smtp.ehlo()
            if SMTP_STARTTLS:
                smtp.starttls(context=context)
                smtp.ehlo()

    if port_open:
        try:
            await asyncio.to_thread(_probe_tls)
            tls_ok = True
        except Exception as exc:
            tls_error = exc.__class__.__name__

    return {
        "host": SMTP_HOST,
        "connect_host": SMTP_CONNECT_HOST,
        "port": SMTP_PORT,
        "starttls": SMTP_STARTTLS,
        "port_open": port_open,
        "tls_ok": tls_ok,
        "tls_error": tls_error,
        "credentials_configured": bool(SMTP_USER and SMTP_PASSWORD),
        "review_recipient_configured": bool(SMTP_REVIEW_TO),
    }


@app.get("/infra/status")
def infra_status() -> dict[str, Any]:
    ssh = tcp_reachable(VPS_TAILSCALE_HOST, 22)
    http = tcp_reachable(VPS_TAILSCALE_HOST, 80)
    https = tcp_reachable(VPS_TAILSCALE_HOST, 443)

    tailscale_available = False
    tailscale_self = None
    try:
        proc = subprocess.run(
            ["tailscale", "status", "--json"],
            check=False,
            capture_output=True,
            text=True,
            timeout=4,
        )
        tailscale_available = proc.returncode == 0
        if tailscale_available:
            data = json.loads(proc.stdout)
            tailscale_self = data.get("Self", {}).get("HostName")
    except (OSError, subprocess.SubprocessError, ValueError):
        pass

    return {
        "tailscale_available": tailscale_available,
        "tailscale_self": tailscale_self,
        "vps_host": VPS_TAILSCALE_HOST,
        "vps_ports": {"ssh": ssh, "http": http, "https": https},
        "vps_reachable": ssh or http or https,
    }


# ---------------------------------------------------------------------------
# Missão operacional baseada na planilha TREINAMENTO_NERUDS_Gestao_e_Preenchimento
# ---------------------------------------------------------------------------

@app.get("/missions")
def missions(session: dict[str, Any] = Depends(require_session)) -> list[dict[str, Any]]:
    return mission_store.mission_list()


@app.get("/missions/{mission_id}/dashboard")
def mission_dashboard(
    mission_id: int,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    try:
        return mission_store.dashboard(mission_id)
    except KeyError:
        raise HTTPException(status_code=404, detail="Missão não encontrada.")


@app.get("/missions/{mission_id}/tasks")
def mission_tasks(
    mission_id: int,
    stage: str | None = None,
    priority: str | None = None,
    owner: str | None = None,
    content_type: str | None = None,
    due_status: str | None = Query(default=None, pattern="^(overdue|upcoming)$"),
    q: str | None = None,
    limit: int = Query(default=100, ge=1, le=500),
    offset: int = Query(default=0, ge=0),
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    return mission_store.list_tasks(
        mission_id,
        stage=stage,
        priority=priority,
        owner=owner,
        content_type=content_type,
        query=q,
        due_status=due_status,
        limit=limit,
        offset=offset,
    )


@app.get("/missions/{mission_id}/saved-filters")
def mission_saved_filters(
    mission_id: int,
    session: dict[str, Any] = Depends(require_session),
) -> list[dict[str, Any]]:
    return mission_store.list_saved_filters(mission_id, session["username"])


@app.post("/missions/{mission_id}/saved-filters")
def mission_saved_filter_create(
    mission_id: int,
    payload: SavedMissionFilterCreate,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    try:
        return mission_store.save_filter(
            mission_id,
            session["username"],
            payload.name,
            payload.filters,
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="Missão não encontrada.")
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))


@app.delete("/missions/{mission_id}/saved-filters/{filter_id}")
def mission_saved_filter_delete(
    mission_id: int,
    filter_id: int,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, bool]:
    try:
        mission_store.delete_saved_filter(mission_id, filter_id, session["username"])
    except KeyError:
        raise HTTPException(status_code=404, detail="Filtro salvo não encontrado.")
    return {"ok": True}


@app.get("/missions/{mission_id}/weekly-report")
def mission_weekly_report(
    mission_id: int,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    try:
        return mission_store.weekly_report(mission_id)
    except KeyError:
        raise HTTPException(status_code=404, detail="Missão não encontrada.")


@app.get("/missions/{mission_id}/export.xlsx")
def mission_export_xlsx(
    mission_id: int,
    session: dict[str, Any] = Depends(require_session),
) -> StreamingResponse:
    try:
        content = mission_store.export_tasks_xlsx(mission_id)
    except KeyError:
        raise HTTPException(status_code=404, detail="Missão não encontrada.")
    return StreamingResponse(
        io.BytesIO(content),
        media_type=(
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        ),
        headers={
            "Content-Disposition": (
                f'attachment; filename="missao-neruds-{mission_id}-controle-master.xlsx"'
            )
        },
    )


@app.get("/mission-tasks/{task_id}")
def mission_task_detail(
    task_id: int,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    try:
        return mission_store.task_detail(task_id)
    except KeyError:
        raise HTTPException(status_code=404, detail="Tarefa não encontrada.")


CONTROLLED_ASSIGNMENT_FIELDS = {
    "primary_owner",
    "cross_reviewer",
    "internal_deadline",
}


def _require_review_for_controlled(
    changes: dict[str, Any], session: dict[str, Any]
) -> None:
    # `responsible` is the effective owner when primary_owner is unset —
    # normalize whitespace so the stored value matches what was
    # authorized, regardless of who sends it.
    if "responsible" in changes:
        changes["responsible"] = (changes["responsible"] or "").strip()
    if session.get("can_review", False):
        return
    if CONTROLLED_ASSIGNMENT_FIELDS.intersection(changes):
        raise HTTPException(
            status_code=403,
            detail=(
                "Somente perfis de revisão/coordenação podem alterar "
                "responsável, revisor cruzado ou prazo interno."
            ),
        )
    # A non-reviewer may only ever self-assign — clearing or renaming the
    # owner on someone else's task needs review rights.
    if "responsible" in changes and (
        changes["responsible"] != session["username"]
    ):
        raise HTTPException(
            status_code=403,
            detail=(
                "Sem perfil de revisão, a tarefa só pode ser atribuída "
                "ao próprio usuário."
            ),
        )


def _canonical_link_fields(changes: dict[str, Any]) -> None:
    """Validate portal ficha links in *changes* and rewrite them to the
    canonical /node/N spelling. The node-pair check itself stays inside the
    store transaction so a concurrent write cannot interleave."""
    for link_field, require_edit in (("public_url", False), ("edit_url", True)):
        if link_field in changes and not _portal_node_link(
            changes[link_field], require_edit=require_edit
        ):
            raise HTTPException(
                status_code=422,
                detail=(
                    "O endereço precisa apontar para uma ficha /node "
                    "do portal configurado."
                ),
            )
    # Canonicalize accepted spellings (/node/N/, query strings, ...) so
    # equivalent links never look like a relink to the store.
    for link_field, suffix in (("public_url", ""), ("edit_url", "/edit")):
        if link_field in changes:
            nid = _portal_node_nid(changes[link_field])
            changes[link_field] = f"{PORTAL_URL}/node/{nid}{suffix}"


@app.post("/missions/{mission_id}/tasks", status_code=201)
def mission_task_create(
    mission_id: int,
    payload: MissionTaskCreate,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    fields = payload.model_dump(exclude_none=True, exclude={"note"})
    _require_review_for_controlled(fields, session)
    _canonical_link_fields(fields)

    if fields.get("gap_bundle"):
        meta = content_map.MONITORED_TYPES.get(fields["gap_bundle"])
        if meta is None:
            raise HTTPException(status_code=422, detail="Tipo não monitorado.")
        if not fields.get("gap_fields"):
            raise HTTPException(
                status_code=422,
                detail="Tarefa de lacuna exige os campos faltantes "
                "registrados.",
            )
        unknown = [
            f for f in fields["gap_fields"] if f not in meta["fields"]
        ]
        if unknown:
            raise HTTPException(
                status_code=422, detail="Campo não monitorado neste tipo."
            )
        fields.setdefault("content_type", meta["label"])
    elif fields.get("gap_fields"):
        raise HTTPException(
            status_code=422,
            detail="Campos de lacuna exigem o tipo da ficha.",
        )

    try:
        return mission_store.create_task(
            mission_id,
            actor=session["username"],
            fields=fields,
            note=payload.note,
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="Missão não encontrada.")
    except ValueError:
        raise HTTPException(
            status_code=422,
            detail="Os endereços público e de edição devem apontar "
            "para a mesma ficha.",
        )


@app.patch("/mission-tasks/{task_id}")
def mission_task_update(
    task_id: int,
    payload: MissionTaskPatch,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    changes = payload.model_dump(
        exclude_none=True,
        exclude={"note", "evidence_url"},
    )
    _require_review_for_controlled(changes, session)
    _canonical_link_fields(changes)
    # When both links change they must reference the same node — the pair
    # check itself runs inside update_task's transaction so a concurrent
    # PATCH cannot interleave between this validation and the write.
    # Stage validity is checked there too, against the mission's own
    # workflow (which may differ from the global WORKFLOW).
    try:
        return mission_store.update_task(
            task_id,
            actor=session["username"],
            changes=changes,
            note=payload.note,
            evidence_url=payload.evidence_url,
            actor_can_review=session.get("can_review", False),
        )
    except PermissionError:
        raise HTTPException(
            status_code=403,
            detail=(
                "Sem perfil de revisão, a tarefa só pode ser atribuída "
                "ao próprio usuário."
            ),
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="Tarefa não encontrada.")
    except ValueError as exc:
        detail = (
            "O endereço salvo usa um alias sem nid. Envie os "
            "dois endereços da nova ficha para revincular."
            if str(exc) == "link_alias_unresolvable"
            else "Etapa da missão inválida."
            if str(exc) == "invalid_stage"
            else "Os endereços público e de edição devem apontar "
            "para a mesma ficha."
        )
        raise HTTPException(status_code=422, detail=detail)


@app.patch("/mission-tasks/{task_id}/checklists/{kind}/{item_order}")
def mission_checklist_update(
    task_id: int,
    kind: str,
    item_order: int,
    payload: ChecklistPatch,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    try:
        return mission_store.set_check_result(
            task_id,
            kind=kind,
            item_order=item_order,
            completed=payload.completed,
            actor=session["username"],
            note=payload.note,
        )
    except KeyError as exc:
        detail = (
            "Item de checklist não encontrado."
            if "checklist" in str(exc)
            else "Tarefa não encontrada."
        )
        raise HTTPException(status_code=404, detail=detail)


EVIDENCE_MAX_BYTES = 10 * 1024 * 1024


@app.post("/mission-tasks/{task_id}/evidence-files", status_code=201)
async def mission_evidence_upload(
    task_id: int,
    file: UploadFile = File(...),
    note: str | None = Form(default=None),
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    content = await file.read()
    if not content:
        raise HTTPException(status_code=422, detail="Arquivo vazio.")
    if len(content) > EVIDENCE_MAX_BYTES:
        raise HTTPException(status_code=413, detail="Arquivo excede 10 MB.")
    try:
        item = mission_store.add_evidence_file(
            task_id,
            actor=session["username"],
            filename=file.filename or "evidence.bin",
            content=content,
            content_type=file.content_type,
            note=note,
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="Tarefa não encontrada.")
    return {"evidence": item}


@app.get("/mission-tasks/{task_id}/evidence-files")
def mission_evidence_list(
    task_id: int,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    try:
        mission_store.task_detail(task_id)
    except KeyError:
        raise HTTPException(status_code=404, detail="Tarefa não encontrada.")
    return {"files": mission_store.list_evidence_files(task_id)}


@app.get("/mission-evidence/{evidence_id}")
def mission_evidence_download(
    evidence_id: int,
    session: dict[str, Any] = Depends(require_session),
) -> FileResponse:
    try:
        meta = mission_store.get_evidence_file(evidence_id)
        path = mission_store.evidence_file_path(evidence_id)
    except KeyError:
        raise HTTPException(status_code=404, detail="Evidência não encontrada.")
    except FileNotFoundError:
        raise HTTPException(status_code=410, detail="Arquivo de evidência indisponível.")
    return FileResponse(
        path,
        media_type=meta.get("content_type") or "application/octet-stream",
        filename=meta["filename"],
    )


@app.get("/missions/{mission_id}/references")
def mission_reference_list(
    mission_id: int,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    try:
        mission_store.dashboard(mission_id)
    except KeyError:
        raise HTTPException(status_code=404, detail="Missão não encontrada.")
    return {"sections": mission_store.list_references()}


@app.get("/missions/{mission_id}/references/{section}")
def mission_reference(
    mission_id: int,
    section: str,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    try:
        mission_store.dashboard(mission_id)
        return {"section": section, "items": mission_store.get_reference(section)}
    except KeyError:
        raise HTTPException(status_code=404, detail="Referência não encontrada.")


# ---------------------------------------------------------------------------
# Automação da missão: sugestões e sinais (nunca conclui tarefa sozinho)
# ---------------------------------------------------------------------------

@app.get("/missions/{mission_id}/automation")
def mission_automation_summary(
    mission_id: int,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    try:
        return mission_automation.summary(mission_id)
    except KeyError:
        raise HTTPException(status_code=404, detail="Missão não encontrada.")


@app.post("/missions/{mission_id}/url-check")
def mission_url_check(
    mission_id: int,
    limit: int = Query(
        default=mission_automation.DEFAULT_URL_CHECK_LIMIT,
        ge=1,
        le=mission_automation.MAX_URL_CHECK_LIMIT,
    ),
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    try:
        result = mission_automation.check_public_urls(mission_id, limit=limit)
    except KeyError:
        raise HTTPException(status_code=404, detail="Missão não encontrada.")
    result["summary"] = mission_automation.url_check_summary(mission_id)
    return result


@app.get("/mission-tasks/{task_id}/drupal-duplicates")
async def mission_task_drupal_duplicates(
    task_id: int,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    try:
        task = mission_store.task_detail(task_id)
    except KeyError:
        raise HTTPException(status_code=404, detail="Tarefa não encontrada.")

    bundle = task.get("gap_bundle") or mission_automation.CONTENT_TYPE_BUNDLES.get(
        (task.get("content_type") or "").strip()
    )
    title = (task.get("title") or "").strip()
    linked_nid = _portal_node_nid(task.get("public_url") or "") or _portal_node_nid(
        task.get("edit_url") or ""
    )
    if not bundle or not title:
        return {"task_id": task_id, "bundle": bundle, "matches": []}

    matches = []
    async with drupal_client(session) as client:
        if linked_nid is not None:
            # Gap tasks are titled "Completar ficha — <node title>"; the
            # duplicate search must use the linked node's real title.
            response = await client.get(
                f"/jsonapi/node/{bundle}",
                params={
                    "filter[drupal_internal__nid]": linked_nid,
                    "page[limit]": 1,
                },
            )
            if response.status_code < 400:
                data = response.json().get("data", [])
                if data:
                    node_title = (
                        data[0].get("attributes", {}).get("title") or ""
                    ).strip()
                    if node_title:
                        title = node_title
        response = await client.get(
            f"/jsonapi/node/{bundle}",
            params={"filter[title]": title, "page[limit]": 20},
        )
        if response.status_code >= 400:
            raise HTTPException(
                status_code=502,
                detail="Drupal não respondeu à consulta de duplicidade.",
            )
        for item in response.json().get("data", []):
            attrs = item.get("attributes", {})
            nid = attrs.get("drupal_internal__nid")
            if linked_nid is not None and str(nid) == str(linked_nid):
                continue
            matches.append(
                {
                    "nid": nid,
                    "uuid": item.get("id"),
                    "title": attrs.get("title", ""),
                    "published": bool(attrs.get("status", False)),
                    "path": (attrs.get("path") or {}).get("alias"),
                }
            )
    return {"task_id": task_id, "bundle": bundle, "matches": matches}


# ---------------------------------------------------------------------------
# Identidade e ciclo de vida de extensionistas (Onda 5)
# ---------------------------------------------------------------------------

CLOSED_STAGES = {"Concluído", "Bloqueado"}


def _require_user_admin(session: dict[str, Any]) -> None:
    if not session.get("can_admin_users", False):
        raise HTTPException(
            status_code=403,
            detail=(
                "Gerenciar contas de extensionista requer a permissão "
                "'administer neruds extensionistas' no Drupal."
            ),
        )


async def _extensionista_call(
    session: dict[str, Any],
    method: str,
    path: str,
    payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    headers = {"Accept": "application/json"}
    if method != "GET":
        headers["X-CSRF-Token"] = session["csrf"]
        headers["Content-Type"] = "application/json"
    async with drupal_client(session) as client:
        response = await client.request(method, path, headers=headers, json=payload)
    if response.status_code >= 400:
        try:
            detail: Any = response.json()
        except ValueError:
            detail = response.text[:1200]
        raise HTTPException(
            status_code=response.status_code,
            detail={
                "message": "Drupal recusou a operação de identidade.",
                "drupal": detail,
            },
        )
    return response.json()


def _open_tasks_for(username: str) -> list[dict[str, Any]]:
    # Gap tasks can be created on any mission — check them all, and page
    # through instead of silently missing tasks past the 500-row page.
    items: list[dict[str, Any]] = []
    for mission in mission_store.mission_list():
        offset = 0
        while True:
            page = mission_store.list_tasks(
                mission["id"], owner=username, limit=500, offset=offset
            )["items"]
            items.extend(page)
            if len(page) < 500:
                break
            offset += 500
    return [t for t in items if t.get("current_stage") not in CLOSED_STAGES]


def _sync_identity_account(
    drupal_account: dict[str, Any], *, actor: str
) -> dict[str, Any]:
    record = identity_store.upsert_account(
        drupal_account["name"],
        drupal_uid=drupal_account.get("uid"),
        mail=drupal_account.get("mail"),
        active=drupal_account.get("active"),
    )
    return record


@app.get("/identity/roster")
async def identity_roster(
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    _require_user_admin(session)
    result = await _extensionista_call(session, "GET", "/neruds-control/extensionistas")
    accounts = result.get("accounts", [])
    known = {a["username"]: a for a in identity_store.list_accounts()}
    for account in accounts:
        name = account.get("name") or ""
        record = known.get(name)
        account["open_tasks"] = len(_open_tasks_for(name))
        account["bridge_record"] = record
        account["offboarding"] = (
            identity_store.offboarding_progress(record["id"]) if record else None
        )
    return {"accounts": accounts, "actor": session["username"]}


@app.post("/identity/accounts", status_code=201)
async def identity_account_create(
    payload: IdentityAccountCreate,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    _require_user_admin(session)
    body: dict[str, Any] = {"name": payload.name.strip(), "mail": payload.mail.strip()}
    if payload.password:
        body["pass"] = payload.password
    result = await _extensionista_call(
        session, "POST", "/neruds-control/extensionistas", body
    )
    record = _sync_identity_account(result, actor=session["username"])
    identity_store.record_event(
        session["username"],
        "provisioned",
        account_id=record["id"],
        username=record["username"],
        detail={"mail": record.get("mail"), "drupal_uid": record.get("drupal_uid")},
    )
    return {"account": record, "drupal": result}


@app.post("/identity/accounts/{uid}/status")
async def identity_account_status(
    uid: int,
    payload: IdentityStatusPatch,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    _require_user_admin(session)
    result = await _extensionista_call(
        session,
        "POST",
        f"/neruds-control/extensionistas/{uid}/status",
        {"active": payload.active},
    )
    record = _sync_identity_account(result, actor=session["username"])
    identity_store.record_event(
        session["username"],
        "activated" if payload.active else "blocked",
        account_id=record["id"],
        username=record["username"],
        detail={"drupal_uid": uid},
    )
    return {"account": record, "drupal": result}


@app.post("/identity/accounts/{uid}/password-reset")
async def identity_password_reset(
    uid: int,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    _require_user_admin(session)
    result = await _extensionista_call(
        session, "POST", f"/neruds-control/extensionistas/{uid}/password-reset"
    )
    record = identity_store.get_account_by_uid(uid)
    identity_store.record_event(
        session["username"],
        "password_reset_issued",
        account_id=record["id"] if record else None,
        username=result.get("name"),
        detail={"drupal_uid": uid},
    )
    # O link de reset é entregue apenas nesta resposta; nunca é persistido.
    return result


@app.get("/identity/accounts/{uid}/checklist")
def identity_checklist(
    uid: int,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    _require_user_admin(session)
    record = identity_store.get_account_by_uid(uid)
    if not record:
        raise HTTPException(
            status_code=404, detail="Conta não sincronizada no bridge."
        )
    return identity_store.offboarding_progress(record["id"])


@app.post("/identity/accounts/{uid}/checklist")
def identity_checklist_update(
    uid: int,
    payload: IdentityCheckPatch,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    _require_user_admin(session)
    record = identity_store.get_account_by_uid(uid)
    if not record:
        raise HTTPException(
            status_code=404, detail="Conta não sincronizada no bridge."
        )
    try:
        item = identity_store.set_check(
            record["id"], payload.step, payload.done, session["username"]
        )
    except KeyError:
        raise HTTPException(status_code=422, detail="Etapa de offboarding inválida.")
    identity_store.record_event(
        session["username"],
        "checklist_step",
        account_id=record["id"],
        username=record["username"],
        detail={"step": payload.step, "done": payload.done},
    )
    return identity_store.offboarding_progress(record["id"]) | {"item": item}


@app.post("/identity/accounts/{uid}/offboarding")
async def identity_offboard(
    uid: int,
    payload: IdentityOffboard,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    _require_user_admin(session)
    roster = await _extensionista_call(session, "GET", "/neruds-control/extensionistas")
    target = next(
        (a for a in roster.get("accounts", []) if a.get("uid") == uid), None
    )
    if target is None:
        raise HTTPException(
            status_code=404, detail="Conta extensionista não encontrada no Drupal."
        )
    username = target["name"]
    actor = session["username"]

    record = _sync_identity_account(target, actor=actor)

    transferred = 0
    if payload.transfer_to:
        for task in _open_tasks_for(username):
            changes: dict[str, Any] = {"primary_owner": payload.transfer_to}
            # Fallback-owned tasks keep the offboarded username in
            # responsible; leaving it would undo the transfer as soon as
            # a reviewer cleared the new primary_owner.
            if (task.get("responsible") or "").strip() == username:
                changes["responsible"] = payload.transfer_to
            mission_store.update_task(
                task["id"],
                actor=actor,
                changes=changes,
                note=f"Offboarding de {username}: tarefa transferida para {payload.transfer_to}.",
            )
            transferred += 1
    open_tasks = _open_tasks_for(username)

    identity_store.set_check(
        record["id"], "tasks_reassigned", transferred > 0 or not open_tasks, actor
    )

    drupal_result = await _extensionista_call(
        session,
        "POST",
        f"/neruds-control/extensionistas/{uid}/status",
        {"active": False},
    )
    record = _sync_identity_account(drupal_result, actor=actor)
    record = identity_store.mark_offboarded(username, actor=actor)
    identity_store.set_check(record["id"], "account_blocked", True, actor)

    identity_store.record_event(
        actor,
        "offboarded",
        account_id=record["id"],
        username=username,
        detail={
            "drupal_uid": uid,
            "transfer_to": payload.transfer_to,
            "tasks_transferred": transferred,
            "pending_drafts": target.get("pending_drafts"),
            "note": payload.note,
        },
    )

    advisories = []
    if open_tasks and not payload.transfer_to:
        advisories.append(
            f"{len(open_tasks)} tarefas abertas continuam atribuídas a {username}; "
            "informe transfer_to para redistribuí-las."
        )
    if (target.get("pending_drafts") or 0) > 0:
        advisories.append(
            f"{username} tem {target['pending_drafts']} rascunhos não publicados "
            "aguardando revisão editorial."
        )
    advisories.extend(
        [
            "Desative a caixa de e-mail institucional no Poste.io.",
            "Sessões Drupal existentes expiram por inatividade; encerre-as em "
            "Pessoas > sessões se necessário.",
        ]
    )

    return {
        "account": record,
        "tasks_transferred": transferred,
        "checklist": identity_store.offboarding_progress(record["id"]),
        "advisories": advisories,
    }


@app.get("/identity/events")
def identity_events(
    username: str | None = None,
    limit: int = Query(default=100, ge=1, le=500),
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    _require_user_admin(session)
    return {
        "items": identity_store.list_events(username=username, limit=limit)
    }


# ---------------------------------------------------------------------------
# Caixa de oportunidades RSS/Atom com curadoria humana
# ---------------------------------------------------------------------------

@app.get("/opportunities/dashboard")
def opportunities_dashboard(
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    return rss_store.dashboard()


@app.get("/opportunities/sources")
def opportunity_sources(
    session: dict[str, Any] = Depends(require_session),
) -> list[dict[str, Any]]:
    return rss_store.list_sources()


@app.post("/opportunities/sources")
def opportunity_source_create(
    payload: FeedSourceCreate,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    try:
        return rss_store.add_source(
            payload.name,
            payload.url,
            actor=session["username"],
            default_category=payload.default_category,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))


@app.patch("/opportunities/sources/{source_id}")
def opportunity_source_update(
    source_id: int,
    payload: FeedSourcePatch,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    try:
        return rss_store.update_source(
            source_id,
            active=payload.active,
            default_category=payload.default_category,
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="Fonte não encontrada.")
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))


@app.post("/opportunities/sources/{source_id}/refresh")
async def opportunity_source_refresh(
    source_id: int,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    try:
        return await asyncio.to_thread(rss_store.refresh_source, source_id)
    except KeyError:
        raise HTTPException(status_code=404, detail="Fonte não encontrada.")
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"Falha ao consultar a fonte: {exc}")


@app.post("/opportunities/refresh")
async def opportunities_refresh(
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    return await asyncio.to_thread(rss_store.refresh_all)


def _opportunity_with_urls(item: dict[str, Any]) -> dict[str, Any]:
    return {**item, **_node_urls(item.get("drupal_draft_id"))}


@app.get("/opportunities/items")
def opportunity_items(
    status: str | None = None,
    category: str | None = None,
    source_id: int | None = None,
    q: str | None = None,
    deadline_status: str | None = None,
    limit: int = Query(default=100, ge=1, le=500),
    offset: int = Query(default=0, ge=0),
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    try:
        result = rss_store.list_items(
            status=status,
            category=category,
            source_id=source_id,
            query=q,
            deadline_status=deadline_status,
            limit=limit,
            offset=offset,
        )
        result["items"] = [_opportunity_with_urls(item) for item in result["items"]]
        return result
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))


@app.post("/opportunities/items/manual")
def opportunity_manual_capture(
    payload: ManualOpportunityCreate,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    try:
        return rss_store.add_manual_item(
            title=payload.title,
            url=payload.url,
            category=payload.category,
            summary=payload.summary,
            actor=session["username"],
            deadline_at=payload.deadline_at,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))


@app.get("/opportunities/items/{item_id}")
def opportunity_item_detail(
    item_id: int,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    try:
        return _opportunity_with_urls(rss_store.item_detail(item_id))
    except KeyError:
        raise HTTPException(status_code=404, detail="Oportunidade não encontrada.")


@app.patch("/opportunities/items/{item_id}/decision")
def opportunity_decision(
    item_id: int,
    payload: FeedDecision,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    if payload.status == "aprovado_pauta" and not session.get("can_review", False):
        raise HTTPException(
            status_code=403,
            detail="Somente perfis de revisão/coordenação podem aprovar uma pauta.",
        )
    try:
        item = rss_store.decide(
            item_id,
            actor=session["username"],
            status=payload.status,
            note=payload.note,
            category=payload.category,
            deadline_at=payload.deadline_at,
            fit_tags=payload.fit_tags,
        )
        return _opportunity_with_urls(item)
    except KeyError:
        raise HTTPException(status_code=404, detail="Oportunidade não encontrada.")
    except rss_store.DraftConflict as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))


@app.post("/opportunities/items/{item_id}/draft")
async def opportunity_create_draft(
    item_id: int,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    lock = _OPPORTUNITY_DRAFT_LOCKS.get(item_id)
    if lock is None:
        lock = asyncio.Lock()
        _OPPORTUNITY_DRAFT_LOCKS[item_id] = lock
    async with lock:
        return await _opportunity_create_draft_locked(item_id, session)


async def _opportunity_create_draft_locked(
    item_id: int,
    session: dict[str, Any],
) -> dict[str, Any]:
    try:
        item = rss_store.item_detail(item_id)
    except KeyError:
        raise HTTPException(status_code=404, detail="Oportunidade não encontrada.")

    if item.get("drupal_draft_id"):
        raise HTTPException(
            status_code=409,
            detail="Esta oportunidade já possui um rascunho Drupal. Abra o registro existente no portal.",
        )
    if item["status"] != "aprovado_pauta":
        raise HTTPException(
            status_code=409,
            detail="A oportunidade precisa ser aprovada como pauta antes de virar rascunho.",
        )
    if item["duplicate_of_item_id"] is not None:
        raise HTTPException(
            status_code=409,
            detail="Uma oportunidade duplicada não pode virar rascunho. Use o item de referência para preservar a auditoria.",
        )

    source_line = f"Fonte original: {item['url']}"
    body_parts = [
        item.get("summary") or "",
        source_line,
        "Conteúdo importado como pauta para revisão humana. Verifique prazo, elegibilidade, autoria e fonte antes da publicação.",
    ]
    body = "\n\n".join(part for part in body_parts if part)

    created = await _create_news_draft_internal(
        title=item["title"],
        summary=item.get("summary") or "",
        body=body,
        publication_date=None,
        session=session,
        opportunity_item_id=item_id,
    )
    drupal_id = str(created.get("id") or "")
    if not drupal_id:
        raise HTTPException(
            status_code=502,
            detail="Drupal salvou sem confirmar o identificador. Confira a notícia no portal antes de repetir.",
        )
    try:
        rss_store.mark_draft(item_id, session["username"], drupal_id)
    except rss_store.DraftConflict as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    notification = await notify_review(item["title"], session["username"])

    return {
        "ok": True,
        "item_id": item_id,
        "drupal_draft_id": drupal_id,
        "published": False,
        "notification": notification,
        **_node_urls(drupal_id),
    }


@app.get("/missions/{mission_id}/work-items")
def mission_work_items(
    mission_id: int,
    section: str | None = None,
    completed: bool | None = None,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    try:
        mission_store.dashboard(mission_id)
        return mission_store.list_work_items(
            mission_id,
            section=section,
            completed=completed,
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="Missão não encontrada.")


@app.get("/mission-work-items/{work_item_id}")
def mission_work_item_detail(
    work_item_id: int,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    try:
        return mission_store.work_item_detail(work_item_id)
    except KeyError:
        raise HTTPException(
            status_code=404,
            detail="Atividade complementar não encontrada.",
        )


@app.patch("/mission-work-items/{work_item_id}")
def mission_work_item_update(
    work_item_id: int,
    payload: WorkItemPatch,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    try:
        return mission_store.update_work_item(
            work_item_id,
            actor=session["username"],
            completed=payload.completed,
            status=payload.status,
            evidence=payload.evidence,
            note=payload.note,
        )
    except KeyError:
        raise HTTPException(
            status_code=404,
            detail="Atividade complementar não encontrada.",
        )


# ---------------------------------------------------------------------------
# Menus do portal — navegação gerenciável no app.
# Requer a permissão Drupal "administer menu" (concedida ao papel
# extensionista em 2026-11 — se um novo operador não enxergar os menus,
# a permissão está faltando na sua conta/papel).
# ---------------------------------------------------------------------------


def _menu_link_item(item: dict[str, Any]) -> dict[str, Any]:
    a = item.get("attributes") or {}
    link = a.get("link") or {}
    return {
        "uuid": item.get("id"),
        "menu": a.get("menu_name"),
        "title": a.get("title") or "",
        "uri": link.get("uri") or "",
        "enabled": bool(a.get("enabled", True)),
        "expanded": bool(a.get("expanded", False)),
        "weight": a.get("weight") or 0,
    }


@app.get("/menus")
async def menus_list(
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    async with drupal_client(session) as client:
        response = await client.get("/jsonapi/menu/menu")
    if response.status_code != 200:
        raise HTTPException(status_code=response.status_code,
                            detail="Consulta de menus recusada.")
    return {
        "menus": [
            {
                "id": (it.get("attributes") or {}).get(
                    "drupal_internal__id"),
                "label": (it.get("attributes") or {}).get("label")
                or (it.get("attributes") or {}).get(
                    "drupal_internal__id"),
            }
            for it in response.json().get("data", [])
        ]
    }


@app.get("/menus/{menu}")
async def menu_items(
    menu: str,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    async with drupal_client(session) as client:
        response = await client.get(
            "/jsonapi/menu_link_content/menu_link_content",
            params={
                "filter[menu_name]": menu,
                "sort": "weight",
                "page[limit]": "100",
            },
        )
    if response.status_code != 200:
        raise HTTPException(status_code=response.status_code,
                            detail="Consulta de itens recusada.")
    return {"items": [_menu_link_item(it) for it in response.json().get("data", [])]}


def _menu_link_body(payload: dict[str, Any], item: dict[str, Any] | None) -> dict[str, Any]:
    a = (item or {}).get("attributes") or {}
    attrs: dict[str, Any] = {
        "title": payload.get("title", a.get("title")),
        "enabled": bool(payload.get("enabled", a.get("enabled", True))),
        "expanded": bool(payload.get("expanded", a.get("expanded", False))),
        "weight": payload.get("weight", a.get("weight", 0)),
        "link": {"uri": payload.get("uri", (a.get("link") or {}).get("uri"))},
    }
    if a.get("menu_name"):
        attrs["menu_name"] = a["menu_name"]
    return attrs


@app.patch("/menus/items/{uuid}")
async def menu_item_update(
    uuid: str,
    payload: dict[str, Any] = Body(default={}),
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    async with drupal_client(session) as client:
        current = await client.get(
            f"/jsonapi/menu_link_content/menu_link_content/{uuid}")
        if current.status_code != 200:
            raise HTTPException(status_code=current.status_code,
                                detail="Item de menu não acessível.")
        item = current.json().get("data") or {}
        body = {
            "data": {
                "type": "menu_link_content--menu_link_content",
                "id": uuid,
                "attributes": _menu_link_body(payload, item),
            }
        }
        response = await client.patch(
            f"/jsonapi/menu_link_content/menu_link_content/{uuid}",
            json=body,
            headers={
                "Content-Type": "application/vnd.api+json",
                "X-CSRF-Token": session.get("csrf") or "",
            },
        )
    if response.status_code != 200:
        raise HTTPException(
            status_code=response.status_code,
            detail=f"Portal recusou a atualização do item de menu.",
        )
    return {"ok": True, "item": _menu_link_item(response.json().get("data") or {})}


@app.post("/menus/{menu}/items")
async def menu_item_create(
    menu: str,
    payload: dict[str, Any] = Body(default={}),
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    attrs = _menu_link_body(payload, {"attributes": {"menu_name": menu}})
    body = {
        "data": {
            "type": "menu_link_content--menu_link_content",
            "attributes": attrs,
        }
    }
    async with drupal_client(session) as client:
        response = await client.post(
            "/jsonapi/menu_link_content/menu_link_content",
            json=body,
            headers={
                "Content-Type": "application/vnd.api+json",
                "X-CSRF-Token": session.get("csrf") or "",
            },
        )
    if response.status_code not in (200, 201):
        raise HTTPException(
            status_code=response.status_code,
            detail="Portal recusou a criação do item de menu.",
        )
    return {"ok": True, "item": _menu_link_item(response.json().get("data") or {})}


@app.delete("/menus/items/{uuid}")
async def menu_item_delete(
    uuid: str,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    async with drupal_client(session) as client:
        response = await client.delete(
            f"/jsonapi/menu_link_content/menu_link_content/{uuid}",
            headers={"X-CSRF-Token": session.get("csrf") or ""})
    if response.status_code not in (200, 204):
        raise HTTPException(
            status_code=response.status_code,
            detail="Portal recusou a remoção do item de menu.",
        )
    return {"ok": True}
