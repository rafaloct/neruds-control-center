import pytest
import review_store


def test_register_and_get_draft(temp_db):
    review = review_store.register_draft(
        "101",
        title="Notícia de Teste 101",
        author="extensionista.1",
        opportunity_item_id=12,
        mission_task_id=8,
    )
    assert review["drupal_nid"] == "101"
    assert review["title"] == "Notícia de Teste 101"
    assert review["author"] == "extensionista.1"
    assert review["review_status"] == "pending"
    assert review["opportunity_item_id"] == 12
    assert review["mission_task_id"] == 8
    assert len(review["events"]) == 1
    assert review["events"][0]["event_type"] == "draft_registered"

    fetched = review_store.get_review("101")
    assert fetched is not None
    assert fetched["drupal_nid"] == "101"


def test_ensure_draft(temp_db):
    # Register first
    d1 = review_store.ensure_draft("202", title="Rascunho Inicial", author="extensionista.2")
    assert d1["drupal_nid"] == "202"
    assert d1["title"] == "Rascunho Inicial"

    # Call ensure_draft again -> returns same draft without overwriting status
    d2 = review_store.ensure_draft("202", title="Título Alterado", author="outro.autor")
    assert d2["drupal_nid"] == "202"
    assert d2["title"] == "Rascunho Inicial"


def test_register_draft_missing_nid(temp_db):
    with pytest.raises(ValueError, match="drupal_nid is required"):
        review_store.register_draft("", title="Sem NID", author="autor")

    with pytest.raises(ValueError, match="drupal_nid is required"):
        review_store.ensure_draft("   ", title="Sem NID", author="autor")


def test_review_decision_flow(temp_db):
    review_store.register_draft("303", title="Rascunho 303", author="extensionista.1")

    # Revisor requests changes
    devolution = review_store.decide(
        "303",
        actor="revisor.1",
        status="changes_requested",
        note="Ajustar o resumo e incluir a fonte de financiamento.",
    )
    assert devolution["review_status"] == "changes_requested"
    assert devolution["reviewer"] == "revisor.1"
    assert devolution["review_note"] == "Ajustar o resumo e incluir a fonte de financiamento."

    # Extensionista adjusts and re-submits (status back to pending)
    resubmitted = review_store.decide(
        "303",
        actor="extensionista.1",
        status="pending",
        note="Resumo ajustado e fonte adicionada.",
    )
    assert resubmitted["review_status"] == "pending"

    # Revisor approves
    approved = review_store.decide(
        "303",
        actor="revisor.1",
        status="approved",
        note="Aprovado para publicação.",
    )
    assert approved["review_status"] == "approved"

    # Coordenador publishes
    published = review_store.mark_published("303", actor="coordenador.1")
    assert published["review_status"] == "published"
    assert published["published_at"] is not None


def test_review_decision_invalid_status(temp_db):
    review_store.register_draft("404", title="Rascunho 404", author="ext")

    with pytest.raises(ValueError, match="invalid review status"):
        review_store.decide("404", actor="revisor", status="invalid_status", note="Nota")


def test_mark_published_missing_draft(temp_db):
    with pytest.raises(KeyError, match="99999"):
        review_store.mark_published("99999", actor="coordenador")


def test_published_draft_cannot_return_to_review(temp_db):
    review_store.register_draft("505", title="Publicado", author="extensionista.1")
    review_store.mark_published("505", actor="coordenador.1")

    with pytest.raises(ValueError, match="published drafts"):
        review_store.decide("505", actor="revisor.1", status="approved", note="Reabrir")
