from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import sqlite3
import threading
import zipfile
from collections import Counter
from datetime import date, datetime, timedelta, timezone

import portal_links
from io import BytesIO
from pathlib import Path
from typing import Any
from xml.sax.saxutils import escape as xml_escape

BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR.parent / "data"
DB_PATH = DATA_DIR / "missions.sqlite3"
SEED_PATH = BASE_DIR / "mission_seed.json"

MISSION_CODE = "GESTAO_PORTAL_NERUDS"
MISSION_TITLE = "Missão: Gestão, Verificação e Perpetuidade do Portal NERUDS"
MISSION_DESCRIPTION = (
    "Executar as verificações da planilha de treinamento, registrar fontes, "
    "evidências, revisão cruzada, validação e conferência pública."
)

WORKFLOW = [
    "Triagem",
    "Em pesquisa",
    "Evidência registrada",
    "Revisão cruzada",
    "Aguardando validação",
    "Conferência pública",
    "Concluído",
    "Bloqueado",
]

TASK_COLUMNS = [
    "prioridade",
    "id",
    "tipo",
    "titulo",
    "conferencia_publica_ok",
    "url_publica",
    "url_edicao",
    "area_sugerida",
    "lacunas",
    "acao",
    "onde_buscar",
    "fontes",
    "consulta_sugerida",
    "evidencia",
    "responsavel",
    "status",
    "fonte_confirmada",
    "data_consulta",
    "observacoes",
    "responsavel_primario",
    "revisor_cruzado",
    "etapa_atual",
    "prazo_interno",
]

FIELD_MAP = {
    "priority": "priority",
    "status": "status",
    "current_stage": "current_stage",
    "evidence": "evidence",
    "confirmed_source": "confirmed_source",
    "consultation_date": "consultation_date",
    "observations": "observations",
    "responsible": "responsible",
    "primary_owner": "primary_owner",
    "cross_reviewer": "cross_reviewer",
    "public_check_ok": "public_check_ok",
    "internal_deadline": "internal_deadline",
    "public_url": "public_url",
    "edit_url": "edit_url",
}

WORK_SPECS = {
    "chamados_tecnicos": {
        "sheet": "07_Chamados_Tecnicos",
        "header": 0,
        "title": ["titulo_ou_id", "tipo_de_problema"],
        "responsible": ["registrado_por"],
        "status": ["status_do_chamado"],
        "evidence": ["evidencia"],
    },
    "extensao_institucional": {
        "sheet": "08_Extensao_Institucional",
        "header": 1,
        "title": ["Etapa", "Objetivo"],
        "responsible": [],
        "status": ["Status"],
        "evidence": ["Evidência"],
    },
    "roteiro_entrevistas": {
        "sheet": "09_Roteiro_Entrevistas",
        "header": 1,
        "title": ["Pergunta principal", "Bloco"],
        "responsible": ["Quem valida"],
        "status": ["Status"],
        "evidence": ["Fonte/documento citado"],
    },
    "mvv": {
        "sheet": "10_MVV_Consolidacao",
        "header": 1,
        "title": ["Elemento"],
        "responsible": [],
        "status": ["Aprovação"],
        "evidence": ["Fonte principal"],
    },
    "historia_linha_tempo": {
        "sheet": "11_Historia_LinhaTempo",
        "header": 1,
        "title": ["Marco", "Ano/Data"],
        "responsible": [],
        "status": ["Publicar?"],
        "evidence": ["Fonte documental"],
    },
    "organograma": {
        "sheet": "12_Organograma",
        "header": 1,
        "title": ["Unidade/Função", "Nível"],
        "responsible": ["Titular atual"],
        "status": ["Status"],
        "evidence": ["Fonte da confirmação"],
    },
    "noticias_instagram": {
        "sheet": "13_Noticias_Instagram",
        "header": 1,
        "title": ["Tema", "Fato noticiável"],
        "responsible": ["Responsável redação"],
        "status": ["Status"],
        "evidence": ["Fonte adicional", "URL do Instagram"],
    },
    "paginas_futuras": {
        "sheet": "14_Paginas_Futuras",
        "header": 1,
        "title": ["Sugestão de página"],
        "responsible": ["Responsável futuro"],
        "status": [],
        "evidence": ["Fontes disponíveis"],
    },
    "diario_extensao": {
        "sheet": "15_Diario_Extensao",
        "header": 1,
        "title": ["Atividade"],
        "responsible": ["Pessoa"],
        "status": ["Validação"],
        "evidence": ["Link/evidência"],
    },
    "encerramento_acessos": {
        "sheet": "16_Encerramento_Acessos",
        "header": 1,
        "title": ["Item"],
        "responsible": ["Responsável"],
        "status": ["Status"],
        "evidence": ["Evidência"],
    },
}


def utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()


def connect() -> sqlite3.Connection:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    return conn


def backup_keep() -> int:
    """Retenção configurável via NERUDS_BACKUP_KEEP; mínimo de 1 arquivo."""
    try:
        return max(1, int(os.getenv("NERUDS_BACKUP_KEEP", "14")))
    except ValueError:
        return 14


def backup_dir() -> Path:
    return DATA_DIR / "backups"


_BACKUP_LOCK = threading.Lock()


def evidence_root() -> Path:
    return DATA_DIR / "evidence"


def backup_db(keep: int | None = None) -> Path:
    """Grava uma cópia consistente do mission store + arquivos de evidência.

    O zip contém `missions.sqlite3` (cópia atômica via sqlite backup API,
    segura com WAL e leitores ativos) e a árvore `evidence/` onde ficam os
    bytes dos anexos. Escreve em arquivo temporário e renomeia ao concluir —
    um backup parcial nunca entra na lista de restauráveis nem suprime
    novas tentativas. Chamadas concorrentes são serializadas pelo lock.
    Retorna o caminho final.
    """
    with _BACKUP_LOCK:
        return _backup_db_locked(keep)


def _backup_db_locked(keep: int | None) -> Path:
    dest_dir = backup_dir()
    dest_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-%f")
    dest = dest_dir / f"missions-{stamp}.zip"
    tmp = dest_dir / f"missions-{stamp}.tmp"
    tmp_db = dest_dir / f".db-{stamp}.tmp"
    try:
        source = connect()
        try:
            target = sqlite3.connect(tmp_db)
            try:
                source.backup(target)
            finally:
                target.close()
        finally:
            source.close()
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zf:
            zf.write(tmp_db, "missions.sqlite3")
            root = evidence_root()
            if root.is_dir():
                for blob in sorted(root.rglob("*")):
                    if blob.is_file():
                        zf.write(blob, f"evidence/{blob.relative_to(root).as_posix()}")
        tmp.replace(dest)
    finally:
        tmp.unlink(missing_ok=True)
        tmp_db.unlink(missing_ok=True)
    prune_backups(keep if keep is not None else backup_keep())
    return dest


def list_backups() -> list[dict[str, Any]]:
    dest_dir = backup_dir()
    if not dest_dir.is_dir():
        return []
    files = sorted(dest_dir.glob("missions-*.zip"), reverse=True)
    entries: list[dict[str, Any]] = []
    for f in files:
        try:
            stat = f.stat()
        except FileNotFoundError:
            continue  # removido por prune concorrente entre glob e stat
        entries.append(
            {
                "file": f.name,
                "size_bytes": stat.st_size,
                "created_at": datetime.fromtimestamp(
                    stat.st_mtime, tz=timezone.utc
                ).isoformat(),
            }
        )
    return entries


def prune_backups(keep: int) -> None:
    files = sorted(backup_dir().glob("missions-*.zip"), reverse=True)
    for stale in files[keep:]:
        stale.unlink(missing_ok=True)


def backup_due(max_age_hours: float = 24.0) -> bool:
    backups = list_backups()
    if not backups:
        return True
    newest = datetime.fromisoformat(backups[0]["created_at"])
    return datetime.now(timezone.utc) - newest > timedelta(hours=max_age_hours)


def check_ready() -> bool:
    """Readiness real: o arquivo existe e o schema da missão responde.

    Abre em modo somente-leitura — um banco ausente não é recriado."""
    if not DB_PATH.is_file():
        return False
    conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
    try:
        conn.execute("SELECT 1 FROM mission_task LIMIT 1")
        return True
    finally:
        conn.close()


def _json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), default=str)


PORTAL_URL = os.getenv("NERUDS_PORTAL_URL", "https://neruds.org").rstrip("/")


def _link_nid(url: Any) -> str | None:
    """Extract the node id from a persisted link, but only when the URL
    provably belongs to the configured portal — a foreign /node/N path
    must never count as our ficha."""
    if not url:
        return None
    parts = portal_links.portal_node_parts(str(url), PORTAL_URL)
    return parts[0] if parts else None


def _nonempty_rows(rows: list[list[Any]]) -> list[list[Any]]:
    return [row for row in rows if any(v is not None and str(v).strip() for v in row)]


def _sheet_dicts(seed: dict[str, Any], sheet: str, header_index: int = 0) -> list[dict[str, Any]]:
    rows = seed.get("sheets", {}).get(sheet, [])
    if len(rows) <= header_index:
        return []
    headers = rows[header_index]
    out = []
    for idx, row in enumerate(rows[header_index + 1 :], start=header_index + 2):
        if not any(v is not None and str(v).strip() for v in row):
            continue
        padded = list(row) + [None] * max(0, len(headers) - len(row))
        out.append({"spreadsheet_row": idx, **dict(zip(headers, padded))})
    return out


def _first_text(record: dict[str, Any], keys: list[str], default: str = "") -> str:
    for key in keys:
        value = record.get(key)
        if value is not None and str(value).strip():
            return str(value).strip()
    return default


def init_db() -> None:
    with connect() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS mission (
                id INTEGER PRIMARY KEY,
                code TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL,
                description TEXT,
                source_file TEXT,
                source_imported_at TEXT,
                workflow_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS mission_task (
                id INTEGER PRIMARY KEY,
                mission_id INTEGER NOT NULL REFERENCES mission(id) ON DELETE CASCADE,
                spreadsheet_row INTEGER NOT NULL,
                source_record_id TEXT,
                priority TEXT,
                content_type TEXT,
                title TEXT NOT NULL,
                public_check_ok INTEGER NOT NULL DEFAULT 0,
                public_url TEXT,
                edit_url TEXT,
                suggested_area TEXT,
                gaps TEXT,
                action TEXT,
                where_to_search TEXT,
                sources TEXT,
                suggested_query TEXT,
                evidence TEXT,
                responsible TEXT,
                status TEXT,
                confirmed_source TEXT,
                consultation_date TEXT,
                observations TEXT,
                primary_owner TEXT,
                cross_reviewer TEXT,
                current_stage TEXT,
                internal_deadline TEXT,
                raw_json TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                UNIQUE(mission_id, spreadsheet_row)
            );

            CREATE TABLE IF NOT EXISTS mission_event (
                id INTEGER PRIMARY KEY,
                task_id INTEGER NOT NULL REFERENCES mission_task(id) ON DELETE CASCADE,
                actor TEXT NOT NULL,
                event_type TEXT NOT NULL,
                from_stage TEXT,
                to_stage TEXT,
                note TEXT,
                evidence_url TEXT,
                changes_json TEXT,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS checklist_template (
                id INTEGER PRIMARY KEY,
                kind TEXT NOT NULL,
                item_order INTEGER NOT NULL,
                item TEXT NOT NULL,
                criterion TEXT,
                UNIQUE(kind, item_order)
            );

            CREATE TABLE IF NOT EXISTS task_check_result (
                task_id INTEGER NOT NULL REFERENCES mission_task(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                item_order INTEGER NOT NULL,
                completed INTEGER NOT NULL DEFAULT 0,
                completed_by TEXT,
                completed_at TEXT,
                note TEXT,
                PRIMARY KEY(task_id, kind, item_order)
            );

            CREATE TABLE IF NOT EXISTS mission_reference (
                section TEXT PRIMARY KEY,
                payload_json TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS mission_work_item (
                id INTEGER PRIMARY KEY,
                mission_id INTEGER NOT NULL REFERENCES mission(id) ON DELETE CASCADE,
                section TEXT NOT NULL,
                spreadsheet_row INTEGER NOT NULL,
                title TEXT NOT NULL,
                responsible TEXT,
                status TEXT,
                evidence TEXT,
                note TEXT,
                completed INTEGER NOT NULL DEFAULT 0,
                payload_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                UNIQUE(mission_id, section, spreadsheet_row)
            );

            CREATE TABLE IF NOT EXISTS mission_work_event (
                id INTEGER PRIMARY KEY,
                work_item_id INTEGER NOT NULL REFERENCES mission_work_item(id) ON DELETE CASCADE,
                actor TEXT NOT NULL,
                event_type TEXT NOT NULL,
                note TEXT,
                changes_json TEXT,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS mission_saved_filter (
                id INTEGER PRIMARY KEY,
                mission_id INTEGER NOT NULL REFERENCES mission(id) ON DELETE CASCADE,
                actor TEXT NOT NULL,
                name TEXT NOT NULL,
                filters_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                UNIQUE(mission_id, actor, name)
            );

            CREATE TABLE IF NOT EXISTS task_evidence_file (
                id INTEGER PRIMARY KEY,
                task_id INTEGER NOT NULL REFERENCES mission_task(id) ON DELETE CASCADE,
                filename TEXT NOT NULL,
                stored_name TEXT NOT NULL,
                content_type TEXT,
                size_bytes INTEGER NOT NULL,
                sha256 TEXT NOT NULL,
                note TEXT,
                uploaded_by TEXT NOT NULL,
                created_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_task_mission_stage
                ON mission_task(mission_id, current_stage);
            CREATE INDEX IF NOT EXISTS idx_task_priority
                ON mission_task(priority);
            CREATE INDEX IF NOT EXISTS idx_task_owner
                ON mission_task(primary_owner);
            CREATE INDEX IF NOT EXISTS idx_event_task
                ON mission_event(task_id, created_at);
            CREATE INDEX IF NOT EXISTS idx_saved_filter_mission_actor
                ON mission_saved_filter(mission_id, actor);
            CREATE INDEX IF NOT EXISTS idx_evidence_file_task
                ON task_evidence_file(task_id, created_at);
            """
        )
        # Gap-born tasks remember which bundle/fields they were created to
        # fix so reconciliation can re-check that exact portal state.
        existing = {
            row[1] for row in conn.execute("PRAGMA table_info(mission_task)")
        }
        for column in ("gap_bundle", "gap_fields"):
            if column not in existing:
                conn.execute(
                    f"ALTER TABLE mission_task ADD COLUMN {column} TEXT"
                )


def seed_from_json(force: bool = False) -> dict[str, Any]:
    init_db()
    if not SEED_PATH.exists():
        return {"seeded": False, "reason": "seed_not_found"}

    seed = json.loads(SEED_PATH.read_text(encoding="utf-8"))
    sheets = seed.get("sheets", {})
    master = sheets.get("03_Controle_Master", [])
    if not master:
        return {"seeded": False, "reason": "master_missing"}

    headers = master[0]
    if headers[: len(TASK_COLUMNS)] != TASK_COLUMNS:
        raise RuntimeError("Cabeçalho do Controle Master não corresponde ao modelo esperado.")

    now = utcnow()
    with connect() as conn:
        existing = conn.execute(
            "SELECT id FROM mission WHERE code = ?", (MISSION_CODE,)
        ).fetchone()

        if existing and force:
            conn.execute("DELETE FROM mission WHERE id = ?", (existing["id"],))
            existing = None

        if existing:
            mission_id = existing["id"]
            conn.execute(
                """
                UPDATE mission
                SET source_file=?, source_imported_at=?, updated_at=?
                WHERE id=?
                """,
                (
                    seed.get("source_file"),
                    seed.get("imported_at"),
                    now,
                    mission_id,
                ),
            )
        else:
            cur = conn.execute(
                """
                INSERT INTO mission
                (code,title,description,source_file,source_imported_at,workflow_json,created_at,updated_at)
                VALUES (?,?,?,?,?,?,?,?)
                """,
                (
                    MISSION_CODE,
                    MISSION_TITLE,
                    MISSION_DESCRIPTION,
                    seed.get("source_file"),
                    seed.get("imported_at"),
                    _json(WORKFLOW),
                    now,
                    now,
                ),
            )
            mission_id = int(cur.lastrowid)

        inserted = 0
        for spreadsheet_row, row in enumerate(master[1:], start=2):
            if not any(v is not None and str(v).strip() for v in row):
                continue
            padded = list(row) + [None] * max(0, len(headers) - len(row))
            rec = dict(zip(headers, padded))
            values = (
                mission_id,
                spreadsheet_row,
                None if rec.get("id") is None else str(rec.get("id")),
                rec.get("prioridade"),
                rec.get("tipo"),
                rec.get("titulo") or f"Linha {spreadsheet_row}",
                1 if rec.get("conferencia_publica_ok") else 0,
                rec.get("url_publica"),
                rec.get("url_edicao"),
                rec.get("area_sugerida"),
                rec.get("lacunas"),
                rec.get("acao"),
                rec.get("onde_buscar"),
                rec.get("fontes"),
                rec.get("consulta_sugerida"),
                rec.get("evidencia"),
                rec.get("responsavel"),
                rec.get("status") or "A pesquisar",
                rec.get("fonte_confirmada"),
                None if rec.get("data_consulta") is None else str(rec.get("data_consulta")),
                rec.get("observacoes"),
                rec.get("responsavel_primario"),
                rec.get("revisor_cruzado"),
                rec.get("etapa_atual") or "Triagem",
                None if rec.get("prazo_interno") is None else str(rec.get("prazo_interno")),
                _json(rec),
                now,
                now,
            )
            cur = conn.execute(
                """
                INSERT OR IGNORE INTO mission_task (
                    mission_id,spreadsheet_row,source_record_id,priority,content_type,title,
                    public_check_ok,public_url,edit_url,suggested_area,gaps,action,where_to_search,
                    sources,suggested_query,evidence,responsible,status,confirmed_source,
                    consultation_date,observations,primary_owner,cross_reviewer,current_stage,
                    internal_deadline,raw_json,created_at,updated_at
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                values,
            )
            if cur.rowcount:
                inserted += 1

        publication = _sheet_dicts(seed, "05_Checklist_Publicacao")
        research = _sheet_dicts(seed, "06_Checklist_Pesquisa")
        for kind, items in (("publicacao", publication), ("pesquisa", research)):
            for item in items:
                order = int(float(item.get("ordem") or 0))
                if not order:
                    continue
                conn.execute(
                    """
                    INSERT OR REPLACE INTO checklist_template(kind,item_order,item,criterion)
                    VALUES (?,?,?,?)
                    """,
                    (
                        kind,
                        order,
                        item.get("item"),
                        item.get("criterio") or item.get("observacao"),
                    ),
                )

        reference_specs = {
            "resumo": ("00_Resumo", 0),
            "distribuicao": ("01_Distribuicao", 0),
            "plano_4_semanas": ("02_Plano_4_Semanas", 0),
            "equipe": ("04_Cadastro_Equipe", 0),
            "chamados_tecnicos": ("07_Chamados_Tecnicos", 0),
            "extensao_institucional": ("08_Extensao_Institucional", 1),
            "roteiro_entrevistas": ("09_Roteiro_Entrevistas", 1),
            "mvv": ("10_MVV_Consolidacao", 1),
            "historia_linha_tempo": ("11_Historia_LinhaTempo", 1),
            "organograma": ("12_Organograma", 1),
            "noticias_instagram": ("13_Noticias_Instagram", 1),
            "paginas_futuras": ("14_Paginas_Futuras", 1),
            "diario_extensao": ("15_Diario_Extensao", 1),
            "encerramento_acessos": ("16_Encerramento_Acessos", 1),
            "fontes_institucionais": ("17_Fontes_Institucionais", 1),
        }
        for section, (sheet, header_idx) in reference_specs.items():
            payload = _sheet_dicts(seed, sheet, header_idx)
            conn.execute(
                """
                INSERT OR REPLACE INTO mission_reference(section,payload_json)
                VALUES (?,?)
                """,
                (section, _json(payload)),
            )

        for section, spec in WORK_SPECS.items():
            records = _sheet_dicts(seed, spec["sheet"], spec["header"])
            for record in records:
                row_number = int(record["spreadsheet_row"])
                title = _first_text(
                    record,
                    spec["title"],
                    default=f"{section} • linha {row_number}",
                )
                responsible = _first_text(record, spec["responsible"])
                status = _first_text(record, spec["status"], default="A fazer")
                evidence = _first_text(record, spec["evidence"])
                completed = 1 if status.lower() in {
                    "concluído",
                    "concluido",
                    "finalizado",
                    "validado",
                    "aprovado",
                } else 0
                conn.execute(
                    """
                    INSERT INTO mission_work_item (
                        mission_id,section,spreadsheet_row,title,responsible,status,
                        evidence,note,completed,payload_json,created_at,updated_at
                    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(mission_id,section,spreadsheet_row) DO UPDATE SET
                        title=excluded.title,
                        responsible=CASE
                            WHEN mission_work_item.responsible IS NULL OR mission_work_item.responsible=''
                            THEN excluded.responsible ELSE mission_work_item.responsible END,
                        payload_json=excluded.payload_json,
                        updated_at=excluded.updated_at
                    """,
                    (
                        mission_id,
                        section,
                        row_number,
                        title,
                        responsible,
                        status,
                        evidence,
                        None,
                        completed,
                        _json(record),
                        now,
                        now,
                    ),
                )

        conn.commit()

    return {
        "seeded": True,
        "mission_id": mission_id,
        "inserted_tasks": inserted,
        "total_tasks": count_tasks(mission_id),
    }


def mission_list() -> list[dict[str, Any]]:
    init_db()
    with connect() as conn:
        rows = conn.execute(
            """
            SELECT m.*,
                   COUNT(t.id) AS total_tasks,
                   SUM(CASE WHEN t.current_stage='Concluído' THEN 1 ELSE 0 END) AS concluded
            FROM mission m
            LEFT JOIN mission_task t ON t.mission_id=m.id
            GROUP BY m.id
            ORDER BY m.id
            """
        ).fetchall()
        return [_mission_row(row) for row in rows]


def _mission_row(row: sqlite3.Row) -> dict[str, Any]:
    data = dict(row)
    data["workflow"] = json.loads(data.pop("workflow_json"))
    total = int(data.get("total_tasks") or 0)
    concluded = int(data.get("concluded") or 0)
    data["progress_percent"] = round((concluded / total) * 100, 1) if total else 0
    return data


def count_tasks(mission_id: int) -> int:
    with connect() as conn:
        return int(
            conn.execute(
                "SELECT COUNT(*) FROM mission_task WHERE mission_id=?", (mission_id,)
            ).fetchone()[0]
        )


def _deadline_date(value: Any) -> date | None:
    if value is None or not str(value).strip():
        return None
    text = str(value).strip()
    try:
        return date.fromisoformat(text[:10])
    except ValueError:
        pass
    try:
        return date(1899, 12, 30) + timedelta(days=int(float(text)))
    except ValueError:
        return None


def _deadline_status(deadline: date | None, stage: str | None) -> str | None:
    if not deadline or stage == "Concluído":
        return None
    today = datetime.now(timezone.utc).date()
    if deadline < today:
        return "overdue"
    if deadline <= today + timedelta(days=7):
        return "upcoming"
    return None


def dashboard(mission_id: int) -> dict[str, Any]:
    with connect() as conn:
        mission = conn.execute("SELECT * FROM mission WHERE id=?", (mission_id,)).fetchone()
        if not mission:
            raise KeyError("mission_not_found")
        tasks = conn.execute(
            """
            SELECT priority,content_type,current_stage,primary_owner,
                   responsible,internal_deadline
            FROM mission_task WHERE mission_id=?
            """,
            (mission_id,),
        ).fetchall()
        event_count = conn.execute(
            """
            SELECT COUNT(*) FROM mission_event e
            JOIN mission_task t ON t.id=e.task_id
            WHERE t.mission_id=?
            """,
            (mission_id,),
        ).fetchone()[0]

    stages = Counter((row["current_stage"] or "Sem etapa") for row in tasks)
    priorities = Counter((row["priority"] or "Sem prioridade") for row in tasks)
    types = Counter((row["content_type"] or "Sem tipo") for row in tasks)
    owners = Counter(
        (row["primary_owner"] or row["responsible"] or "Não atribuído")
        for row in tasks
    )
    total = len(tasks)
    concluded = stages.get("Concluído", 0)
    overdue = sum(
        _deadline_status(_deadline_date(row["internal_deadline"]), row["current_stage"])
        == "overdue"
        for row in tasks
    )
    upcoming = sum(
        _deadline_status(_deadline_date(row["internal_deadline"]), row["current_stage"])
        == "upcoming"
        for row in tasks
    )

    result = dict(mission)
    result["workflow"] = json.loads(result.pop("workflow_json"))
    result.update(
        {
            "total_tasks": total,
            "concluded": concluded,
            "progress_percent": round((concluded / total) * 100, 1) if total else 0,
            "by_stage": dict(stages),
            "by_priority": dict(priorities),
            "by_type": dict(types),
            "by_owner": dict(owners),
            "event_count": event_count,
            "overdue": overdue,
            "upcoming": upcoming,
        }
    )
    return result


def list_tasks(
    mission_id: int,
    *,
    stage: str | None = None,
    priority: str | None = None,
    owner: str | None = None,
    content_type: str | None = None,
    query: str | None = None,
    due_status: str | None = None,
    limit: int = 100,
    offset: int = 0,
) -> dict[str, Any]:
    where = ["mission_id=?"]
    args: list[Any] = [mission_id]
    filters = {
        "current_stage": stage,
        "priority": priority,
        "content_type": content_type,
    }
    for field, value in filters.items():
        if value:
            where.append(f"{field}=?")
            args.append(value)
    if owner:
        # Gap tasks may only carry the free-text responsible when the
        # creator lacked assignment permission.
        where.append("COALESCE(NULLIF(primary_owner,''),responsible)=?")
        args.append(owner)
    if query:
        where.append("(title LIKE ? OR action LIKE ? OR gaps LIKE ? OR suggested_query LIKE ?)")
        q = f"%{query}%"
        args.extend([q, q, q, q])

    clause = " AND ".join(where)
    with connect() as conn:
        rows = conn.execute(
            f"""
            SELECT * FROM mission_task
            WHERE {clause}
            ORDER BY
              CASE priority WHEN 'P0' THEN 0 WHEN 'P1' THEN 1 WHEN 'P2' THEN 2 ELSE 9 END,
              spreadsheet_row
            """,
            args,
        ).fetchall()
    items = [_task_row(row) for row in rows]
    if due_status:
        items = [item for item in items if item["deadline_status"] == due_status]
    total = len(items)
    bounded_limit = max(1, min(limit, 500))
    return {
        "total": total,
        "items": items[max(0, offset) : max(0, offset) + bounded_limit],
    }


def _task_row(row: sqlite3.Row) -> dict[str, Any]:
    data = dict(row)
    data["public_check_ok"] = bool(data["public_check_ok"])
    # Empty strings behave as "unassigned" everywhere — normalize so
    # consumers can rely on null alone for the fallback logic.
    for owner_field in ("primary_owner", "cross_reviewer", "responsible"):
        if data.get(owner_field) == "":
            data[owner_field] = None
    try:
        data["gap_fields"] = json.loads(data.get("gap_fields") or "[]")
    except ValueError:
        data["gap_fields"] = []
    due_date = _deadline_date(data.get("internal_deadline"))
    data["deadline_date"] = due_date.isoformat() if due_date else None
    data["deadline_status"] = _deadline_status(
        due_date,
        data.get("current_stage"),
    )
    data.pop("raw_json", None)
    return data


def task_detail(task_id: int) -> dict[str, Any]:
    with connect() as conn:
        row = conn.execute("SELECT * FROM mission_task WHERE id=?", (task_id,)).fetchone()
        if not row:
            raise KeyError("task_not_found")
        task = _task_row(row)
        templates = conn.execute(
            "SELECT * FROM checklist_template ORDER BY kind,item_order"
        ).fetchall()
        results = conn.execute(
            "SELECT * FROM task_check_result WHERE task_id=?", (task_id,)
        ).fetchall()
        events = conn.execute(
            "SELECT * FROM mission_event WHERE task_id=? ORDER BY id DESC LIMIT 100",
            (task_id,),
        ).fetchall()
        evidence_files = conn.execute(
            "SELECT * FROM task_evidence_file WHERE task_id=? ORDER BY id",
            (task_id,),
        ).fetchall()

    result_index = {
        (r["kind"], r["item_order"]): dict(r)
        for r in results
    }
    checklists: dict[str, list[dict[str, Any]]] = {}
    for template in templates:
        item = dict(template)
        state = result_index.get((item["kind"], item["item_order"]))
        if state:
            item.update(
                {
                    "completed": bool(state["completed"]),
                    "completed_by": state["completed_by"],
                    "completed_at": state["completed_at"],
                    "note": state["note"],
                }
            )
        else:
            item.update(
                {
                    "completed": False,
                    "completed_by": None,
                    "completed_at": None,
                    "note": None,
                }
            )
        checklists.setdefault(item["kind"], []).append(item)

    task["checklists"] = checklists
    task["events"] = [dict(event) for event in events]
    task["evidence_files"] = [_evidence_row(row) for row in evidence_files]
    return task


def update_task(
    task_id: int,
    actor: str,
    changes: dict[str, Any],
    note: str | None = None,
    evidence_url: str | None = None,
    actor_can_review: bool = True,
) -> dict[str, Any]:
    allowed = {k: v for k, v in changes.items() if k in FIELD_MAP}
    if not allowed and not note and not evidence_url:
        return task_detail(task_id)

    with connect() as conn:
        # BEGIN IMMEDIATE takes the write lock up front: python-sqlite3
        # otherwise stays in autocommit until the first DML, leaving a
        # window between this SELECT/validation and the UPDATE where a
        # concurrent PATCH could interleave.
        conn.execute("BEGIN IMMEDIATE")
        before = conn.execute("SELECT * FROM mission_task WHERE id=?", (task_id,)).fetchone()
        if not before:
            raise KeyError("task_not_found")

        if "current_stage" in allowed:
            # Missions may store their own workflow — a stage is valid
            # when it belongs to the global workflow or this mission's.
            mission_row = conn.execute(
                "SELECT workflow_json FROM mission WHERE id=?",
                (before["mission_id"],),
            ).fetchone()
            try:
                mission_workflow = (
                    json.loads(mission_row["workflow_json"] or "[]")
                    if mission_row
                    else []
                )
            except (TypeError, ValueError):
                mission_workflow = []
            valid_stages = (
                set(mission_workflow) if mission_workflow else set(WORKFLOW)
            )
            if allowed["current_stage"] not in valid_stages:
                raise ValueError("invalid_stage")

        if not actor_can_review and "responsible" in allowed:
            # A non-reviewer may only claim an unassigned task or adjust
            # their own — never move a task someone else owns, even via
            # the responsible fallback when primary_owner is unset.
            current_owner = (
                (before["primary_owner"] or "") or (before["responsible"] or "")
            ).strip()
            requested = (allowed["responsible"] or "").strip()
            if (
                requested != actor
                or (current_owner and current_owner != actor)
            ):
                raise PermissionError("owner_change_denied")

        if "public_url" in allowed or "edit_url" in allowed:
            # Pair check inside the transaction: the links being written
            # must reference the same node as each other and as any
            # persisted counterpart — verified against the row we hold,
            # not a snapshot another PATCH could have already replaced.
            linked_nids: set[str] = set()
            for link_field in ("public_url", "edit_url"):
                if link_field in allowed:
                    nid = _link_nid(allowed[link_field])
                    if nid:
                        linked_nids.add(nid)
                    continue
                persisted = before[link_field]
                if not persisted:
                    continue
                persisted_nid = _link_nid(persisted)
                if persisted_nid is None:
                    raise ValueError("link_alias_unresolvable")
                linked_nids.add(persisted_nid)
            if len(linked_nids) > 1:
                raise ValueError("link_node_mismatch")

        actual_changes: dict[str, Any] = {}
        assignments = []
        args: list[Any] = []
        for api_field, value in allowed.items():
            db_field = FIELD_MAP[api_field]
            if db_field == "public_check_ok":
                value = 1 if bool(value) else 0
            old_value = before[db_field]
            if old_value != value:
                assignments.append(f"{db_field}=?")
                args.append(value)
                actual_changes[api_field] = {"from": old_value, "to": value}

        if "public_url" in actual_changes or "edit_url" in actual_changes:
            # Relinked fichas must not inherit verification results recorded
            # for the previous node. Compare node identity, not the URL
            # string: a persisted alias (e.g. /pub/2) canonicalizing to
            # /node/2 is the same ficha and keeps its checks. Either link
            # may carry the node identity, so resolve old and new nids
            # across both fields.
            new_public = allowed.get("public_url", before["public_url"])
            new_edit = allowed.get("edit_url", before["edit_url"])
            old_nid = _link_nid(before["public_url"]) or _link_nid(
                before["edit_url"]
            )
            new_nid = _link_nid(new_public) or _link_nid(new_edit)
            relinked = new_nid != old_nid
        else:
            relinked = False
        if relinked:
            if before["public_check_ok"] and "public_check_ok" not in allowed:
                assignments.append("public_check_ok=?")
                args.append(0)
                actual_changes["public_check_ok"] = {"from": 1, "to": 0}
            url_check_table = conn.execute(
                "SELECT name FROM sqlite_master "
                "WHERE type='table' AND name='task_url_check'"
            ).fetchone()
            if url_check_table:
                conn.execute(
                    "DELETE FROM task_url_check WHERE task_id=?", (task_id,)
                )

        if assignments:
            assignments.append("updated_at=?")
            args.append(utcnow())
            args.append(task_id)
            conn.execute(
                f"UPDATE mission_task SET {', '.join(assignments)} WHERE id=?",
                args,
            )

        from_stage = before["current_stage"]
        to_stage = allowed.get("current_stage", from_stage)
        event_type = "task_updated"
        if from_stage != to_stage:
            event_type = "stage_changed"
        elif evidence_url or "evidence" in allowed:
            event_type = "evidence_registered"

        if actual_changes or note or evidence_url:
            conn.execute(
                """
                INSERT INTO mission_event
                (task_id,actor,event_type,from_stage,to_stage,note,evidence_url,changes_json,created_at)
                VALUES (?,?,?,?,?,?,?,?,?)
                """,
                (
                    task_id,
                    actor,
                    event_type,
                    from_stage,
                    to_stage,
                    note,
                    evidence_url,
                    _json(actual_changes),
                    utcnow(),
                ),
            )
        conn.commit()

    return task_detail(task_id)


def create_task(
    mission_id: int,
    actor: str,
    fields: dict[str, Any],
    note: str | None = None,
) -> dict[str, Any]:
    """Create a task on a mission — used by the monitoring board to turn a
    real portal gap into trackable work. Portal links must already be
    canonical /node/N URLs; the same-node pair rule is enforced here.

    App-created tasks take negative spreadsheet rows so a later re-seed of
    the spreadsheet can never collide with or overwrite them.
    """
    with connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        mission = conn.execute(
            "SELECT id, workflow_json FROM mission WHERE id=?", (mission_id,)
        ).fetchone()
        if not mission:
            raise KeyError("mission_not_found")
        try:
            mission_workflow = json.loads(mission["workflow_json"] or "[]")
        except (TypeError, ValueError):
            mission_workflow = []
        # The first stage belongs to the mission's own workflow — other
        # missions may not start at the global Triagem.
        initial_stage = (
            mission_workflow[0] if mission_workflow else WORKFLOW[0]
        )

        nids = {
            nid
            for nid in (
                _link_nid(fields.get("public_url")),
                _link_nid(fields.get("edit_url")),
            )
            if nid
        }
        if len(nids) > 1:
            raise ValueError("link_node_mismatch")
        linked_nid = next(iter(nids), None)

        # Negative rows only: MIN over the whole mission could be a positive
        # sheet row (min=2 → next=1), which a later re-seed could overwrite.
        next_row = conn.execute(
            "SELECT COALESCE(MIN(spreadsheet_row), 0) - 1 "
            "FROM mission_task WHERE mission_id=? AND spreadsheet_row < 0",
            (mission_id,),
        ).fetchone()[0]
        now = utcnow()
        cursor = conn.execute(
            """
            INSERT INTO mission_task (
                mission_id, spreadsheet_row, source_record_id, priority,
                content_type, title, public_url, edit_url, gaps, action,
                responsible, status, primary_owner, cross_reviewer,
                current_stage, internal_deadline, observations,
                gap_bundle, gap_fields, created_at, updated_at
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            (
                mission_id,
                next_row,
                (
                    # The export uses source_record_id as its ID column;
                    # keep it unique even for repeated tasks of the same
                    # node (the negative row is unique per creation).
                    f"portal_gap:{linked_nid or 'unlinked'}:{-next_row}"
                    if fields.get("gap_bundle")
                    else f"app:{-next_row}"
                ),
                # NULL priority sorts after every P0-P2 row and would fall
                # outside the app's first page — default to the mid bucket.
                fields.get("priority") or "P1",
                fields.get("content_type"),
                fields["title"],
                fields.get("public_url"),
                fields.get("edit_url"),
                fields.get("gaps"),
                fields.get("action"),
                fields.get("responsible"),
                fields.get("status") or "A fazer",
                fields.get("primary_owner"),
                fields.get("cross_reviewer"),
                initial_stage,
                fields.get("internal_deadline"),
                fields.get("observations"),
                fields.get("gap_bundle"),
                _json(fields.get("gap_fields") or []),
                now,
                now,
            ),
        )
        task_id = int(cursor.lastrowid)
        conn.execute(
            """
            INSERT INTO mission_event
            (task_id,actor,event_type,from_stage,to_stage,note,changes_json,created_at)
            VALUES (?,?,?,?,?,?,?,?)
            """,
            (
                task_id,
                actor,
                "task_created",
                None,
                initial_stage,
                note,
                _json({}),
                now,
            ),
        )
        conn.commit()

    return task_detail(task_id)


def set_check_result(
    task_id: int,
    kind: str,
    item_order: int,
    completed: bool,
    actor: str,
    note: str | None = None,
) -> dict[str, Any]:
    with connect() as conn:
        template = conn.execute(
            "SELECT 1 FROM checklist_template WHERE kind=? AND item_order=?",
            (kind, item_order),
        ).fetchone()
        if not template:
            raise KeyError("checklist_item_not_found")
        task = conn.execute("SELECT current_stage FROM mission_task WHERE id=?", (task_id,)).fetchone()
        if not task:
            raise KeyError("task_not_found")

        conn.execute(
            """
            INSERT INTO task_check_result
            (task_id,kind,item_order,completed,completed_by,completed_at,note)
            VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(task_id,kind,item_order) DO UPDATE SET
              completed=excluded.completed,
              completed_by=excluded.completed_by,
              completed_at=excluded.completed_at,
              note=excluded.note
            """,
            (
                task_id,
                kind,
                item_order,
                1 if completed else 0,
                actor,
                utcnow() if completed else None,
                note,
            ),
        )
        conn.execute(
            """
            INSERT INTO mission_event
            (task_id,actor,event_type,from_stage,to_stage,note,changes_json,created_at)
            VALUES (?,?,?,?,?,?,?,?)
            """,
            (
                task_id,
                actor,
                "checklist_updated",
                task["current_stage"],
                task["current_stage"],
                note,
                _json({"kind": kind, "item_order": item_order, "completed": completed}),
                utcnow(),
            ),
        )
        conn.commit()
    return task_detail(task_id)


def _evidence_dir(task_id: int) -> Path:
    return DATA_DIR / "evidence" / str(task_id)


def _evidence_row(row: sqlite3.Row) -> dict[str, Any]:
    item = dict(row)
    item.pop("stored_name", None)
    item["download_url"] = f"/mission-evidence/{item['id']}"
    return item


def add_evidence_file(
    task_id: int,
    actor: str,
    filename: str,
    content: bytes,
    content_type: str | None = None,
    note: str | None = None,
) -> dict[str, Any]:
    safe_name = re.sub(r"[^A-Za-z0-9._-]", "_", Path(filename).name) or "evidence.bin"
    digest = hashlib.sha256(content).hexdigest()
    stored_name = f"{secrets.token_hex(8)}-{safe_name}"

    with connect() as conn:
        task = conn.execute(
            "SELECT current_stage FROM mission_task WHERE id=?", (task_id,)
        ).fetchone()
        if not task:
            raise KeyError("task_not_found")

        target_dir = _evidence_dir(task_id)
        target_dir.mkdir(parents=True, exist_ok=True)
        (target_dir / stored_name).write_bytes(content)

        cur = conn.execute(
            """
            INSERT INTO task_evidence_file
            (task_id,filename,stored_name,content_type,size_bytes,sha256,note,uploaded_by,created_at)
            VALUES (?,?,?,?,?,?,?,?,?)
            """,
            (
                task_id,
                safe_name,
                stored_name,
                content_type,
                len(content),
                digest,
                note,
                actor,
                utcnow(),
            ),
        )
        evidence_id = int(cur.lastrowid)
        conn.execute(
            """
            INSERT INTO mission_event
            (task_id,actor,event_type,from_stage,to_stage,note,evidence_url,changes_json,created_at)
            VALUES (?,?,?,?,?,?,?,?,?)
            """,
            (
                task_id,
                actor,
                "evidence_registered",
                task["current_stage"],
                task["current_stage"],
                note,
                f"/mission-evidence/{evidence_id}",
                _json({"file": safe_name, "sha256": digest, "size_bytes": len(content)}),
                utcnow(),
            ),
        )
        conn.commit()

    return get_evidence_file(evidence_id)


def list_evidence_files(task_id: int) -> list[dict[str, Any]]:
    with connect() as conn:
        rows = conn.execute(
            "SELECT * FROM task_evidence_file WHERE task_id=? ORDER BY id",
            (task_id,),
        ).fetchall()
    return [_evidence_row(row) for row in rows]


def get_evidence_file(evidence_id: int) -> dict[str, Any]:
    with connect() as conn:
        row = conn.execute(
            "SELECT * FROM task_evidence_file WHERE id=?", (evidence_id,)
        ).fetchone()
    if not row:
        raise KeyError("evidence_not_found")
    return _evidence_row(row)


def evidence_file_path(evidence_id: int) -> Path:
    with connect() as conn:
        row = conn.execute(
            "SELECT task_id, stored_name FROM task_evidence_file WHERE id=?",
            (evidence_id,),
        ).fetchone()
    if not row:
        raise KeyError("evidence_not_found")
    path = _evidence_dir(int(row["task_id"])) / row["stored_name"]
    if not path.is_file():
        raise FileNotFoundError("evidence_blob_missing")
    return path


def get_reference(section: str) -> Any:
    with connect() as conn:
        row = conn.execute(
            "SELECT payload_json FROM mission_reference WHERE section=?", (section,)
        ).fetchone()
    if not row:
        raise KeyError("reference_not_found")
    return json.loads(row["payload_json"])


def list_references() -> list[str]:
    with connect() as conn:
        rows = conn.execute(
            "SELECT section FROM mission_reference ORDER BY section"
        ).fetchall()
    return [row["section"] for row in rows]


def list_saved_filters(mission_id: int, actor: str) -> list[dict[str, Any]]:
    with connect() as conn:
        rows = conn.execute(
            """
            SELECT id,name,filters_json,created_at,updated_at
            FROM mission_saved_filter
            WHERE mission_id=? AND actor=?
            ORDER BY name
            """,
            (mission_id, actor),
        ).fetchall()
    return [{**dict(row), "filters": json.loads(row["filters_json"])} for row in rows]


def save_filter(
    mission_id: int,
    actor: str,
    name: str,
    filters: dict[str, str],
) -> dict[str, Any]:
    clean_name = name.strip()
    if not clean_name:
        raise ValueError("filter name is required")
    now = utcnow()
    with connect() as conn:
        exists = conn.execute("SELECT 1 FROM mission WHERE id=?", (mission_id,)).fetchone()
        if not exists:
            raise KeyError("mission_not_found")
        conn.execute(
            """
            INSERT INTO mission_saved_filter(mission_id,actor,name,filters_json,created_at,updated_at)
            VALUES (?,?,?,?,?,?)
            ON CONFLICT(mission_id,actor,name) DO UPDATE SET
              filters_json=excluded.filters_json,
              updated_at=excluded.updated_at
            """,
            (mission_id, actor, clean_name, _json(filters), now, now),
        )
        row = conn.execute(
            """
            SELECT id,name,filters_json,created_at,updated_at
            FROM mission_saved_filter
            WHERE mission_id=? AND actor=? AND name=?
            """,
            (mission_id, actor, clean_name),
        ).fetchone()
        conn.commit()
    return {**dict(row), "filters": json.loads(row["filters_json"])}


def delete_saved_filter(mission_id: int, filter_id: int, actor: str) -> None:
    with connect() as conn:
        deleted = conn.execute(
            """
            DELETE FROM mission_saved_filter
            WHERE id=? AND mission_id=? AND actor=?
            """,
            (filter_id, mission_id, actor),
        ).rowcount
        conn.commit()
    if not deleted:
        raise KeyError("saved_filter_not_found")


def weekly_report(mission_id: int) -> dict[str, Any]:
    summary = dashboard(mission_id)
    cutoff = (datetime.now(timezone.utc) - timedelta(days=7)).isoformat()
    with connect() as conn:
        task_events = conn.execute(
            """
            SELECT e.event_type,e.actor,e.created_at,t.title
            FROM mission_event e
            JOIN mission_task t ON t.id=e.task_id
            WHERE t.mission_id=? AND e.created_at>=?
            ORDER BY e.created_at DESC
            """,
            (mission_id, cutoff),
        ).fetchall()
        work_events = conn.execute(
            """
            SELECT e.event_type,e.actor,e.created_at,w.title
            FROM mission_work_event e
            JOIN mission_work_item w ON w.id=e.work_item_id
            WHERE w.mission_id=? AND e.created_at>=?
            ORDER BY e.created_at DESC
            """,
            (mission_id, cutoff),
        ).fetchall()
    events = [dict(event) for event in [*task_events, *work_events]]
    events.sort(key=lambda event: event["created_at"], reverse=True)
    return {
        "generated_at": utcnow(),
        "period_start": cutoff,
        "summary": {
            key: summary[key]
            for key in (
                "total_tasks",
                "concluded",
                "progress_percent",
                "overall_total",
                "overall_concluded",
                "overall_progress_percent",
                "overdue",
                "upcoming",
                "by_owner",
                "by_stage",
            )
        },
        "recent_events": events,
    }


def export_tasks_xlsx(mission_id: int) -> bytes:
    dashboard(mission_id)
    # App-created tasks can grow the mission past the 500-row page —
    # export must paginate instead of silently truncating the workbook.
    items: list[dict[str, Any]] = []
    offset = 0
    while True:
        page = list_tasks(mission_id, limit=500, offset=offset)["items"]
        items.extend(page)
        if len(page) < 500:
            break
        offset += 500
    headers = [
        "ID",
        "Linha",
        "Prioridade",
        "Tipo",
        "Título",
        "Responsável",
        "Revisor cruzado",
        "Etapa",
        "Prazo interno",
        "Status do prazo",
        "Evidência",
        "Fonte confirmada",
        "Observações",
    ]
    rows = [
        [
            item.get("source_record_id"),
            item.get("spreadsheet_row"),
            item.get("priority"),
            item.get("content_type"),
            item.get("title"),
            item.get("primary_owner") or item.get("responsible"),
            item.get("cross_reviewer"),
            item.get("current_stage"),
            item.get("deadline_date") or item.get("internal_deadline"),
            item.get("deadline_status"),
            item.get("evidence"),
            item.get("confirmed_source"),
            item.get("observations"),
        ]
        for item in items
    ]

    def cell(column: int, row: int, value: Any) -> str:
        ref = f"{chr(65 + column)}{row}"
        return f'<c r="{ref}" t="inlineStr"><is><t>{xml_escape(str(value or ""))}</t></is></c>'

    sheet_rows = [
        f'<row r="1">{"".join(cell(column, 1, value) for column, value in enumerate(headers))}</row>'
    ]
    for row_number, values in enumerate(rows, start=2):
        sheet_rows.append(
            f'<row r="{row_number}">'
            f'{"".join(cell(column, row_number, value) for column, value in enumerate(values))}'
            "</row>"
        )
    worksheet = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        f"<sheetData>{''.join(sheet_rows)}</sheetData></worksheet>"
    )
    workbook = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="Controle Master" sheetId="1" r:id="rId1"/></sheets></workbook>'
    )
    content_types = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        "</Types>"
    )
    root_rels = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
        'Target="xl/workbook.xml"/></Relationships>'
    )
    workbook_rels = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
        'Target="worksheets/sheet1.xml"/></Relationships>'
    )
    output = BytesIO()
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("[Content_Types].xml", content_types)
        archive.writestr("_rels/.rels", root_rels)
        archive.writestr("xl/workbook.xml", workbook)
        archive.writestr("xl/_rels/workbook.xml.rels", workbook_rels)
        archive.writestr("xl/worksheets/sheet1.xml", worksheet)
    return output.getvalue()


init_db()


# Extensão da missão: pacotes de trabalho complementares das demais abas.

def dashboard(mission_id: int) -> dict[str, Any]:
    with connect() as conn:
        mission = conn.execute(
            "SELECT * FROM mission WHERE id=?", (mission_id,)
        ).fetchone()
        if not mission:
            raise KeyError("mission_not_found")

        tasks = conn.execute(
            """
            SELECT priority,content_type,current_stage,primary_owner,
                   responsible,internal_deadline
            FROM mission_task WHERE mission_id=?
            """,
            (mission_id,),
        ).fetchall()
        work_items = conn.execute(
            """
            SELECT section,completed,status
            FROM mission_work_item WHERE mission_id=?
            """,
            (mission_id,),
        ).fetchall()
        event_count = conn.execute(
            """
            SELECT COUNT(*) FROM mission_event e
            JOIN mission_task t ON t.id=e.task_id
            WHERE t.mission_id=?
            """,
            (mission_id,),
        ).fetchone()[0]
        work_event_count = conn.execute(
            """
            SELECT COUNT(*) FROM mission_work_event e
            JOIN mission_work_item w ON w.id=e.work_item_id
            WHERE w.mission_id=?
            """,
            (mission_id,),
        ).fetchone()[0]

    stages = Counter((row["current_stage"] or "Sem etapa") for row in tasks)
    priorities = Counter((row["priority"] or "Sem prioridade") for row in tasks)
    types = Counter((row["content_type"] or "Sem tipo") for row in tasks)
    owners = Counter(
        (row["primary_owner"] or row["responsible"] or "Não atribuído")
        for row in tasks
    )
    work_sections = Counter((row["section"] or "Outros") for row in work_items)

    total = len(tasks)
    concluded = stages.get("Concluído", 0)
    overdue = sum(
        _deadline_status(_deadline_date(row["internal_deadline"]), row["current_stage"])
        == "overdue"
        for row in tasks
    )
    upcoming = sum(
        _deadline_status(_deadline_date(row["internal_deadline"]), row["current_stage"])
        == "upcoming"
        for row in tasks
    )
    work_total = len(work_items)
    work_concluded = sum(1 for row in work_items if bool(row["completed"]))
    overall_total = total + work_total
    overall_concluded = concluded + work_concluded

    result = dict(mission)
    result["workflow"] = json.loads(result.pop("workflow_json"))
    result.update(
        {
            "total_tasks": total,
            "concluded": concluded,
            "progress_percent": round((concluded / total) * 100, 1)
            if total
            else 0,
            "work_total": work_total,
            "work_concluded": work_concluded,
            "work_progress_percent": round(
                (work_concluded / work_total) * 100, 1
            )
            if work_total
            else 0,
            "overall_total": overall_total,
            "overall_concluded": overall_concluded,
            "overall_progress_percent": round(
                (overall_concluded / overall_total) * 100, 1
            )
            if overall_total
            else 0,
            "by_stage": dict(stages),
            "by_priority": dict(priorities),
            "by_type": dict(types),
            "by_owner": dict(owners),
            "overdue": overdue,
            "upcoming": upcoming,
            "work_by_section": dict(work_sections),
            "event_count": event_count,
            "work_event_count": work_event_count,
        }
    )
    return result


def list_work_items(
    mission_id: int,
    *,
    section: str | None = None,
    completed: bool | None = None,
) -> dict[str, Any]:
    where = ["mission_id=?"]
    args: list[Any] = [mission_id]
    if section:
        where.append("section=?")
        args.append(section)
    if completed is not None:
        where.append("completed=?")
        args.append(1 if completed else 0)
    clause = " AND ".join(where)

    with connect() as conn:
        rows = conn.execute(
            f"""
            SELECT * FROM mission_work_item
            WHERE {clause}
            ORDER BY section, spreadsheet_row
            """,
            args,
        ).fetchall()

    items = []
    for row in rows:
        item = dict(row)
        item["completed"] = bool(item["completed"])
        item["payload"] = json.loads(item.pop("payload_json"))
        items.append(item)
    return {"total": len(items), "items": items}


def work_item_detail(work_item_id: int) -> dict[str, Any]:
    with connect() as conn:
        row = conn.execute(
            "SELECT * FROM mission_work_item WHERE id=?",
            (work_item_id,),
        ).fetchone()
        if not row:
            raise KeyError("work_item_not_found")
        events = conn.execute(
            """
            SELECT * FROM mission_work_event
            WHERE work_item_id=?
            ORDER BY id DESC
            """,
            (work_item_id,),
        ).fetchall()

    item = dict(row)
    item["completed"] = bool(item["completed"])
    item["payload"] = json.loads(item.pop("payload_json"))
    item["events"] = [dict(event) for event in events]
    return item


def update_work_item(
    work_item_id: int,
    *,
    actor: str,
    completed: bool | None = None,
    status: str | None = None,
    evidence: str | None = None,
    note: str | None = None,
) -> dict[str, Any]:
    with connect() as conn:
        before = conn.execute(
            "SELECT * FROM mission_work_item WHERE id=?",
            (work_item_id,),
        ).fetchone()
        if not before:
            raise KeyError("work_item_not_found")

        assignments = []
        args: list[Any] = []
        changes: dict[str, Any] = {}

        candidates = {
            "completed": None if completed is None else (1 if completed else 0),
            "status": status,
            "evidence": evidence,
            "note": note,
        }
        for field, value in candidates.items():
            if value is None:
                continue
            if before[field] != value:
                assignments.append(f"{field}=?")
                args.append(value)
                changes[field] = {
                    "from": before[field],
                    "to": value,
                }

        if assignments:
            assignments.append("updated_at=?")
            args.append(utcnow())
            args.append(work_item_id)
            conn.execute(
                f"""
                UPDATE mission_work_item
                SET {', '.join(assignments)}
                WHERE id=?
                """,
                args,
            )

        if changes:
            conn.execute(
                """
                INSERT INTO mission_work_event
                (work_item_id,actor,event_type,note,changes_json,created_at)
                VALUES (?,?,?,?,?,?)
                """,
                (
                    work_item_id,
                    actor,
                    "work_item_updated",
                    note,
                    _json(changes),
                    utcnow(),
                ),
            )
        conn.commit()

    return work_item_detail(work_item_id)
