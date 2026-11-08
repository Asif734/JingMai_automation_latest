from __future__ import annotations

import hashlib
from pathlib import Path

from fastapi.testclient import TestClient

from app.index import RagIndex
from app.knowledge import load_corpus
from app.main import app
from app.media import MediaStore
from app.openai_service import CUSTOMER_CARE_INSTRUCTIONS
from app.risk import assess_risk
from app.schemas import (ConversationMessage, DraftRequest, GeneratedDraft, KnowledgeSelection,
                         MediaSearchPlan, MediaSelection, RequestPlan)
from app.service import RagService
from app.tickets import ConversationPausedError, TicketStore


ROOT = Path(__file__).resolve().parents[2]
KNOWLEDGE = ROOT / "格志京东客服知识库-2026-10-04"


class FakeEmbedder:
    model = "test-embedding"

    def embed(self, texts):
        vectors = []
        for value in texts:
            digest = hashlib.sha256(value.encode()).digest()
            vectors.append([float(byte) for byte in digest[:16]])
        return vectors


def test_loads_all_curated_cards_and_source_chunks():
    corpus = load_corpus(KNOWLEDGE)
    assert len([row for row in corpus.records if row.record_type == "card"]) == 530
    assert len([row for row in corpus.records if row.record_type == "source_chunk"]) == 832
    assert len(corpus.content_hash) == 64
    assert len(corpus.media) == 21


def test_risk_rules_override_generation():
    assert assess_risk("打印机冒烟了").level == "critical"
    assert assess_risk("我要申请退款").level == "high"
    assert assess_risk("怎样设置日期").level == "low"


def test_customer_care_role_supports_greetings_and_grounded_guidance():
    assert "Greet customers warmly" in CUSTOMER_CARE_INSTRUCTIONS
    assert "ordinary greetings" in CUSTOMER_CARE_INSTRUCTIONS
    assert "must come only from the supplied knowledge" in CUSTOMER_CARE_INSTRUCTIONS
    assert "Never guess" in CUSTOMER_CARE_INSTRUCTIONS
    assert "off-topic questions" in CUSTOMER_CARE_INSTRUCTIONS
    assert "text-only" in CUSTOMER_CARE_INSTRUCTIONS


def test_generated_draft_has_strict_nested_action_schema():
    schema = GeneratedDraft.model_json_schema()
    assert schema["additionalProperties"] is False
    action_schema = schema["$defs"]["DraftAction"]
    assert action_schema["additionalProperties"] is False
    assert set(action_schema["properties"]) == {"type", "description"}
    media_schema = schema["$defs"]["DraftMedia"]
    assert media_schema["additionalProperties"] is False
    assert set(media_schema["properties"]) == {"media_id", "kind", "caption"}


def test_contextual_query_keeps_previous_media_intent():
    request = DraftRequest(
        customer_message="M880UT",
        messages=[
            ConversationMessage(direction="incoming", body="I want exterior and screen pictures"),
            ConversationMessage(direction="outgoing", body="Which model?"),
        ],
    )
    query = RagService._contextual_query(request)
    assert "pictures" in query
    assert query.endswith("M880UT")


def test_parameterized_media_search_uses_model_and_view(tmp_path):
    store = MediaStore(tmp_path, load_corpus(KNOWLEDGE))
    internal = store.search(MediaSearchPlan(
        requested=True, query="M880 internal photo", model="M880",
        kinds=["image"], views=["internal"],
    ))
    assert any(item.filename == "m880_rear_cover_removed_without_battery.png" for item in internal)
    exterior = store.search(MediaSearchPlan(
        requested=True, query="M880 exterior photo", model="M880",
        kinds=["image"], views=["exterior"],
    ))
    assert exterior == []
    unverified, total = store.catalog(verified=False)
    assert total > 18
    assert unverified
    assert all(not item.customer_send_allowed for item in unverified)


def test_lexical_retrieval_uses_product_and_model(tmp_path):
    corpus = load_corpus(KNOWLEDGE)
    index = RagIndex(tmp_path, corpus)
    rows = index.search("TD630G 在 Mac 怎么无线打印", None, limit=5,
                        product_line="dot_matrix_printer", model="TD630G")
    assert rows
    assert rows[0]["record"].id == "dot_matrix_td630g_mac_usb_only"


def test_request_planning_and_media_selection_are_strict_schemas():
    request_schema = RequestPlan.model_json_schema()
    selection_schema = MediaSelection.model_json_schema()
    assert request_schema["additionalProperties"] is False
    assert selection_schema["additionalProperties"] is False
    assert set(selection_schema["properties"]) == {"selected_media_ids", "reason"}
    assert KnowledgeSelection.model_json_schema()["additionalProperties"] is False


def test_builds_and_reloads_faiss_index(tmp_path):
    corpus = load_corpus(KNOWLEDGE)
    index = RagIndex(tmp_path, corpus)
    count, dimensions = index.rebuild(FakeEmbedder())
    assert count == 1362
    assert dimensions == 16
    assert (tmp_path / "metadata.sqlite3").is_file()
    assert RagIndex(tmp_path, corpus).ready


def test_api_runs_without_openai_key(monkeypatch, tmp_path):
    monkeypatch.setenv("KNOWLEDGE_DIR", str(KNOWLEDGE))
    monkeypatch.setenv("RAG_DATA_DIR", str(tmp_path))
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.setenv("RAG_ADMIN_TOKEN", "test-admin-token")
    with TestClient(app) as client:
        tester = client.get("/tester")
        assert tester.status_code == 200
        assert "JD Seller RAG Tester" in tester.text
        health = client.get("/health")
        assert health.status_code == 200
        assert health.json()["records"] == 1362
        result = client.post("/v1/retrieve", json={"query": "怎么设置日期"})
        assert result.status_code == 200
        assert result.json()["hits"]
        media = client.get("/v1/media?query=battery")
        assert media.status_code == 200
        upload = client.post(
            "/v1/media/upload",
            data={"conversation_id": "media-test", "caption": "客户截图"},
            files={"file": ("screen.png", b"\x89PNG\r\n\x1a\ncontent", "image/png")},
        )
        assert upload.status_code == 200
        uploaded = upload.json()
        assert uploaded["source"] == "customer"
        assert client.get(uploaded["url"]).status_code == 200
        draft = client.post("/v1/replies/draft", json={"customer_message": "你好"})
        assert draft.status_code == 503
        unauthorized = client.get("/v1/history")
        assert unauthorized.status_code == 403
        history = client.get(
            "/v1/history?limit=5",
            headers={"X-Admin-Token": "test-admin-token"},
        )
        assert history.status_code == 200
        assert len(history.json()["items"]) == 1
        assert history.json()["items"][0]["customer_message"] == "你好"
        assert history.json()["items"][0]["status"] == "error"
        rebuild = client.post("/v1/index/rebuild")
        assert rebuild.status_code == 403


def test_ticket_lifecycle_pauses_then_waits_for_new_customer_message(tmp_path):
    store = TicketStore(tmp_path)
    ticket = store.create_or_get("conversation-1", "Send setup video", "Verified video missing")
    assert ticket.status == "open"
    assert store.create_or_get("conversation-1", "duplicate", "duplicate").id == ticket.id
    store.ensure_ai_may_reply("conversation-1", "message-1")

    contacting = store.mark_contacting(ticket.id, "agent-1")
    assert contacting.status == "contacting"
    try:
        store.ensure_ai_may_reply("conversation-1", "message-2")
        assert False, "AI must be paused while a human is contacting the customer"
    except ConversationPausedError:
        pass

    contacted = store.mark_contacted(ticket.id, "message-2", "Sent official video")
    assert contacted.status == "contacted"
    try:
        store.ensure_ai_may_reply("conversation-1", "message-2")
        assert False, "AI must not answer the message at the resume boundary"
    except ConversationPausedError:
        pass
    store.ensure_ai_may_reply("conversation-1", "message-3")
