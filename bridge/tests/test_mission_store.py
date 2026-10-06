import hashlib
import pytest
import mission_store
import zipfile
from io import BytesIO


def test_seed_from_json(temp_db):
    res = mission_store.seed_from_json(force=True)
    assert res["seeded"] is True
    assert res["mission_id"] == 1
    assert res["inserted_tasks"] > 0
    assert res["total_tasks"] == res["inserted_tasks"]

    # Seeding again without force should not duplicate
    res_second = mission_store.seed_from_json(force=False)
    assert res_second["seeded"] is True
    assert res_second["inserted_tasks"] == 0
    assert res_second["total_tasks"] == res["total_tasks"]


def test_mission_list(seeded_mission):
    missions = mission_store.mission_list()
    assert len(missions) == 1
    m = missions[0]
    assert m["code"] == "GESTAO_PORTAL_NERUDS"
    assert m["total_tasks"] > 0
    assert "workflow" in m
    assert isinstance(m["workflow"], list)
    assert "progress_percent" in m


def test_mission_dashboard(seeded_mission):
    dash = mission_store.dashboard(1)
    assert dash["code"] == "GESTAO_PORTAL_NERUDS"
    assert dash["total_tasks"] > 0
    assert "by_stage" in dash
    assert "by_priority" in dash
    assert "by_type" in dash
    assert "by_owner" in dash
    assert "work_total" in dash
    assert "overall_total" in dash
    assert dash["total_tasks"] == 205
    assert dash["work_total"] == 73
    assert dash["overall_total"] == 278


def test_mission_dashboard_not_found(temp_db):
    with pytest.raises(KeyError, match="mission_not_found"):
        mission_store.dashboard(999)


def test_list_tasks_and_filtering(seeded_mission):
    # Total tasks
    all_tasks = mission_store.list_tasks(1, limit=500)
    assert all_tasks["total"] > 0
    assert len(all_tasks["items"]) == all_tasks["total"]

    # Filter by priority
    p0_tasks = mission_store.list_tasks(1, priority="P0")
    assert p0_tasks["total"] > 0
    for task in p0_tasks["items"]:
        assert task["priority"] == "P0"

    # Filter by stage
    triagem_tasks = mission_store.list_tasks(1, stage="Triagem")
    for task in triagem_tasks["items"]:
        assert task["current_stage"] == "Triagem"

    # Filter by search query
    searched = mission_store.list_tasks(1, query="Contato")
    assert searched["total"] > 0
    assert any("Contato" in t["title"] for t in searched["items"])


def test_task_detail_and_update(seeded_mission):
    tasks = mission_store.list_tasks(1, limit=5)
    first_task_id = tasks["items"][0]["id"]

    detail = mission_store.task_detail(first_task_id)
    assert detail["id"] == first_task_id
    assert "checklists" in detail
    assert "events" in detail

    # Update task fields and stage
    updated = mission_store.update_task(
        first_task_id,
        actor="test.user",
        changes={"current_stage": "Em pesquisa", "priority": "P0"},
        note="Iniciando pesquisa",
        evidence_url="https://example.org/evidence1",
    )
    assert updated["current_stage"] == "Em pesquisa"
    assert updated["priority"] == "P0"

    # Verify event was recorded
    events = updated["events"]
    assert len(events) >= 1
    latest_event = events[0]
    assert latest_event["actor"] == "test.user"
    assert latest_event["from_stage"] == "Triagem" or latest_event["to_stage"] == "Em pesquisa"
    assert latest_event["note"] == "Iniciando pesquisa"
    assert latest_event["evidence_url"] == "https://example.org/evidence1"


def test_task_detail_not_found(temp_db):
    with pytest.raises(KeyError, match="task_not_found"):
        mission_store.task_detail(99999)

    with pytest.raises(KeyError, match="task_not_found"):
        mission_store.update_task(99999, actor="test", changes={"priority": "P1"})


def test_checklist_management(seeded_mission):
    tasks = mission_store.list_tasks(1, limit=1)
    task_id = tasks["items"][0]["id"]

    # Get a valid checklist template item from the DB
    with mission_store.connect() as conn:
        tpl = conn.execute("SELECT kind, item_order FROM checklist_template ORDER BY item_order LIMIT 1").fetchone()
        valid_kind = tpl["kind"]
        valid_order = tpl["item_order"]

    # Mark a checklist item as completed
    updated = mission_store.set_check_result(
        task_id,
        kind=valid_kind,
        item_order=valid_order,
        completed=True,
        actor="checker.user",
        note="Checked ok",
    )
    kind_checks = updated["checklists"].get(valid_kind, [])
    item = next((i for i in kind_checks if i["item_order"] == valid_order), None)
    assert item is not None
    assert item["completed"] is True
    assert item["completed_by"] == "checker.user"
    assert item["note"] == "Checked ok"

    # Uncheck the item
    updated2 = mission_store.set_check_result(
        task_id,
        kind=valid_kind,
        item_order=valid_order,
        completed=False,
        actor="checker.user",
        note="Unchecked",
    )
    item_uncheck = next((i for i in updated2["checklists"][valid_kind] if i["item_order"] == valid_order), None)
    assert item_uncheck["completed"] is False


def test_checklist_item_not_found(seeded_mission):
    tasks = mission_store.list_tasks(1, limit=1)
    task_id = tasks["items"][0]["id"]

    with pytest.raises(KeyError, match="checklist_item_not_found"):
        mission_store.set_check_result(
            task_id,
            kind="non_existent_kind",
            item_order=999,
            completed=True,
            actor="user",
        )


def test_mission_references(seeded_mission):
    refs = mission_store.list_references()
    assert len(refs) > 0
    assert "resumo" in refs
    assert "equipe" in refs

    payload = mission_store.get_reference("resumo")
    assert isinstance(payload, list)


def test_mission_reference_not_found(temp_db):
    with pytest.raises(KeyError, match="reference_not_found"):
        mission_store.get_reference("invalid_section")


def test_work_items(seeded_mission):
    work_items = mission_store.list_work_items(1)
    assert work_items["total"] > 0
    first_item = work_items["items"][0]
    work_item_id = first_item["id"]

    detail = mission_store.work_item_detail(work_item_id)
    assert detail["id"] == work_item_id
    assert "payload" in detail
    assert "events" in detail

    updated = mission_store.update_work_item(
        work_item_id,
        actor="test.user",
        completed=True,
        status="Concluído",
        evidence="https://example.org/work_evidence",
        note="Atividade finalizada",
    )
    assert updated["completed"] is True
    assert updated["status"] == "Concluído"
    assert updated["evidence"] == "https://example.org/work_evidence"
    assert len(updated["events"]) >= 1


def test_work_item_not_found(temp_db):
    with pytest.raises(KeyError, match="work_item_not_found"):
        mission_store.work_item_detail(99999)

    with pytest.raises(KeyError, match="work_item_not_found"):
        mission_store.update_work_item(99999, actor="test", completed=True)


def test_sla_saved_filters_weekly_report_and_xlsx(seeded_mission):
    task = mission_store.list_tasks(1, limit=1)["items"][0]
    mission_store.update_task(
        task["id"],
        actor="test.user",
        changes={"internal_deadline": "2020-01-01"},
        note="Prazo definido",
    )

    overdue = mission_store.list_tasks(1, due_status="overdue", limit=500)
    assert any(item["id"] == task["id"] for item in overdue["items"])
    assert mission_store.dashboard(1)["overdue"] >= 1

    saved = mission_store.save_filter(
        1,
        "test.user",
        "Pendências críticas",
        {"priority": "P0", "due_status": "overdue"},
    )
    assert saved["filters"]["due_status"] == "overdue"
    assert mission_store.list_saved_filters(1, "test.user")[0]["name"] == "Pendências críticas"
    mission_store.delete_saved_filter(1, saved["id"], "test.user")
    assert mission_store.list_saved_filters(1, "test.user") == []

    report = mission_store.weekly_report(1)
    assert report["summary"]["overdue"] >= 1
    assert report["recent_events"]

    workbook = mission_store.export_tasks_xlsx(1)
    with zipfile.ZipFile(BytesIO(workbook)) as archive:
        assert "xl/worksheets/sheet1.xml" in archive.namelist()
        assert "Controle Master" in archive.read("xl/workbook.xml").decode()


def test_evidence_file_lifecycle(seeded_mission, tmp_path):
    task = mission_store.list_tasks(1, limit=1)["items"][0]
    content = b"print-quality-evidence-bytes"

    item = mission_store.add_evidence_file(
        task["id"],
        actor="extensionista.test",
        filename="captura portal.png",
        content=content,
        content_type="image/png",
        note="Print do link público",
    )
    assert item["filename"] == "captura_portal.png"
    assert item["size_bytes"] == len(content)
    assert item["uploaded_by"] == "extensionista.test"
    assert item["sha256"] == hashlib.sha256(content).hexdigest()
    assert item["download_url"] == f"/mission-evidence/{item['id']}"

    files = mission_store.list_evidence_files(task["id"])
    assert len(files) == 1
    assert files[0]["id"] == item["id"]
    assert "stored_name" not in files[0]

    path = mission_store.evidence_file_path(item["id"])
    assert path.read_bytes() == content
    assert path.parent == tmp_path / "evidence" / str(task["id"])

    detail = mission_store.task_detail(task["id"])
    assert detail["evidence_files"][0]["id"] == item["id"]
    assert detail["events"][0]["event_type"] == "evidence_registered"
    assert detail["events"][0]["evidence_url"] == item["download_url"]


def test_evidence_file_requires_task(temp_db):
    with pytest.raises(KeyError):
        mission_store.add_evidence_file(9999, "actor", "a.txt", b"x")


def test_evidence_file_missing_blob(seeded_mission):
    task = mission_store.list_tasks(1, limit=1)["items"][0]
    item = mission_store.add_evidence_file(
        task["id"], "actor", "f.txt", b"data"
    )
    mission_store.evidence_file_path(item["id"]).unlink()
    with pytest.raises(FileNotFoundError):
        mission_store.evidence_file_path(item["id"])
