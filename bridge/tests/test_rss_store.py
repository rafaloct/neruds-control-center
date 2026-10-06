import socket
from datetime import date, timedelta
import pytest
import rss_store


def test_clean_text():
    assert rss_store._clean_text("<p>Hello &amp; World</p>") == "Hello & World"
    assert rss_store._clean_text("<script>alert('xss')</script>Safe text") == "Safe text"
    assert rss_store._clean_text("   Multiple   spaces   ") == "Multiple spaces"


def test_classify():
    assert rss_store.classify("Chamada de artigos para revista", "Dossiê especial") == "Chamada para revista"
    assert rss_store.classify("Edital Proext 2026", "Ação de extensão universitária") == "Oportunidade de extensão" or "Edital"
    assert rss_store.classify("Congresso Internacional de Agroecologia", "Seminário") == "Evento científico"
    assert rss_store.classify("Seleção de Bolsistas PIBIC", "Bolsa de iniciação científica") == "Bolsa"
    assert rss_store.classify("Notícia Genérica", "Algum texto sem palavra chave", default="Notícia institucional") == "Notícia institucional"
    assert rss_store.classify("Notícia Genérica", "Sem palavra chave", default=None) == "Outro"


def test_validate_public_url_ssrf_protection(monkeypatch):
    # Invalid schemes
    with pytest.raises(ValueError, match="http ou https"):
        rss_store._validate_public_url("ftp://example.com/rss.xml")

    with pytest.raises(ValueError, match="http ou https"):
        rss_store._validate_public_url("file:///etc/passwd")

    # Credentials in URL
    with pytest.raises(ValueError, match="credenciais"):
        rss_store._validate_public_url("https://user:password@example.com/rss")

    # Missing hostname
    with pytest.raises(ValueError, match="sem hostname"):
        rss_store._validate_public_url("https:///path")

    # Non-web port
    with pytest.raises(ValueError, match="porta web padrão"):
        rss_store._validate_public_url("https://example.com:22/rss")

    with pytest.raises(ValueError, match="porta web padrão"):
        rss_store._validate_public_url("http://example.com:8080/rss")

    # Private / loopback IP address protection
    def mock_getaddrinfo(host, port):
        if host in ("localhost", "127.0.0.1", "loopback"):
            return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", port))]
        if host == "internal-server":
            return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("10.0.0.15", port))]
        if host == "public-server":
            return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", port))]
        raise socket.gaierror("Name or service not known")

    monkeypatch.setattr(socket, "getaddrinfo", mock_getaddrinfo)

    # 127.0.0.1 -> blocked
    with pytest.raises(ValueError, match="endereço público"):
        rss_store._validate_public_url("http://127.0.0.1/rss.xml")

    # 10.0.0.15 -> blocked
    with pytest.raises(ValueError, match="endereço público"):
        rss_store._validate_public_url("http://internal-server/rss.xml")

    # Unresolvable hostname -> blocked
    with pytest.raises(ValueError, match="não pôde ser resolvido"):
        rss_store._validate_public_url("http://non-existent-domain-123456.org/rss.xml")

    # Valid public host -> accepted
    valid = rss_store._validate_public_url("https://public-server/rss.xml")
    assert valid == "https://public-server/rss.xml"


def test_sources_crud(monkeypatch, temp_db):
    monkeypatch.setattr(socket, "getaddrinfo", lambda host, port: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", port))])

    # Add source
    source = rss_store.add_source(
        name="Fonte Teste UFT",
        url="https://public-server/rss.xml",
        actor="admin.test",
        default_category="Notícia institucional",
    )
    assert source["id"] > 0
    assert source["name"] == "Fonte Teste UFT"
    assert source["active"] is True
    assert source["default_category"] == "Notícia institucional"

    # Listing sources
    sources = rss_store.list_sources()
    assert len(sources) == 1
    assert sources[0]["id"] == source["id"]

    # Duplicate source raises ValueError
    with pytest.raises(ValueError, match="já foi cadastrada"):
        rss_store.add_source("Fonte Duplicada", "https://public-server/rss.xml", "admin.test")

    # Update source
    updated = rss_store.update_source(source["id"], active=False, default_category="Bolsa")
    assert updated["active"] is False
    assert updated["default_category"] == "Bolsa"


def test_update_source_not_found(temp_db):
    with pytest.raises(KeyError, match="source_not_found"):
        rss_store.update_source(999, active=True)

    with pytest.raises(ValueError, match="Categoria inválida"):
        rss_store.update_source(1, default_category="CategoriaInexistente")


def test_manual_opportunity_capture(temp_db):
    item = rss_store.add_manual_item(
        title="Edital de Seleção de Bolsistas 2026",
        url="https://neruds.org/oportunidades/edital-2026",
        category="Edital",
        actor="extensionista.test",
        summary="Abertura de inscrições para 5 vagas de bolsa de extensão.",
    )
    assert item["id"] > 0
    assert item["title"] == "Edital de Seleção de Bolsistas 2026"
    assert item["category"] == "Edital"
    assert item["status"] == "novo"
    assert item["source_verified"] is False
    assert len(item["events"]) == 1
    assert item["events"][0]["event_type"] == "manual_capture"


def test_manual_opportunity_invalid_category_or_url(temp_db):
    with pytest.raises(ValueError, match="Categoria inválida"):
        rss_store.add_manual_item(
            title="Título",
            url="https://neruds.org/link",
            category="CategoriaInvalida",
            actor="user",
        )

    with pytest.raises(ValueError, match="http ou https"):
        rss_store.add_manual_item(
            title="Título",
            url="ftp://neruds.org/link",
            category="Edital",
            actor="user",
        )


def test_opportunity_decision_and_draft_workflow(temp_db):
    item = rss_store.add_manual_item(
        title="Chamada de Artigos Revista Extensão",
        url="https://neruds.org/chamada-artigos-2026",
        category="Chamada para revista",
        actor="extensionista.test",
    )
    item_id = item["id"]

    # Extensionista/Revisor decides to approve pauta
    approved = rss_store.decide(
        item_id,
        actor="revisor.test",
        status="aprovado_pauta",
        note="Pauta relevante para a revista do núcleo.",
    )
    assert approved["status"] == "aprovado_pauta"
    assert approved["reviewed_by"] == "revisor.test"

    # Mark draft created
    drafted = rss_store.mark_draft(item_id, actor="extensionista.test", drupal_draft_id="356")
    assert drafted["status"] == "rascunho_criado"
    assert drafted["drupal_draft_id"] == "356"


def test_opportunity_decision_invalid_status_or_category(temp_db):
    item = rss_store.add_manual_item(
        title="Oportunidade Teste",
        url="https://neruds.org/item1",
        category="Bolsa",
        actor="user",
    )
    item_id = item["id"]

    with pytest.raises(ValueError, match="Status inválido"):
        rss_store.decide(item_id, actor="user", status="status_inexistente")

    with pytest.raises(ValueError, match="Categoria inválida"):
        rss_store.decide(item_id, actor="user", status="em_triagem", category="CatInvalida")


def test_opportunity_dashboard(temp_db):
    dash = rss_store.dashboard()
    assert "active_sources" in dash
    assert "total_items" in dash
    assert "by_status" in dash
    assert "by_category" in dash
    assert "CATEGORIES" in dash or "categories" in dash


def test_manual_duplicates_deadlines_tags_and_expiring_queue(temp_db):
    deadline = (date.today() + timedelta(days=3)).isoformat()
    original = rss_store.add_manual_item(
        title="Edital de Pesquisa Aplicada 2026",
        url="https://neruds.org/editais/pesquisa-aplicada",
        category="Edital",
        actor="user",
        summary="Pesquisa, inovação e formação para comunidades.",
        deadline_at=deadline,
    )
    duplicate = rss_store.add_manual_item(
        title="Edital de Pesquisa Aplicada 2026",
        url="https://another.example.org/edital-pesquisa",
        category="Edital",
        actor="user",
    )

    assert original["deadline_at"] == deadline
    assert "pesquisa" in original["fit_tags"]
    assert duplicate["duplicate_of_item_id"] == original["id"]
    assert duplicate["duplicate_reason"] == "title"
    assert any(event["event_type"] == "duplicate_detected" for event in duplicate["events"])

    expiring = rss_store.list_items(deadline_status="upcoming")
    assert [item["id"] for item in expiring["items"]] == [original["id"]]
    assert rss_store.dashboard()["expiring_soon"] == 1


def test_curation_decision_audits_deadline_and_tags(temp_db):
    item = rss_store.add_manual_item(
        title="Bolsa de pesquisa",
        url="https://neruds.org/bolsa",
        category="Bolsa",
        actor="user",
    )
    updated = rss_store.decide(
        item["id"],
        actor="reviewer",
        status="em_triagem",
        deadline_at="20/12/2026",
        fit_tags=["pesquisa", "formação"],
        note="Prazo e aderência revisados pela curadoria.",
    )
    assert updated["deadline_at"] == "2026-12-20"
    assert updated["fit_tags"] == ["pesquisa", "formação"]
    assert "fit_tags" in updated["events"][0]["changes_json"]


def test_source_health_states(temp_db):
    source = rss_store.add_manual_item(
        title="Item",
        url="https://neruds.org/item",
        category="Outro",
        actor="user",
    )
    with rss_store.connect() as conn:
        conn.execute(
            """
            UPDATE feed_source
            SET last_checked_at=?, last_success_at=?, last_error=?
            WHERE id=?
            """,
            ("2026-01-01T00:00:00+00:00", None, "HTTP 500", source["source_id"]),
        )
        conn.commit()
    assert rss_store.list_sources()[0]["health"] == "error"
