import json
import os
import sqlite3
from typing import Any, Dict, List

from .utils import ensure_dir, now_iso


class KB:
    def __init__(self, db_path: str):
        self.db_path = db_path
        ensure_dir(os.path.dirname(db_path))
        self.conn = sqlite3.connect(db_path)
        self.conn.row_factory = sqlite3.Row
        self._init_db()

    def _init_db(self) -> None:
        cur = self.conn.cursor()
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS documents (
                id INTEGER PRIMARY KEY,
                created_at TEXT,
                source_image TEXT,
                raw_text TEXT,
                clean_text TEXT,
                summary TEXT,
                command TEXT,
                intent TEXT,
                category TEXT,
                metadata_json TEXT
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS artifacts (
                id INTEGER PRIMARY KEY,
                doc_id INTEGER,
                type TEXT,
                path TEXT,
                hash TEXT,
                created_at TEXT
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS tasks (
                id INTEGER PRIMARY KEY,
                doc_id INTEGER,
                type TEXT,
                status TEXT,
                payload_json TEXT,
                created_at TEXT
            )
            """
        )
        cur.execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS fts_docs
            USING fts5(doc_id, clean_text, summary, category, intent)
            """
        )
        self.conn.commit()

    def store_document(
        self,
        source_image: str,
        raw_text: str,
        clean_text: str,
        summary: str,
        command: str,
        intent: str,
        category: str,
        metadata: Dict[str, Any],
    ) -> int:
        cur = self.conn.cursor()
        cur.execute(
            """
            INSERT INTO documents
            (created_at, source_image, raw_text, clean_text, summary, command, intent, category, metadata_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                now_iso(),
                source_image,
                raw_text,
                clean_text,
                summary,
                command,
                intent,
                category,
                json.dumps(metadata),
            ),
        )
        doc_id = cur.lastrowid
        cur.execute(
            """
            INSERT INTO fts_docs (doc_id, clean_text, summary, category, intent)
            VALUES (?, ?, ?, ?, ?)
            """,
            (doc_id, clean_text, summary, category, intent),
        )
        self.conn.commit()
        return doc_id

    def store_artifact(self, doc_id: int, type_: str, path: str, hash_: str) -> None:
        cur = self.conn.cursor()
        cur.execute(
            """
            INSERT INTO artifacts (doc_id, type, path, hash, created_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            (doc_id, type_, path, hash_, now_iso()),
        )
        self.conn.commit()

    def store_task(self, doc_id: int, type_: str, payload: Dict[str, Any]) -> int:
        cur = self.conn.cursor()
        cur.execute(
            """
            INSERT INTO tasks (doc_id, type, status, payload_json, created_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            (doc_id, type_, "draft", json.dumps(payload), now_iso()),
        )
        task_id = cur.lastrowid
        self.conn.commit()
        return task_id

    def search(self, query: str, limit: int = 5) -> List[Dict[str, Any]]:
        cur = self.conn.cursor()
        cur.execute(
            """
            SELECT doc_id, bm25(fts_docs) AS score, snippet(fts_docs, 1, '[', ']', '…', 12) AS snippet
            FROM fts_docs
            WHERE fts_docs MATCH ?
            ORDER BY score
            LIMIT ?
            """,
            (query, limit),
        )
        rows = cur.fetchall()
        results = []
        for row in rows:
            doc = self.get_document(row["doc_id"])
            results.append(
                {
                    "doc_id": row["doc_id"],
                    "score": row["score"],
                    "snippet": row["snippet"],
                    "document": doc,
                }
            )
        return results

    def get_document(self, doc_id: int) -> Dict[str, Any]:
        cur = self.conn.cursor()
        cur.execute("SELECT * FROM documents WHERE id = ?", (doc_id,))
        row = cur.fetchone()
        return dict(row) if row else {}
