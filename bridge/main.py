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
from html import escape, unescape
from html.parser import HTMLParser
from typing import Any
from weakref import WeakValueDictionary

import httpx

import content_map
import identity_store
import mission_automation
import mission_store
import review_store
import rss_store
from dotenv import load_dotenv
from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, Query, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, StreamingResponse
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
# Serialize requests for the same opportunity in this bridge process.
_OPPORTUNITY_DRAFT_LOCKS: WeakValueDictionary[int, asyncio.Lock] = WeakValueDictionary()

app = FastAPI(
    title="NERUDS Control Bridge",
    version="0.4.0",
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
    async with drupal_client(session) as client:
        form = await client.get("/node/add/noticia")
        if form.status_code != 200:
            raise HTTPException(
                status_code=form.status_code,
                detail="Drupal recusou o acesso ao formulário de Notícia.",
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
                "field_data_noticia[0][value][date]": publication_date
                or datetime.now().date().isoformat(),
                "form_id": fields.get("form_id", "node_noticia_form"),
                "op": fields.get("op", "Salvar"),
            }
        )
        if text_format is None:
            fields.pop("body[0][format]", None)
        else:
            fields["body[0][format]"] = text_format
        if publication_date:
            fields["field_data_publicacao[0][value][date]"] = publication_date

        response = await client.post(
            "/node/add/noticia",
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
            "type": "node--noticia",
            "location": location,
            **_node_urls(node_id),
            "owner_uid": str(session["uid"]) if session.get("uid") is not None else None,
            "is_owner": True,
        }


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "ok": True,
        "service": "neruds-control-bridge",
        "mode": "editorial-mvp",
        "version": "0.4.0",
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
    client: httpx.AsyncClient, bundle: str
) -> dict[str, Any]:
    """JSON:API items for a monitored bundle, cached with its fetch time."""
    key = f"nodes:{bundle}"
    cached = _portal_cache_get(key)
    if cached is not None:
        return cached
    meta = content_map.MONITORED_TYPES[bundle]
    result = await _jsonapi_items(client, bundle, list(meta["fields"]))
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
    while url:
        response = await client.get(url, params=params)
        if response.status_code >= 400:
            raise HTTPException(
                status_code=response.status_code,
                detail=f"Drupal não autorizou a leitura de {bundle}.",
            )
        payload = response.json()
        items.extend(payload.get("data", []))
        included.extend(payload.get("included") or [])
        url = (payload.get("links") or {}).get("next", {}).get("href")
        params = {}  # the next link already carries the query string
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
            cached = await _portal_nodes(client, bundle)
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
    cached = _portal_cache_get("ep:eventos")
    if cached is not None:
        return cached
    async with drupal_client(session) as client:
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
        "ep:eventos",
        {
            "fetched_at": datetime.now(timezone.utc).isoformat(),
            "events": events,
            "listing_url": f"{PORTAL_URL}/eventos",
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
            ],
            include="field_status_projeto,field_tipo_projeto",
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
    params = {"sort": "-changed", "page[limit]": str(limit)}
    if status:
        params["filter[status]"] = "1" if status == "published" else "0"
    async with drupal_client(session) as client:
        response = await client.get("/jsonapi/node/noticia", params=params)
        if response.status_code >= 400:
            raise HTTPException(
                status_code=response.status_code,
                detail="Drupal não autorizou a leitura dos rascunhos.",
            )
        payload = response.json()
        truncated = "next" in (payload.get("links") or {})
        drafts = []
        for item in payload.get("data", []):
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
    controlled_assignment_fields = {
        "primary_owner",
        "cross_reviewer",
        "internal_deadline",
    }
    requested_controlled_fields = controlled_assignment_fields.intersection(changes)
    if requested_controlled_fields and not session.get("can_review", False):
        raise HTTPException(
            status_code=403,
            detail=(
                "Somente perfis de revisão/coordenação podem alterar "
                "responsável, revisor cruzado ou prazo interno."
            ),
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

    bundle = mission_automation.CONTENT_TYPE_BUNDLES.get(
        (task.get("content_type") or "").strip()
    )
    title = (task.get("title") or "").strip()
    if not bundle or not title:
        return {"task_id": task_id, "bundle": bundle, "matches": []}

    matches = []
    async with drupal_client(session) as client:
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
            matches.append(
                {
                    "nid": attrs.get("drupal_internal__nid"),
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


def _mission_id() -> int | None:
    missions = mission_store.mission_list()
    return missions[0]["id"] if missions else None


def _open_tasks_for(username: str) -> list[dict[str, Any]]:
    mission_id = _mission_id()
    if mission_id is None:
        return []
    items = mission_store.list_tasks(mission_id, owner=username, limit=500)["items"]
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
            mission_store.update_task(
                task["id"],
                actor=actor,
                changes={"primary_owner": payload.transfer_to},
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
