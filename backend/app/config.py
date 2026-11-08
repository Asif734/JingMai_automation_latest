from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    knowledge_dir: Path
    data_dir: Path
    openai_api_key: str | None
    generation_model: str
    embedding_model: str
    retrieval_limit: int
    admin_token: str | None

    @classmethod
    def from_env(cls) -> "Settings":
        root = Path(__file__).resolve().parents[2]
        default_knowledge = root / "格志京东客服知识库-2026-10-04"
        return cls(
            knowledge_dir=Path(os.getenv("KNOWLEDGE_DIR", str(default_knowledge))).resolve(),
            data_dir=Path(os.getenv("RAG_DATA_DIR", str(root / "data" / "rag"))).resolve(),
            openai_api_key=os.getenv("OPENAI_API_KEY") or None,
            generation_model=os.getenv("OPENAI_MODEL", "gpt-5.6-sol"),
            embedding_model=os.getenv("OPENAI_EMBEDDING_MODEL", "text-embedding-3-large"),
            retrieval_limit=max(1, min(10, int(os.getenv("RAG_RETRIEVAL_LIMIT", "5")))),
            admin_token=os.getenv("RAG_ADMIN_TOKEN") or None,
        )
