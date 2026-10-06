from __future__ import annotations

import asyncio
import io
import json
import os
import re
import secrets
import smtplib
import socket
import ssl
import subprocess
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from html import escape
from html.parser import HTMLParser
from typing import Any

import httpx
import mission_store
import review_store
import rss_store
from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

load_dotenv()

PORTAL_URL = os.getenv("NERUDS_PORTAL_URL", "https://neruds.org").rstrip("/")
VPS_TAILSCALE_HOST = os.getenv("NERUDS_VPS_TAILSCALE_HOST", "100.111.132.36")
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

# Sessions live only in memory and disappear when the bridge restarts.
# Passwords are never stored. Drupal remains the source of truth for identity/permissions.
SESSION_IDLE_TTL = timedelta(hours=int(os.getenv("NERUDS_SESSION_IDLE_HOURS", "8")))
SESSIONS: dict[str, dict[str, Any]] = {}

app = FastAPI(
    title="NERUDS Control Bridge",
    version="0.3.3",
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


class HiddenInputParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.fields: dict[str, str] = {}

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() != "input":
            return
        data = dict(attrs)
        name = data.get("name")
        if not name:
            return
        input_type = data.get("type", "").lower()
        if input_type == "hidden":
            self.fields[name] = data.get("value") or ""
        elif input_type == "submit" and name == "op" and name not in self.fields:
            self.fields[name] = data.get("value") or ""


class LoginRequest(BaseModel):
    username: str = Field(min_length=1, max_length=128)
    password: str = Field(min_length=1, max_length=512)


class NewsDraftRequest(BaseModel):
    title: str = Field(min_length=3, max_length=255)
    summary: str = Field(default="", max_length=4000)
    body: str = Field(min_length=1)
    publication_date: str | None = None


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
    note: str | None = None
    evidence_url: str | None = None


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


class ManualOpportunityCreate(BaseModel):
    title: str = Field(min_length=3, max_length=300)
    url: str = Field(min_length=8, max_length=2048)
    category: str
    summary: str | None = Field(default=None, max_length=5000)


class DraftReviewDecision(BaseModel):
    status: str
    note: str | None = Field(default=None, max_length=4000)


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


async def _create_news_draft_internal(
    *,
    title: str,
    summary: str,
    body: str,
    publication_date: str | None,
    session: dict[str, Any],
) -> dict[str, Any]:
    async with drupal_client(session) as client:
        form = await client.get("/node/add/noticia")
        if form.status_code != 200:
            raise HTTPException(
                status_code=form.status_code,
                detail="Drupal recusou o acesso ao formulário de Notícia.",
            )

        parser = HiddenInputParser()
        parser.feed(form.text)
        fields = parser.fields
        fields.update(
            {
                "title[0][value]": title,
                "body[0][summary]": summary,
                "body[0][value]": plain_to_basic_html(body),
                "body[0][format]": "basic_html",
                "form_id": fields.get("form_id", "node_noticia_form"),
                "op": fields.get("op", "Salvar"),
            }
        )
        if publication_date:
            fields["field_data_publicacao[0][value][date]"] = publication_date

        response = await client.post(
            "/node/add/noticia",
            data=fields,
            follow_redirects=False,
        )
        if response.status_code not in (302, 303):
            raise HTTPException(
                status_code=response.status_code,
                detail={
                    "message": "Drupal não salvou o rascunho pelo formulário nativo.",
                    "response": response.text[:1200],
                },
            )

        location = response.headers.get("location", "")
        match = re.search(r"/node/(\d+)", location)
        node_id = match.group(1) if match else None
        jsonapi_id = None

        if not node_id:
            lookup = await client.get(
                "/jsonapi/node/noticia",
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
                    internal_nid = attrs.get("drupal_internal__nid")
                    if internal_nid is not None:
                        node_id = str(internal_nid)
                    jsonapi_id = item.get("id")
                    break

        draft_id = node_id or jsonapi_id
        if draft_id:
            review_store.register_draft(
                str(draft_id),
                title,
                session["username"],
            )

        return {
            "id": draft_id,
            "drupal_internal_nid": node_id,
            "jsonapi_id": jsonapi_id,
            "type": "node--noticia",
            "location": location,
        }


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "ok": True,
        "service": "neruds-control-bridge",
        "mode": "editorial-mvp",
        "version": "0.3.3",
        "time": datetime.now(timezone.utc).isoformat(),
        "active_sessions": len(SESSIONS),
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
        "backup": False,
        "server_update": False,
        "notes": [
            "Identidade e permissões editoriais são delegadas ao Drupal.",
            "Senha Drupal não é persistida pelo bridge.",
            "Operações de infraestrutura continuam separadas do fluxo editorial.",
        ],
    }


@app.post("/auth/login")
async def login(payload: LoginRequest) -> dict[str, Any]:
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
            if key.startswith("node--") and key != "node--page"
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


@app.get("/content/news/drafts")
async def news_drafts(session: dict[str, Any] = Depends(require_session)) -> dict[str, Any]:
    params = {
        "filter[status]": "0",
        "sort": "-changed",
        "page[limit]": "50",
    }
    async with drupal_client(session) as client:
        response = await client.get("/jsonapi/node/noticia", params=params)
        if response.status_code >= 400:
            raise HTTPException(
                status_code=response.status_code,
                detail="Drupal não autorizou a leitura dos rascunhos.",
            )
        drafts = []
        for item in response.json().get("data", []):
            attrs = item.get("attributes", {})
            nid = attrs.get("drupal_internal__nid")
            review = None
            if nid is not None:
                review = review_store.ensure_draft(
                    str(nid),
                    attrs.get("title", "Sem título"),
                    "Drupal",
                )
            drafts.append(
                {
                    "id": item.get("id"),
                    "nid": nid,
                    "title": attrs.get("title", "Sem título"),
                    "changed": attrs.get("changed", ""),
                    "created": attrs.get("created", ""),
                    "moderation_state": attrs.get("moderation_state", ""),
                    "review": review,
                }
            )
        return {
            "items": drafts,
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
    )
    notification = await notify_review(payload.title, session["username"])
    return {
        "ok": True,
        "id": created.get("id"),
        "type": created.get("type"),
        "title": payload.title,
        "published": False,
        "notification": notification,
    }


@app.patch("/content/news/drafts/{nid}/review")
async def review_news_draft(
    nid: int,
    payload: DraftReviewDecision,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    if not session.get("can_review", False):
        raise HTTPException(
            status_code=403,
            detail="Sua conta não tem permissão para revisar notícias.",
        )

    current = review_store.get_review(str(nid))
    if not current:
        raise HTTPException(status_code=404, detail="Rascunho não registrado para revisão.")

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
    if payload.current_stage and payload.current_stage not in mission_store.WORKFLOW:
        raise HTTPException(status_code=422, detail="Etapa da missão inválida.")
    try:
        return mission_store.update_task(
            task_id,
            actor=session["username"],
            changes=changes,
            note=payload.note,
            evidence_url=payload.evidence_url,
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="Tarefa não encontrada.")


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


@app.get("/opportunities/items")
def opportunity_items(
    status: str | None = None,
    category: str | None = None,
    source_id: int | None = None,
    q: str | None = None,
    limit: int = Query(default=100, ge=1, le=500),
    offset: int = Query(default=0, ge=0),
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    return rss_store.list_items(
        status=status,
        category=category,
        source_id=source_id,
        query=q,
        limit=limit,
        offset=offset,
    )


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
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))


@app.get("/opportunities/items/{item_id}")
def opportunity_item_detail(
    item_id: int,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    try:
        return rss_store.item_detail(item_id)
    except KeyError:
        raise HTTPException(status_code=404, detail="Oportunidade não encontrada.")


@app.patch("/opportunities/items/{item_id}/decision")
def opportunity_decision(
    item_id: int,
    payload: FeedDecision,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    try:
        return rss_store.decide(
            item_id,
            actor=session["username"],
            status=payload.status,
            note=payload.note,
            category=payload.category,
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="Oportunidade não encontrada.")
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))


@app.post("/opportunities/items/{item_id}/draft")
async def opportunity_create_draft(
    item_id: int,
    session: dict[str, Any] = Depends(require_session),
) -> dict[str, Any]:
    try:
        item = rss_store.item_detail(item_id)
    except KeyError:
        raise HTTPException(status_code=404, detail="Oportunidade não encontrada.")

    if item["status"] != "aprovado_pauta":
        raise HTTPException(
            status_code=409,
            detail="A oportunidade precisa ser aprovada como pauta antes de virar rascunho.",
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
    )
    drupal_id = str(created.get("id") or "")
    rss_store.mark_draft(item_id, session["username"], drupal_id)
    notification = await notify_review(item["title"], session["username"])

    return {
        "ok": True,
        "item_id": item_id,
        "drupal_draft_id": drupal_id,
        "published": False,
        "notification": notification,
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
