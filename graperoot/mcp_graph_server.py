#!/usr/bin/env python3
"""MCP gateway exposing dual-graph retrieval/read/impact tools."""

import hashlib
import json
import logging
import math
import os
import re
import socket
import subprocess
import time
import urllib.request

# Suppress all INFO-level logs so the Claude CLI terminal stays clean
logging.basicConfig(level=logging.ERROR)
for _logger in ("uvicorn", "uvicorn.error", "uvicorn.access", "mcp", "anyio"):
    logging.getLogger(_logger).setLevel(logging.ERROR)
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Union

try:
    from mcp.server.fastmcp import FastMCP
except Exception:  # noqa: BLE001
    FastMCP = None  # type: ignore[assignment]

import sys as _sys
_sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    from graperoot.graph_builder import scan as _gb_scan
except Exception:  # noqa: BLE001
    _gb_scan = None  # type: ignore[assignment]

try:
    from graperoot.dg import retrieve as _dg_retrieve, classify_intent as _dg_classify_intent
except Exception:  # noqa: BLE001
    _dg_retrieve = None  # type: ignore[assignment]
    _dg_classify_intent = None  # type: ignore[assignment]


DG_BASE = os.environ.get("DG_BASE_URL", "http://127.0.0.1:8787")
DG_API_TOKEN = os.environ.get("DG_API_TOKEN", "").strip()
PROJECT_ROOT = Path(
    os.environ.get(
        "DUAL_GRAPH_PROJECT_ROOT",
        "/app/project",  # default clone target in Railway (set via GITHUB_REPO_URL)
    )
).resolve()
# When DUAL_GRAPH_PROJECT_ROOT is explicitly set in env, lock the server to that
# project for its lifetime. The launcher (dgc/dg) always sets it, so each Claude/
# Codex session ends up with its own MCP process bound to one project. Locking
# makes that invariant explicit: graph_scan() with a different path is rejected
# instead of silently flipping PROJECT_ROOT under the running session.
_LOCKED_PROJECT_ROOT: Path | None = (
    PROJECT_ROOT if "DUAL_GRAPH_PROJECT_ROOT" in os.environ else None
)
# DG_DATA_DIR: where graph JSON + action graph + cache are stored.
# Defaults to <script_dir>/data (Railway mode).
# Set to PROJECT_ROOT/.dual-graph for local mode so data persists with the project.
DG_DATA_DIR = Path(
    os.environ.get("DG_DATA_DIR", str(Path(__file__).resolve().parent / "data"))
)
LOG_FILE = DG_DATA_DIR / "mcp_tool_calls.jsonl"
ACTION_GRAPH_FILE = DG_DATA_DIR / "chat_action_graph.json"
RETRIEVAL_CACHE_FILE = DG_DATA_DIR / "retrieval_cache.json"
SYMBOL_INDEX_FILE = DG_DATA_DIR / "symbol_index.json"
CONTEXT_STORE_FILE = DG_DATA_DIR / "context-store.json"
HARD_MAX_READ_CHARS = int(os.environ.get("DG_HARD_MAX_READ_CHARS", "20000"))
TURN_READ_BUDGET_CHARS = int(os.environ.get("DG_TURN_READ_BUDGET_CHARS", "60000"))
ENFORCE_REUSE_GATE = str(os.environ.get("DG_ENFORCE_REUSE_GATE", "1")).strip() not in {"0", "false", "False"}
ENFORCE_SINGLE_RETRIEVE = str(os.environ.get("DG_ENFORCE_SINGLE_RETRIEVE", "1")).strip() not in {"0", "false", "False"}
ENFORCE_READ_ALLOWLIST = str(os.environ.get("DG_ENFORCE_READ_ALLOWLIST", "0")).strip() not in {"0", "false", "False"}
FALLBACK_MAX_CALLS_PER_TURN = int(os.environ.get("DG_FALLBACK_MAX_CALLS_PER_TURN", "1"))
RETRIEVE_CACHE_TTL_SEC = int(os.environ.get("DG_RETRIEVE_CACHE_TTL_SEC", "900"))
# Memory-first routing requires at least this many overlapping query terms to avoid
# false positives from single-word coincidental matches across sessions.
MEMORY_FIRST_MIN_OVERLAP = int(os.environ.get("DG_MEMORY_FIRST_MIN_OVERLAP", "3"))
# Per-type score multipliers for memory entries: explicit decisions outweigh auto-generated ones.
MEMORY_TYPE_MULTIPLIERS: dict[str, float] = {
    "decision": 1.5,
    "fact": 1.3,
    "blocker": 1.3,
    "next": 1.1,
    "edit_observation": 1.1,
    "interaction_pattern": 1.0,
    "query_association": 0.8,
    "stale_marker": 0.5,
}
# Explore-mode read budget: allows more total chars and larger per-file reads for
# architecture/trace queries that need to span many files.
EXPLORE_READ_BUDGET_CHARS = int(os.environ.get("DG_EXPLORE_READ_BUDGET_CHARS", "36000"))
EXPLORE_MAX_READ_CHARS = int(os.environ.get("DG_EXPLORE_MAX_READ_CHARS", "6000"))
# Session epoch: used to penalise query_association entries from prior sessions.
_SESSION_START_EPOCH: int = int(time.time())

# Process-local state for adaptive budgeting and dedupe.
TURN_STATE: dict[str, Any] = {
    "query_key": "",
    "used_chars": 0,
    "seen_reads": {},  # key: (file, query, anchor) -> content
    "reuse_gate_candidates": [],
    "reuse_gate_satisfied": False,
    "retrieved_files": [],
    "retrieve_count": 0,
    "last_retrieve_out": None,
    "fallback_calls": 0,
}


def _post(path: str, payload: dict[str, Any]) -> dict[str, Any]:
    raw = json.dumps(payload).encode("utf-8")
    headers = {"content-type": "application/json"}
    if DG_API_TOKEN:
        headers["authorization"] = f"Bearer {DG_API_TOKEN}"
    req = urllib.request.Request(
        url=f"{DG_BASE}{path}",
        data=raw,
        method="POST",
        headers=headers,
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _get(path: str) -> dict[str, Any]:
    req = urllib.request.Request(url=f"{DG_BASE}{path}", method="GET")
    if DG_API_TOKEN:
        req.add_header("authorization", f"Bearer {DG_API_TOKEN}")
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))


# Module-level cache for info graph and symbol index, keyed by file mtime.
# Avoids re-parsing MB-sized JSON on every tool call.
_INFO_GRAPH_CACHE: dict[str, Any] | None = None
_INFO_GRAPH_MTIME: int = -1
_SYMBOL_INDEX_CACHE: dict[str, Any] | None = None
_SYMBOL_INDEX_MTIME: int = -1
_CONTEXT_STORE_CACHE: list[dict[str, Any]] | None = None
_CONTEXT_STORE_MTIME: int = -1


def _local_info_graph() -> dict[str, Any] | None:
    """Read the info-graph from local DG_DATA_DIR without HTTP. Returns None if unavailable.
    Results are cached in memory and invalidated when the file mtime changes."""
    global _INFO_GRAPH_CACHE, _INFO_GRAPH_MTIME  # noqa: PLW0603
    graph_json = DG_DATA_DIR / "info_graph.json"
    if not graph_json.exists():
        return None
    try:
        current_mtime = int(graph_json.stat().st_mtime_ns)
        if _INFO_GRAPH_CACHE is not None and current_mtime == _INFO_GRAPH_MTIME:
            return _INFO_GRAPH_CACHE
        data = json.loads(graph_json.read_text(encoding="utf-8-sig"))
        # Stale-graph guard (locked/local mode only): if the on-disk graph was
        # built for a different project, refuse to use it. Railway/ingest mode
        # has no lock so this never triggers there.
        if _LOCKED_PROJECT_ROOT is not None:
            stamped = data.get("root")
            if stamped:
                try:
                    if Path(stamped).resolve() != PROJECT_ROOT:
                        _INFO_GRAPH_CACHE = None
                        _INFO_GRAPH_MTIME = -1
                        return None
                except Exception:
                    pass
        # Strip content from file nodes — retrieval doesn't use it, saves RAM.
        # Railway-mode graph_read reads info_graph.json directly (separate path).
        for node in data.get("nodes", []):
            node.pop("content", None)
        _INFO_GRAPH_CACHE = data
        _INFO_GRAPH_MTIME = current_mtime
        return data
    except Exception:
        return None


def _build_symbol_index(graph: dict[str, Any]) -> dict[str, Any]:
    """Build a flat {symbol_id: metadata} dict for O(1) graph_read lookup."""
    index: dict[str, Any] = {}
    for node in graph.get("nodes", []):
        if node.get("kind") == "symbol":
            node_id = str(node.get("id", ""))
            if node_id:
                index[node_id] = {
                    "line_start": node.get("line_start", 0),
                    "line_end": node.get("line_end", 0),
                    "body_hash": node.get("body_hash", ""),
                    "confidence": node.get("confidence", ""),
                    "path": node.get("path", ""),
                }
    return index


def _load_symbol_index() -> dict[str, Any]:
    """Load symbol index with in-memory caching keyed by file mtime."""
    global _SYMBOL_INDEX_CACHE, _SYMBOL_INDEX_MTIME  # noqa: PLW0603
    if not SYMBOL_INDEX_FILE.exists():
        return {}
    try:
        current_mtime = int(SYMBOL_INDEX_FILE.stat().st_mtime_ns)
        if _SYMBOL_INDEX_CACHE is not None and current_mtime == _SYMBOL_INDEX_MTIME:
            return _SYMBOL_INDEX_CACHE
        data = json.loads(SYMBOL_INDEX_FILE.read_text(encoding="utf-8-sig"))
        _SYMBOL_INDEX_CACHE = data
        _SYMBOL_INDEX_MTIME = current_mtime
        return data
    except Exception:
        return {}


def _local_chat_fix(query: str, top_files: int, top_edges: int) -> dict[str, Any] | None:
    """Run retrieval locally from the graph file, bypassing /api/chat-fix HTTP call.
    Returns None if local retrieval is unavailable (falls back to HTTP)."""
    if _dg_retrieve is None:
        return None
    g = _local_info_graph()
    if g is None:
        return None
    try:
        rel = _dg_retrieve(g, query, top_files, top_edges)
        return {
            "ok": True,
            "query": query,
            "graph_files": rel.files,
            "graph_edges": rel.edges,
            "grep_hits": [],
        }
    except Exception:
        return None


def _is_local_file_ref(value: str) -> bool:
    if not value:
        return False
    if value.startswith("@"):
        return False
    # Strip symbol suffix (e.g. "src/auth.ts::handleLogin" → "src/auth.ts")
    file_part = value.split("::")[0] if "::" in value else value
    if ":" in file_part:  # URL-like (http:, C:\)
        return False
    if "/" not in file_part:
        return False
    return "." in file_part.split("/")[-1]


def _est_tokens(text: str) -> int:
    return max(1, len(text) // 4) if text else 0


def _query_terms(query: str) -> list[str]:
    words = re.findall(r"[A-Za-z0-9_]+", query.lower())
    stop = {
        "a", "an", "the", "and", "or", "to", "for", "with", "in", "on", "by", "of",
        "please", "can", "could", "would", "should", "will", "use", "update", "fix",
        "make", "show", "this", "that", "it",
    }
    out: list[str] = []
    seen = set()
    for w in words:
        if len(w) < 3 or w in stop or w in seen:
            continue
        seen.add(w)
        out.append(w)
    return out[:8]


def _query_key(query: str) -> str:
    return " ".join(_query_terms(query))


def _excerpt_by_terms(text: str, terms: list[str], max_chars: int) -> str:
    if not terms:
        return text[:max_chars]
    lines = text.splitlines()
    if not lines:
        return text[:max_chars]
    picks: list[str] = []
    seen_blocks: set[int] = set()
    for idx, line in enumerate(lines):
        blob = line.lower()
        if not any(t in blob for t in terms):
            continue
        start = max(0, idx - 12)
        end = min(len(lines), idx + 13)
        if start in seen_blocks:
            continue
        seen_blocks.add(start)
        block = "\n".join(lines[start:end])
        picks.append(block)
        if sum(len(x) for x in picks) >= max_chars:
            break
    if not picks:
        return text[:max_chars]
    out = "\n\n/* --- excerpt --- */\n\n".join(picks)
    if len(out) > max_chars:
        out = out[:max_chars]
    return out


def _log_tool(name: str, payload: dict[str, Any]) -> None:
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    row = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "tool": name,
        "payload": payload,
    }
    with LOG_FILE.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row) + "\n")


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _load_action_graph() -> dict[str, Any]:
    if not ACTION_GRAPH_FILE.exists():
        return {"nodes": [], "edges": [], "files": {}, "actions": []}
    try:
        return json.loads(ACTION_GRAPH_FILE.read_text(encoding="utf-8-sig"))
    except Exception:
        return {"nodes": [], "edges": [], "files": {}, "actions": []}


def _save_action_graph(g: dict[str, Any]) -> None:
    ACTION_GRAPH_FILE.parent.mkdir(parents=True, exist_ok=True)
    ACTION_GRAPH_FILE.write_text(json.dumps(g, indent=2), encoding="utf-8")


def _memory_id() -> str:
    return f"mem:{int(datetime.now(timezone.utc).timestamp() * 1000)}"


def _memory_anchor_for_ref(ref: str, symbol_index: dict[str, Any]) -> tuple[str, str, str]:
    if not ref:
        return "", "", ""
    if "::" in ref:
        sym = ref
        meta = symbol_index.get(sym, {})
        return sym, str(meta.get("path", ref.split("::")[0])), str(meta.get("body_hash", ""))
    return "", ref, ""


def _merge_unique_strings(values: list[Any], limit: int = 6) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for value in values:
        text = str(value or "").strip()
        if not text or text in seen:
            continue
        seen.add(text)
        out.append(text)
        if len(out) >= limit:
            break
    return out


def _normalize_memory_entry(entry: Any, symbol_index: dict[str, Any]) -> dict[str, Any] | None:
    if not isinstance(entry, dict):
        return None
    content = str(entry.get("content") or entry.get("summary") or "").strip()
    if not content:
        return None
    raw_files = entry.get("files", [])
    files = [str(f) for f in raw_files if isinstance(f, str) and str(f).strip()] if isinstance(raw_files, list) else []
    symbol_id = str(entry.get("symbol_id") or "").strip()
    file_path = str(entry.get("file_path") or "").strip()
    symbol_hash = str(entry.get("symbol_hash") or "").strip()
    if not symbol_id and files:
        symbol_id, anchored_file, anchored_hash = _memory_anchor_for_ref(files[0], symbol_index)
        if anchored_file and not file_path:
            file_path = anchored_file
        if anchored_hash and not symbol_hash:
            symbol_hash = anchored_hash
    if symbol_id and not file_path:
        file_path = str(symbol_index.get(symbol_id, {}).get("path", symbol_id.split("::")[0]))
    if symbol_id and not symbol_hash:
        symbol_hash = str(symbol_index.get(symbol_id, {}).get("body_hash", ""))
    if not files:
        if symbol_id:
            files = [symbol_id]
        elif file_path:
            files = [file_path]
    stale = bool(entry.get("stale", False))
    stale_reason = str(entry.get("stale_reason", "")).strip()
    created_at = str(entry.get("created_at") or entry.get("updated_at") or entry.get("date") or _now_iso())
    updated_at = str(entry.get("updated_at") or created_at)
    created_epoch = int(entry.get("created_epoch") or 0)
    if created_epoch <= 0:
        try:
            created_epoch = int(datetime.fromisoformat(created_at.replace("Z", "+00:00")).timestamp())
        except Exception:
            created_epoch = int(datetime.now(timezone.utc).timestamp())
    tags = entry.get("tags", [])
    if not isinstance(tags, list):
        tags = []
    return {
        "id": str(entry.get("id") or _memory_id()),
        "kind": str(entry.get("kind") or entry.get("type") or "fact"),
        "content": content,
        "tags": [str(t) for t in tags if isinstance(t, str)],
        "files": files,
        "file_path": file_path,
        "symbol_id": symbol_id,
        "symbol_hash": symbol_hash,
        "created_at": created_at,
        "created_epoch": created_epoch,
        "updated_at": updated_at,
        "stale": stale,
        "stale_reason": stale_reason,
        "observed_queries": [str(q) for q in entry.get("observed_queries", []) if isinstance(q, str)] if isinstance(entry.get("observed_queries", []), list) else [],
        "evidence": entry.get("evidence", {}) if isinstance(entry.get("evidence", {}), dict) else {},
    }


def _memory_identity(entry: dict[str, Any]) -> tuple[str, str, str, str]:
    kind = str(entry.get("kind", ""))
    symbol_id = str(entry.get("symbol_id", ""))
    file_path = str(entry.get("file_path", ""))
    if kind == "interaction_pattern":
        return (kind, symbol_id, file_path, "")
    if kind == "edit_observation":
        return (kind, symbol_id, file_path, "")
    if kind == "stale_marker":
        return (kind, symbol_id, file_path, str(entry.get("stale_reason", "")))
    return (
        kind,
        symbol_id,
        file_path,
        str(entry.get("content", "")),
    )


def _prune_context_entries(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    # Drop auto-generated entries older than 14 days to prevent cross-session noise buildup.
    _QA_MAX_AGE_SECS = 14 * 86400
    _AUTO_KINDS = {"query_association", "interaction_pattern"}
    now_epoch = int(datetime.now(timezone.utc).timestamp())
    entries = [
        row for row in entries
        if str(row.get("kind", "")) not in _AUTO_KINDS
        or (now_epoch - int(row.get("created_epoch", 0) or 0)) <= _QA_MAX_AGE_SECS
    ]
    caps = {
        "query_association": 4,
        "edit_observation": 2,
        "interaction_pattern": 1,
        "stale_marker": 1,
        "decision": 3,
    }
    ranked = sorted(entries, key=lambda row: int(row.get("created_epoch", 0) or 0), reverse=True)
    kept: list[dict[str, Any]] = []
    counts: dict[tuple[str, str, str], int] = {}
    for row in ranked:
        kind = str(row.get("kind", ""))
        symbol_id = str(row.get("symbol_id", ""))
        file_path = str(row.get("file_path", ""))
        bucket = (kind, symbol_id, file_path)
        cap = caps.get(kind, 6)
        if counts.get(bucket, 0) >= cap:
            continue
        counts[bucket] = counts.get(bucket, 0) + 1
        kept.append(row)
        if len(kept) >= 200:
            break
    kept.reverse()
    return kept


def _merge_memory_entries(existing: dict[str, Any], incoming: dict[str, Any]) -> dict[str, Any]:
    merged = dict(existing)
    merged["updated_at"] = str(incoming.get("updated_at") or _now_iso())
    merged["stale"] = bool(existing.get("stale") or incoming.get("stale"))
    merged["stale_reason"] = str(incoming.get("stale_reason") or existing.get("stale_reason") or "")
    merged["tags"] = _merge_unique_strings(list(existing.get("tags", [])) + list(incoming.get("tags", [])), limit=10)
    merged["files"] = _merge_unique_strings(list(existing.get("files", [])) + list(incoming.get("files", [])), limit=10)
    merged["observed_queries"] = _merge_unique_strings(
        list(existing.get("observed_queries", [])) + list(incoming.get("observed_queries", [])),
        limit=6,
    )
    evidence = dict(existing.get("evidence", {}))
    for key, value in incoming.get("evidence", {}).items():
        if isinstance(value, list):
            evidence[key] = _merge_unique_strings(list(evidence.get(key, [])) + value, limit=8)
        elif isinstance(value, bool):
            evidence[key] = bool(evidence.get(key, False) or value)
        elif isinstance(value, int):
            evidence[key] = max(int(evidence.get(key, 0) or 0), value)
        elif value not in (None, "", []):
            evidence[key] = value
    merged["evidence"] = evidence
    return merged


def _upsert_context_memory(candidate: dict[str, Any], symbol_index: dict[str, Any] | None = None) -> dict[str, Any] | None:
    idx = symbol_index if symbol_index is not None else _load_symbol_index()
    normalized = _normalize_memory_entry(candidate, idx)
    if normalized is None:
        return None
    entries = _load_context_store(idx)
    target = _memory_identity(normalized)
    for i, row in enumerate(entries):
        if _memory_identity(row) != target:
            continue
        entries[i] = _merge_memory_entries(row, normalized)
        _save_context_store(entries)
        return entries[i]
    entries.append(normalized)
    _save_context_store(entries)
    return normalized


def _load_context_store(symbol_index: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    global _CONTEXT_STORE_CACHE, _CONTEXT_STORE_MTIME  # noqa: PLW0603
    if not CONTEXT_STORE_FILE.exists():
        return []
    try:
        current_mtime = int(CONTEXT_STORE_FILE.stat().st_mtime_ns)
        if _CONTEXT_STORE_CACHE is not None and current_mtime == _CONTEXT_STORE_MTIME:
            return list(_CONTEXT_STORE_CACHE)
    except Exception:
        pass
    idx = symbol_index if symbol_index is not None else _load_symbol_index()
    try:
        raw = json.loads(CONTEXT_STORE_FILE.read_text(encoding="utf-8-sig"))
        if not isinstance(raw, list):
            return []
        # Prune-on-load: if file grew beyond cap, heal it immediately
        if len(raw) > 200:
            _save_context_store([r for r in raw if isinstance(r, dict)])
            raw = json.loads(CONTEXT_STORE_FILE.read_text(encoding="utf-8-sig"))
            if not isinstance(raw, list):
                return []
        out: list[dict[str, Any]] = []
        for row in raw:
            norm = _normalize_memory_entry(row, idx)
            if norm is not None:
                out.append(norm)
        try:
            _CONTEXT_STORE_MTIME = int(CONTEXT_STORE_FILE.stat().st_mtime_ns)
        except Exception:
            pass
        _CONTEXT_STORE_CACHE = out
        return list(out)
    except Exception:
        return []


def _save_context_store(entries: list[dict[str, Any]]) -> None:
    global _CONTEXT_STORE_CACHE, _CONTEXT_STORE_MTIME  # noqa: PLW0603
    _CONTEXT_STORE_CACHE = None  # invalidate cache on write
    _CONTEXT_STORE_MTIME = -1
    CONTEXT_STORE_FILE.parent.mkdir(parents=True, exist_ok=True)
    CONTEXT_STORE_FILE.write_text(json.dumps(_prune_context_entries(entries), indent=2), encoding="utf-8")


def _reconcile_context_store(symbol_index: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    idx = symbol_index if symbol_index is not None else _load_symbol_index()
    entries = _load_context_store(idx)
    changed = False
    stale_candidates: list[dict[str, Any]] = []
    for row in entries:
        sym = row.get("symbol_id", "")
        if not sym:
            continue
        meta = idx.get(sym)
        if not meta:
            if not row.get("stale") or row.get("stale_reason") != "symbol removed":
                row["stale"] = True
                row["stale_reason"] = "symbol removed"
                row["updated_at"] = _now_iso()
                changed = True
                stale_candidates.append(
                    {
                        "kind": "stale_marker",
                        "content": "Marked stale because symbol removed",
                        "files": list(row.get("files", [])),
                        "file_path": str(row.get("file_path", "")),
                        "symbol_id": sym,
                        "symbol_hash": str(row.get("symbol_hash", "")),
                        "created_at": _now_iso(),
                        "created_epoch": int(datetime.now(timezone.utc).timestamp()),
                        "updated_at": _now_iso(),
                        "stale": True,
                        "stale_reason": "symbol removed",
                        "observed_queries": list(row.get("observed_queries", [])),
                        "evidence": {"source_kind": str(row.get("kind", ""))},
                    }
                )
            continue
        current_hash = str(meta.get("body_hash", ""))
        if not row.get("symbol_hash") and current_hash:
            row["symbol_hash"] = current_hash
            changed = True
        if not row.get("file_path"):
            row["file_path"] = str(meta.get("path", sym.split("::")[0]))
            changed = True
        if row.get("symbol_hash") and current_hash and row.get("symbol_hash") != current_hash:
            if not row.get("stale") or row.get("stale_reason") != "symbol body changed":
                row["stale"] = True
                row["stale_reason"] = "symbol body changed"
                row["updated_at"] = _now_iso()
                changed = True
                stale_candidates.append(
                    {
                        "kind": "stale_marker",
                        "content": "Marked stale because symbol body changed",
                        "files": list(row.get("files", [])),
                        "file_path": str(row.get("file_path", "")),
                        "symbol_id": sym,
                        "symbol_hash": str(row.get("symbol_hash", "")),
                        "created_at": _now_iso(),
                        "created_epoch": int(datetime.now(timezone.utc).timestamp()),
                        "updated_at": _now_iso(),
                        "stale": True,
                        "stale_reason": "symbol body changed",
                        "observed_queries": list(row.get("observed_queries", [])),
                        "evidence": {"source_kind": str(row.get("kind", ""))},
                    }
                )
    if changed:
        _save_context_store(entries)
    for candidate in stale_candidates:
        _upsert_context_memory(candidate, idx)
    return entries


def _score_memory_entry(entry: dict[str, Any], qterms: set[str], related_files: set[str]) -> tuple[int, list[str]]:
    score = 0
    why: list[str] = []
    blob = " ".join(
        [
            str(entry.get("content", "")).lower(),
            " ".join(str(t).lower() for t in entry.get("tags", [])),
            str(entry.get("symbol_id", "")).lower(),
            str(entry.get("file_path", "")).lower(),
        ]
    )
    term_hits = sum(1 for t in qterms if t in blob)
    if term_hits:
        score += term_hits * 3
        why.append(f"{term_hits} query term match")
    symbol_id = str(entry.get("symbol_id", ""))
    file_path = str(entry.get("file_path", ""))
    if symbol_id and symbol_id in related_files:
        score += 5
        why.append("exact symbol match")
    elif file_path and file_path in related_files:
        score += 4
        why.append("same file as retrieved context")
    created_epoch = int(entry.get("created_epoch", 0) or 0)
    if created_epoch > 0:
        age_days = max(0.0, (int(datetime.now(timezone.utc).timestamp()) - created_epoch) / 86400.0)
        recency_score = 4.0 * math.pow(0.5, age_days / 7.0)
        if recency_score > 0.1:
            score += int(round(recency_score))
            why.append(f"recency {recency_score:.1f}")
    if entry.get("stale"):
        score -= 6
        why.append("stale penalty")
    else:
        score += 1
        why.append("fresh memory")
    # Cross-session penalty: auto-generated query_association entries from prior sessions
    # are less reliable than entries from the current session.
    if str(entry.get("kind", "")) == "query_association":
        entry_session = int((entry.get("evidence") or {}).get("session_epoch", 0) or 0)
        if entry_session > 0 and entry_session != _SESSION_START_EPOCH:
            score -= 2
            why.append("cross-session penalty")
    # Type-based score multiplier: explicit decisions outweigh auto-generated entries.
    kind = str(entry.get("kind", ""))
    multiplier = MEMORY_TYPE_MULTIPLIERS.get(kind, 1.0)
    if multiplier != 1.0:
        score = int(round(score * multiplier))
        why.append(f"type_weight×{multiplier:.1f}")
    return score, why


def _search_context_store(query: str, related_files: list[str] | None = None, limit: int = 3) -> list[dict[str, Any]]:
    qterms = set(_query_terms(query))
    related = set(related_files or [])
    scored: list[tuple[int, dict[str, Any]]] = []
    for row in _reconcile_context_store():
        score, why = _score_memory_entry(row, qterms, related)
        if score <= 0:
            continue
        payload = dict(row)
        # Flag weak matches on auto-generated entries so callers can discount them.
        row_blob = " ".join([
            str(row.get("content", "")).lower(),
            " ".join(str(t).lower() for t in row.get("tags", [])),
            str(row.get("symbol_id", "")).lower(),
            str(row.get("file_path", "")).lower(),
        ])
        raw_term_hits = sum(1 for t in qterms if t in row_blob)
        if raw_term_hits < 2 and score < 10 and str(row.get("kind", "")) == "query_association":
            payload["weak_match"] = True
            payload["weak_match_reason"] = f"auto-generated, only {raw_term_hits} term overlap"
        payload["why"] = ", ".join(why[:3])
        scored.append((score, payload))
    scored.sort(
        key=lambda item: (
            -item[0],
            bool(item[1].get("stale")),
            -int(item[1].get("created_epoch", 0) or 0),
        )
    )
    return [row for _, row in scored[:limit]]


def _ensure_node(g: dict[str, Any], node_id: str, node_type: str, meta: dict[str, Any] | None = None) -> None:
    nodes = g.setdefault("nodes", [])
    if any(n.get("id") == node_id for n in nodes):
        return
    row = {"id": node_id, "type": node_type}
    if meta:
        row["meta"] = meta
    nodes.append(row)


def _add_edge(g: dict[str, Any], frm: str, to: str, rel: str, meta: dict[str, Any] | None = None) -> None:
    edges = g.setdefault("edges", [])
    # Use epoch seconds (not ISO string) to save space.
    row: dict[str, Any] = {"from": frm, "to": to, "rel": rel, "ts": int(datetime.now(timezone.utc).timestamp())}
    if meta:
        row["meta"] = meta
    edges.append(row)
    # Keep last 500 edges only.
    if len(edges) > 500:
        del edges[:-500]


def _slim_payload(kind: str, payload: dict[str, Any]) -> dict[str, Any]:
    """Strip large fields from action payloads before storing."""
    keep: dict[str, Any] = {"kind": kind}
    for k in ("file", "query", "mode", "pattern", "response_chars", "overlap"):
        if k in payload:
            keep[k] = payload[k]
    return keep


def _record_action(kind: str, payload: dict[str, Any]) -> None:
    g = _load_action_graph()
    actions = g.setdefault("actions", [])
    # Store only slim metadata — never full file content.
    actions.append({"ts": int(datetime.now(timezone.utc).timestamp()), "kind": kind, "payload": _slim_payload(kind, payload)})
    if len(actions) > 300:
        del actions[:-300]
    _save_action_graph(g)


def _recent_action_evidence(files: list[str], window_sec: int = 120) -> dict[str, Any]:
    now = int(datetime.now(timezone.utc).timestamp())
    g = _load_action_graph()
    actions = g.get("actions", [])
    bases = {f.split("::")[0] if "::" in f else f for f in files}
    recent_kinds: list[str] = []
    recent_queries: list[str] = []
    for a in reversed(actions):
        ts = int(a.get("ts", 0) or 0)
        if ts <= 0 or now - ts > window_sec:
            continue
        payload = a.get("payload", {})
        action_file = str(payload.get("file", ""))
        action_query = str(payload.get("query", "")).strip()
        action_base = action_file.split("::")[0] if "::" in action_file else action_file
        if action_file and action_base not in bases and action_file not in files:
            continue
        kind = str(a.get("kind", ""))
        if kind and kind not in recent_kinds:
            recent_kinds.append(kind)
        if action_query and action_query not in recent_queries:
            recent_queries.append(action_query)
    return {
        "window_sec": window_sec,
        "recent_action_kinds": recent_kinds[:6],
        "recent_queries": recent_queries[:3],
    }


def _recent_read_context(ref: str, window_sec: int = 600) -> dict[str, Any]:
    now = int(datetime.now(timezone.utc).timestamp())
    g = _load_action_graph()
    actions = g.get("actions", [])
    base_ref = ref.split("::")[0] if "::" in ref else ref
    symbol_ref = ref if "::" in ref else ""
    read_count = 0
    co_visited: list[str] = []
    queries: list[str] = []
    for a in reversed(actions):
        ts = int(a.get("ts", 0) or 0)
        if ts <= 0 or now - ts > window_sec:
            continue
        if str(a.get("kind", "")) not in {"read", "read_cache_hit"}:
            continue
        payload = a.get("payload", {})
        action_file = str(payload.get("file", ""))
        action_base = action_file.split("::")[0] if "::" in action_file else action_file
        exact_match = bool(symbol_ref and action_file == symbol_ref)
        file_match = bool(not symbol_ref and action_base == base_ref)
        if exact_match or file_match:
            read_count += 1
            query = str(payload.get("query", "")).strip()
            if query:
                queries.append(query)
            continue
        if action_file and (not symbol_ref or action_base == base_ref):
            co_visited.append(action_file)
    return {
        "read_count": read_count,
        "co_visited": _merge_unique_strings(co_visited, limit=3),
        "queries": _merge_unique_strings(queries, limit=3),
    }


def _capture_read_memory(file: str, file_base: str, query: str, qterms: list[str], symbol_index: dict[str, Any] | None = None) -> None:
    idx = symbol_index if symbol_index is not None else _load_symbol_index()
    anchor_ref = file if "::" in file else file_base
    symbol_id, file_path, symbol_hash = _memory_anchor_for_ref(anchor_ref, idx)
    if not file_path:
        file_path = file_base
    query_text = query.strip()
    if query_text:
        _upsert_context_memory(
            {
                "kind": "query_association",
                "content": f"Queried during: {query_text}",
                "tags": qterms,
                "files": [anchor_ref],
                "file_path": file_path,
                "symbol_id": symbol_id,
                "symbol_hash": symbol_hash,
                "created_at": _now_iso(),
                "created_epoch": int(datetime.now(timezone.utc).timestamp()),
                "updated_at": _now_iso(),
                "stale": False,
                "stale_reason": "",
                "observed_queries": [query_text],
                "evidence": {
                    "source": "graph_read",
                    "anchor_mode": "symbol" if symbol_id else "file",
                    "session_epoch": _SESSION_START_EPOCH,
                },
            },
            idx,
        )
    read_context = _recent_read_context(anchor_ref)
    if int(read_context.get("read_count", 0)) >= 2:
        co_visited = list(read_context.get("co_visited", []))
        content = f"Frequently read with: {', '.join(co_visited)}" if co_visited else "Repeatedly visited during recent work"
        _upsert_context_memory(
            {
                "kind": "interaction_pattern",
                "content": content,
                "tags": qterms,
                "files": [anchor_ref],
                "file_path": file_path,
                "symbol_id": symbol_id,
                "symbol_hash": symbol_hash,
                "created_at": _now_iso(),
                "created_epoch": int(datetime.now(timezone.utc).timestamp()),
                "updated_at": _now_iso(),
                "stale": False,
                "stale_reason": "",
                "observed_queries": list(read_context.get("queries", [])),
                "evidence": {
                    "source": "graph_read",
                    "read_count": int(read_context.get("read_count", 0)),
                    "co_visited": co_visited,
                },
            },
            idx,
        )


def _load_retrieval_cache() -> dict[str, Any]:
    if not RETRIEVAL_CACHE_FILE.exists():
        return {"entries": {}}
    try:
        data = json.loads(RETRIEVAL_CACHE_FILE.read_text(encoding="utf-8-sig"))
        if not isinstance(data, dict):
            return {"entries": {}}
        if "entries" not in data or not isinstance(data["entries"], dict):
            data["entries"] = {}
        # Eagerly evict expired entries on load so file never grows stale.
        now = int(datetime.now(timezone.utc).timestamp())
        data["entries"] = {
            k: v for k, v in data["entries"].items()
            if isinstance(v, dict) and now - int(v.get("created_epoch", 0)) <= RETRIEVE_CACHE_TTL_SEC
        }
        return data
    except Exception:
        return {"entries": {}}


def _save_retrieval_cache(cache: dict[str, Any]) -> None:
    RETRIEVAL_CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
    RETRIEVAL_CACHE_FILE.write_text(json.dumps(cache, indent=2), encoding="utf-8")


def _cache_key(query: str, top_files: int, top_edges: int) -> str:
    qk = _query_key(query)
    return f"{qk}|tf={top_files}|te={top_edges}"


def _file_mtime_ns(path: Path) -> int:
    try:
        return int(path.stat().st_mtime_ns)
    except Exception:
        return -1


def _retrieval_entry_valid(entry: dict[str, Any]) -> bool:
    if not isinstance(entry, dict):
        return False
    created = int(entry.get("created_epoch", 0) or 0)
    if created <= 0:
        return False
    now = int(datetime.now(timezone.utc).timestamp())
    if now - created > RETRIEVE_CACHE_TTL_SEC:
        return False
    files = entry.get("files", [])
    mtimes = entry.get("mtimes_ns", {})
    if not isinstance(files, list) or not isinstance(mtimes, dict):
        return False
    for rel in files:
        if not isinstance(rel, str) or not rel:
            return False
        # Symbol IDs (file::symbol) → check mtime of the base file on disk.
        file_path = rel.split("::")[0] if "::" in rel else rel
        p = (PROJECT_ROOT / file_path).resolve()
        current = _file_mtime_ns(p)
        if current < 0:
            return False
        if int(mtimes.get(rel, -2)) != current:
            return False
    return True


def _invalidate_retrieval_cache_for_files(changed_files: list[str]) -> int:
    cache = _load_retrieval_cache()
    entries = cache.get("entries", {})
    if not isinstance(entries, dict):
        return 0
    changed = set(changed_files)
    # Also match symbol IDs whose base file is in the changed set.
    changed_bases = {f.split("::")[0] if "::" in f else f for f in changed_files}
    kill_keys = []
    for key, ent in entries.items():
        files = ent.get("files", [])
        if not isinstance(files, list):
            continue
        if any(f in changed or (f.split("::")[0] if "::" in f else f) in changed_bases for f in files):
            kill_keys.append(key)
    for k in kill_keys:
        entries.pop(k, None)
    cache["entries"] = entries
    _save_retrieval_cache(cache)
    return len(kill_keys)


def _search_action_history(query: str, limit: int = 10) -> dict[str, Any]:
    g = _load_action_graph()
    qterms = set(_query_terms(query))
    actions = g.get("actions", [])
    files_meta = g.get("files", {})

    # Recent relevant actions — return only slim metadata, never full payload.
    action_hits: list[dict[str, Any]] = []
    for a in reversed(actions):
        payload = a.get("payload", {})
        # Score against slim payload only (already stripped of large content).
        blob = " ".join(str(v) for v in payload.values()).lower()
        overlap = sum(1 for t in qterms if t in blob)
        if overlap <= 0 and qterms:
            continue
        action_hits.append({"kind": a.get("kind"), "file": payload.get("file", ""), "overlap": overlap})
        if len(action_hits) >= limit:
            break

    # Relevant cached files — slim response, no cached_content.
    file_hits: list[dict[str, Any]] = []
    for file, meta in files_meta.items():
        cached_terms = set(meta.get("query_terms", []))
        overlap = len(qterms & cached_terms) if qterms else 0
        if qterms and overlap <= 0:
            continue
        file_hits.append({
            "file": file,
            "overlap": overlap,
            "edited_count": int(meta.get("edited_count", 0)),
        })
    file_hits.sort(key=lambda x: (-x["overlap"], -x["edited_count"], x["file"]))
    return {"action_hits": action_hits, "file_hits": file_hits[:limit]}


def build_server(host: str = "127.0.0.1", port: int = 8080) -> Any:
    if FastMCP is None:
        raise RuntimeError(
            "Missing dependency: 'mcp'. Install with: python3 -m pip install mcp"
        )

    mcp = FastMCP("dual-graph-mcp", host=host, port=port, stateless_http=True, json_response=True)

    @mcp.tool()
    def graph_retrieve(query: str, top_files: int = 5, top_edges: int = 12) -> dict[str, Any]:
        """Retrieve ranked files/edges using dual-graph first."""
        qk = _query_key(query)
        # New query starts a new adaptive turn budget.
        if qk and qk != TURN_STATE.get("query_key", ""):
            TURN_STATE["query_key"] = qk
            TURN_STATE["used_chars"] = 0
            TURN_STATE["seen_reads"] = {}
            TURN_STATE["reuse_gate_candidates"] = []
            TURN_STATE["reuse_gate_satisfied"] = False
            TURN_STATE["retrieved_files"] = []
            TURN_STATE["retrieve_count"] = 0
            TURN_STATE["last_retrieve_out"] = None
            TURN_STATE["fallback_calls"] = 0
        # Avoid repeated retrieval cycles for the same turn unless query changed.
        if ENFORCE_SINGLE_RETRIEVE and qk and qk == TURN_STATE.get("query_key", "") and int(TURN_STATE.get("retrieve_count", 0)) >= 1:
            cached = dict(TURN_STATE.get("last_retrieve_out") or {})
            if cached:
                cached["single_retrieve_reused"] = True
                return cached
        # Persistent retrieval cache (cross-turn) with safe invalidation.
        ck = _cache_key(query, top_files, top_edges)
        rcache = _load_retrieval_cache()
        cent = rcache.get("entries", {}).get(ck)
        if cent and _retrieval_entry_valid(cent):
            out = dict(cent.get("result", {}))
            out["retrieval_cache_hit"] = True
            out["retrieval_cache_key"] = ck
            TURN_STATE["retrieved_files"] = [str(f.get("id", "")) for f in out.get("graph_files", []) if str(f.get("id", ""))]
            TURN_STATE["last_retrieve_out"] = dict(out)
            TURN_STATE["retrieve_count"] = int(TURN_STATE.get("retrieve_count", 0)) + 1
            _log_tool("graph_retrieve", {"query": query, "top_files": top_files, "top_edges": top_edges, "mode": "retrieval_cache_hit"})
            _record_action("retrieve_cache_hit", {"query": query, "cache_key": ck})
            return out
        _log_tool("graph_retrieve", {"query": query, "top_files": top_files, "top_edges": top_edges})
        _record_action("retrieve", {"query": query, "top_files": top_files, "top_edges": top_edges})
        out = _local_chat_fix(query, top_files, top_edges) or _post(
            "/api/chat-fix",
            {"query": query, "top_files": top_files, "top_edges": top_edges, "max_grep_hits": 0},
        )
        # Action graph update + cache hints
        g = _load_action_graph()
        qid = f"query:{_query_key(query)}"
        _ensure_node(g, qid, "query", {"text": query})
        for f in out.get("graph_files", [])[: max(1, top_files)]:
            fid = str(f.get("id", ""))
            if not fid:
                continue
            _ensure_node(g, fid, "file")
            _add_edge(g, qid, fid, "retrieved")
        TURN_STATE["retrieved_files"] = [str(f.get("id", "")) for f in out.get("graph_files", [])[: max(1, top_files)] if str(f.get("id", ""))]
        _save_action_graph(g)

        files_meta = g.get("files", {})
        qterms = set(_query_terms(query))
        reuse: list[dict[str, Any]] = []
        for file, meta in files_meta.items():
            cached_terms = set(meta.get("query_terms", []))
            overlap = len(qterms & cached_terms)
            if overlap <= 0:
                continue
            reuse.append(
                {
                    "file": file,
                    "overlap": overlap,
                    "cached_chars": int(meta.get("cached_chars", 0)),
                    "cached_tokens_est": int(meta.get("cached_tokens_est", 0)),
                    "last_action": meta.get("last_action", ""),
                }
            )
        reuse.sort(key=lambda x: (-x["overlap"], -x["cached_tokens_est"], x["file"]))
        out["reuse_candidates"] = reuse[:3]
        TURN_STATE["reuse_gate_candidates"] = [r["file"] for r in reuse[:3]]
        TURN_STATE["reuse_gate_satisfied"] = False
        out["read_budget"] = {
            "remaining_chars": max(0, TURN_READ_BUDGET_CHARS - int(TURN_STATE.get("used_chars", 0))),
            "reuse_gate_candidates": TURN_STATE.get("reuse_gate_candidates", []),
        }
        TURN_STATE["retrieve_count"] = int(TURN_STATE.get("retrieve_count", 0)) + 1
        TURN_STATE["last_retrieve_out"] = dict(out)
        # Save retrieval cache with mtime stamps of returned files.
        rel_files = [str(f.get("id", "")) for f in out.get("graph_files", []) if str(f.get("id", ""))]
        mtimes: dict[str, int] = {}
        for rel in rel_files:
            # Symbol IDs (file::symbol) → stat the base file on disk.
            file_path = rel.split("::")[0] if "::" in rel else rel
            mtimes[rel] = _file_mtime_ns((PROJECT_ROOT / file_path).resolve())
        entries = rcache.get("entries", {})
        if not isinstance(entries, dict):
            entries = {}
        entries[ck] = {
            "created_epoch": int(datetime.now(timezone.utc).timestamp()),
            "files": rel_files,        # only file IDs, not full objects
            "mtimes_ns": mtimes,
            "result": out,
        }
        # Bound cache size to 50 entries (down from 200).
        if len(entries) > 50:
            items = sorted(entries.items(), key=lambda kv: int(kv[1].get("created_epoch", 0)))
            for old_key, _ in items[:-50]:
                entries.pop(old_key, None)
        rcache["entries"] = entries
        _save_retrieval_cache(rcache)
        return out

    @mcp.tool()
    def graph_read(file: str, max_chars: int = 20000, query: str = "", anchor: str = "") -> dict[str, Any]:
        """Read ONE file from project root. Call once per file — do NOT pass arrays. Use file::symbol notation for focused reads."""
        requested = max(256, int(max_chars or 0))
        effective_hard_max = int(TURN_STATE.get("explore_hard_max_chars", HARD_MAX_READ_CHARS))
        max_chars = min(requested, effective_hard_max)
        qterms = _query_terms(query)
        # For file::symbol notation, also accept the base file in the allowlist.
        file_base = file.split("::")[0] if "::" in file else file
        retrieved_files = set(TURN_STATE.get("retrieved_files", []))
        if ENFORCE_READ_ALLOWLIST and retrieved_files and file not in retrieved_files and file_base not in retrieved_files:
            payload = {
                "file": file,
                "requested_chars": requested,
                "granted_chars": 0,
                "query": query,
                "anchor": anchor,
                "mode": "allowlist_blocked",
                "retrieved_files": sorted(retrieved_files),
            }
            _log_tool("graph_read", payload)
            _record_action("read_blocked_allowlist", payload)
            return {
                "ok": False,
                "error": "file not in retrieved allowlist; call graph_retrieve with broader top_files first",
                "retrieved_files": sorted(retrieved_files),
            }
        g = _load_action_graph()
        files_meta = g.setdefault("files", {})
        meta = files_meta.get(file, {})
        gate_candidates = list(TURN_STATE.get("reuse_gate_candidates", []))
        gate_satisfied = bool(TURN_STATE.get("reuse_gate_satisfied", False))
        if ENFORCE_REUSE_GATE and gate_candidates and not gate_satisfied and file not in gate_candidates and file_base not in gate_candidates:
            payload = {
                "file": file,
                "requested_chars": requested,
                "granted_chars": 0,
                "query": query,
                "anchor": anchor,
                "mode": "reuse_gate_blocked",
                "reuse_gate_candidates": gate_candidates,
            }
            _log_tool("graph_read", payload)
            _record_action("read_blocked_reuse_gate", payload)
            return {
                "ok": False,
                "error": "reuse gate active: read one reuse candidate first",
                "reuse_gate_candidates": gate_candidates,
            }
        # Cross-turn cache hit: reuse prior excerpt for same semantic query.
        if meta and set(meta.get("query_terms", [])) & set(qterms) and meta.get("cached_content"):
            cached = str(meta.get("cached_content", ""))[:max_chars]
            payload = {
                "file": file,
                "requested_chars": requested,
                "granted_chars": len(cached),
                "query": query,
                "anchor": anchor,
                "mode": "cache_hit",
                "response_chars": len(cached),
                "response_tokens_est": _est_tokens(cached),
            }
            _log_tool("graph_read", payload)
            _record_action("read_cache_hit", payload)
            if file in gate_candidates:
                TURN_STATE["reuse_gate_satisfied"] = True
            _capture_read_memory(file, file_base, query, qterms)
            return {"ok": True, "file": file, "content": cached, "mode": "cache_hit", "from_action_graph": True}

        used = int(TURN_STATE.get("used_chars", 0))
        effective_budget = int(TURN_STATE.get("explore_budget_chars", TURN_READ_BUDGET_CHARS))
        remaining = max(0, effective_budget - used)
        if remaining <= 0:
            payload = {
                "file": file,
                "requested_chars": requested,
                "granted_chars": 0,
                "query": query,
                "anchor": anchor,
                "mode": "budget_exhausted",
                "response_chars": 0,
                "response_tokens_est": 0,
            }
            _log_tool("graph_read", payload)
            return {
                "ok": False,
                "error": "turn read budget exhausted; call graph_retrieve again or use fallback_rg",
                "budget": {
                    "used_chars": used,
                    "remaining_chars": remaining,
                    "turn_read_budget_chars": effective_budget,
                },
            }

        granted = min(max_chars, remaining)
        dedupe_key = f"{file}|{_query_key(query)}|{anchor.lower()}"
        seen = TURN_STATE.get("seen_reads", {})
        if dedupe_key in seen:
            prev = str(seen[dedupe_key])
            # Return only tiny reminder for duplicate reads in same turn.
            preview = prev[:500]
            payload = {
                "file": file,
                "requested_chars": requested,
                "granted_chars": min(500, granted),
                "query": query,
                "anchor": anchor,
                "mode": "dedupe_preview",
                "response_chars": len(preview),
                "response_tokens_est": _est_tokens(preview),
            }
            _log_tool("graph_read", payload)
            return {"ok": True, "file": file, "content": preview, "mode": "dedupe_preview", "already_returned": True}

        # Handle file::symbol notation — O(1) lookup via symbol index.
        sym_meta = None
        file_for_fs = file
        if "::" in file:
            file_for_fs, _ = file.split("::", 1)
            sym_meta = _load_symbol_index().get(file)

        tgt = (PROJECT_ROOT / file_for_fs).resolve()
        if PROJECT_ROOT not in tgt.parents and tgt != PROJECT_ROOT:
            return {"ok": False, "error": "outside project root"}
        if not tgt.exists() or not tgt.is_file():
            # Remote/Railway mode: file is not on this server's disk.
            # Fall back to content uploaded with the graph.
            graph_json = DG_DATA_DIR / "info_graph.json"
            text = None
            if graph_json.exists():
                try:
                    gdata = json.loads(graph_json.read_text(encoding="utf-8-sig"))
                    for node in gdata.get("nodes", []):
                        if node.get("path") == file_for_fs and node.get("content"):
                            text = node["content"]
                            break
                except Exception:
                    pass
            if not text:
                return {"ok": False, "error": "file not found", "file": file}
        else:
            text = tgt.read_text(encoding="utf-8", errors="ignore")
        mode = "full"
        sym_stale = False
        # If symbol notation matched, extract only the symbol's lines.
        if sym_meta:
            _lines = text.splitlines()
            _start = int(sym_meta.get("line_start", 0))
            _end = min(int(sym_meta.get("line_end", len(_lines) - 1)), len(_lines) - 1)
            text = "\n".join(_lines[_start:_end + 1])
            mode = "symbol_excerpt"
            # Staleness check: compare body hash against current file content.
            stored_hash = sym_meta.get("body_hash", "")
            if stored_hash:
                current_hash = hashlib.md5(text.encode()).hexdigest()[:8]
                sym_stale = current_hash != stored_hash
        if anchor:
            i = text.lower().find(anchor.lower())
            if i >= 0:
                start = max(0, i - granted // 2)
                end = min(len(text), i + granted // 2)
                text = text[start:end]
                mode = "anchor_excerpt"
            else:
                text = text[:granted]
                mode = "anchor_fallback_head"
        elif len(text) > granted:
            terms = _query_terms(query)
            text = _excerpt_by_terms(text, terms, granted)
            mode = "query_excerpt" if query else "head"
        TURN_STATE["used_chars"] = used + len(text)
        # Store only a 200-char fingerprint for dedupe — not the full content.
        seen[dedupe_key] = text[:200]
        if len(seen) > 20:  # evict oldest if too many entries
            oldest = next(iter(seen))
            del seen[oldest]
        TURN_STATE["seen_reads"] = seen
        payload = {
            "file": file,
            "requested_chars": requested,
            "granted_chars": granted,
            "query": query,
            "anchor": anchor,
            "mode": mode,
            "response_chars": len(text),
            "response_tokens_est": _est_tokens(text),
            "budget_used_chars": int(TURN_STATE.get("used_chars", 0)),
            "budget_remaining_chars": max(0, TURN_READ_BUDGET_CHARS - int(TURN_STATE.get("used_chars", 0))),
        }
        _log_tool("graph_read", payload)
        _record_action("read", payload)
        # Persist file cache + graph edges.
        qid = f"query:{_query_key(query)}" if query else "query:(empty)"
        _ensure_node(g, qid, "query", {"text": query})
        _ensure_node(g, file, "file")
        _add_edge(g, qid, file, "read", {"mode": mode})
        files_meta[file] = {
            "query_terms": qterms,
            "cached_content": text[:300],          # cap to 300 chars — just enough for context hints
            "cached_chars": len(text),
            "cached_tokens_est": _est_tokens(text),
            "last_action": "read",
            "last_ts": int(datetime.now(timezone.utc).timestamp()),
        }
        _save_action_graph(g)
        _capture_read_memory(file, file_base, query, qterms)
        resp: dict[str, Any] = {"ok": True, "file": file, "content": text, "mode": mode}
        if sym_stale:
            resp["stale"] = True
            resp["stale_reason"] = "symbol body changed since last graph scan — consider running graph_scan again"
        return resp

    @mcp.tool()
    def graph_neighbors(file: str, limit: int = 30) -> dict[str, Any]:
        """Return graph edges touching a file."""
        _log_tool("graph_neighbors", {"file": file, "limit": limit})
        g = _local_info_graph() or _get("/api/info-graph?full=1")
        edges = g.get("edges", [])
        out = []
        for edge in edges:
            if edge.get("from") == file or edge.get("to") == file:
                out.append(edge)
            if len(out) >= limit:
                break
        return {"ok": True, "file": file, "neighbors": out}

    @mcp.tool()
    def graph_impact(changed_files: list[str]) -> dict[str, Any]:
        """Return connected local files likely impacted by edits."""
        _log_tool("graph_impact", {"changed_files": changed_files})
        _record_action("impact", {"changed_files": changed_files})
        g = _local_info_graph() or _get("/api/info-graph?full=1")
        edges = g.get("edges", [])
        changed = set(changed_files)
        connected: set[str] = set()
        for edge in edges:
            frm = str(edge.get("from", ""))
            to = str(edge.get("to", ""))
            if frm in changed and _is_local_file_ref(to):
                connected.add(to)
            if to in changed and _is_local_file_ref(frm):
                connected.add(frm)
        return {
            "ok": True,
            "changed_files": sorted(changed),
            "connected_files": sorted(connected),
            "untouched_connected_files": sorted(x for x in connected if x not in changed),
        }

    @mcp.tool()
    def graph_register_edit(files: Union[str, list[str]], summary: str = "") -> dict[str, Any]:
        """Register edited files into in-chat action graph memory."""
        if isinstance(files, str):
            files = [files]
        # Global decision window: max verbatim entries before compression.
        # Stored ONCE per edit call (not per-file) to avoid N-file duplication.
        _DECISION_WINDOW = 20
        _DECISION_ARCHIVE_CAP = 300  # chars for compressed older decisions

        g = _load_action_graph()
        aid = f"action:edit:{int(datetime.now(timezone.utc).timestamp())}"
        _ensure_node(g, aid, "action", {"summary": summary})
        files_meta = g.setdefault("files", {})
        for f in files:
            _ensure_node(g, f, "file")
            _add_edge(g, aid, f, "edited")
            meta = files_meta.get(f, {})
            meta["last_action"] = "edited"
            meta["last_ts"] = _now_iso()
            meta["edited_count"] = int(meta.get("edited_count", 0)) + 1
            files_meta[f] = meta

        # ── Global decisions log (rolling window, stored once per edit) ───────
        # One entry per graph_register_edit call regardless of how many files.
        # This prevents N-file duplication and keeps the budget fixed.
        if summary:
            decisions: list[dict[str, Any]] = g.setdefault("decisions", [])
            decisions.append({
                "ts": int(datetime.now(timezone.utc).timestamp()),
                "summary": summary,
                "files": files,                     # which files this decision touched
                "scope": "global" if len(files) > 1 else "file",
            })
            if len(decisions) > _DECISION_WINDOW:
                overflow = decisions[:-_DECISION_WINDOW]
                g["decisions"] = decisions[-_DECISION_WINDOW:]
                # Compress overflow into archive string (rolling summary of old decisions).
                old_archive = g.get("decisions_archive", "")
                combined = "; ".join(d["summary"] for d in overflow)
                if old_archive:
                    combined = old_archive.rstrip(".") + "; " + combined
                g["decisions_archive"] = combined[:_DECISION_ARCHIVE_CAP]
            symbol_index = _load_symbol_index()
            symbol_id = ""
            file_path = ""
            symbol_hash = ""
            if files:
                symbol_id, file_path, symbol_hash = _memory_anchor_for_ref(str(files[0]), symbol_index)
                if not file_path:
                    file_path = str(files[0]).split("::")[0]
            evidence = _recent_action_evidence([str(f) for f in files])
            _upsert_context_memory(
                {
                    "id": _memory_id(),
                    "kind": "decision",
                    "content": summary,
                    "tags": _query_terms(summary),
                    "files": [str(f) for f in files],
                    "file_path": file_path,
                    "symbol_id": symbol_id,
                    "symbol_hash": symbol_hash,
                    "created_at": _now_iso(),
                    "created_epoch": int(datetime.now(timezone.utc).timestamp()),
                    "updated_at": _now_iso(),
                    "stale": False,
                    "stale_reason": "",
                    "observed_queries": evidence.get("recent_queries", []),
                    "evidence": evidence,
                },
                symbol_index,
            )
        symbol_index = _load_symbol_index()
        for f in files:
            symbol_id, file_path, symbol_hash = _memory_anchor_for_ref(str(f), symbol_index)
            if not file_path:
                file_path = str(f).split("::")[0]
            evidence = _recent_action_evidence([str(f)])
            recent_queries = list(evidence.get("recent_queries", []))
            content = f"Edited after query: {recent_queries[0]}" if recent_queries else "Edited during active session"
            _upsert_context_memory(
                {
                    "kind": "edit_observation",
                    "content": content,
                    "tags": _query_terms(summary or content),
                    "files": [str(f)],
                    "file_path": file_path,
                    "symbol_id": symbol_id,
                    "symbol_hash": symbol_hash,
                    "created_at": _now_iso(),
                    "created_epoch": int(datetime.now(timezone.utc).timestamp()),
                    "updated_at": _now_iso(),
                    "stale": False,
                    "stale_reason": "",
                    "observed_queries": recent_queries,
                    "evidence": {
                        "source": "graph_register_edit",
                        "recent_action_kinds": evidence.get("recent_action_kinds", []),
                        "recent_queries": recent_queries,
                        "edited": True,
                    },
                },
                symbol_index,
            )
        # ─────────────────────────────────────────────────────────────────────

        # Detect first-ever edit to surface "graph primed" signal
        prior_edit_count = sum(
            int(g.get("files", {}).get(f, {}).get("edited_count", 0)) for f in g.get("files", {})
        )
        _save_action_graph(g)
        payload = {"files": files, "summary": summary}
        invalidated = _invalidate_retrieval_cache_for_files(files)
        _log_tool("graph_register_edit", payload)
        _record_action("register_edit", {"files": files, "summary": summary, "retrieval_cache_invalidated": invalidated})
        result: dict[str, Any] = {"ok": True, "edited_files": files, "count": len(files), "retrieval_cache_invalidated": invalidated}
        if prior_edit_count == 0:
            result["graph_state"] = "primed"
            result["graph_state_reason"] = "Structural signal established. Future turns will use memory_first routing."
        return result

    @mcp.tool()
    def graph_action_summary(query: str = "", limit: int = 12) -> dict[str, Any]:
        """Return recent action graph summary + query-relevant touched files."""
        g = _load_action_graph()
        actions = g.get("actions", [])
        files_meta = g.get("files", {})
        recent = actions[-limit:]
        qterms = set(_query_terms(query))
        relevant = []
        for file, meta in files_meta.items():
            overlap = len(qterms & set(meta.get("query_terms", [])))
            if query and overlap <= 0:
                continue
            relevant.append({
                "file": file,
                "overlap": overlap,
                "last_action": meta.get("last_action", ""),
                "edited_count": int(meta.get("edited_count", 0)),
                "cached_tokens_est": int(meta.get("cached_tokens_est", 0)),
                "last_ts": meta.get("last_ts", ""),
            })
        relevant.sort(key=lambda x: (-x["overlap"], -x["edited_count"], -x["cached_tokens_est"], x["file"]))

        # ── Global decisions log ──────────────────────────────────────────────
        # Return only decisions relevant to the current query (or last 5 if no query).
        all_decisions: list[dict[str, Any]] = g.get("decisions", [])
        if query and qterms:
            file_set = {f["file"] for f in relevant}
            scored: list[tuple[int, dict[str, Any]]] = []
            for d in all_decisions:
                # Score by term overlap in summary + file intersection with relevant set.
                term_hits = sum(1 for t in qterms if t in d.get("summary", "").lower())
                file_hits = len(set(d.get("files", [])) & file_set)
                score = term_hits * 2 + file_hits
                if score > 0:
                    scored.append((score, d))
            scored.sort(key=lambda x: (-x[0], -x[1]["ts"]))
            shown_decisions = [d for _, d in scored[:5]]
        else:
            shown_decisions = all_decisions[-5:]  # most recent 5 when no query

        payload = {"query": query, "limit": limit}
        _log_tool("graph_action_summary", payload)
        _record_action("action_summary", payload)
        out: dict[str, Any] = {
            "ok": True,
            "recent_actions": recent,
            "relevant_files": relevant[:limit],
            "decisions": shown_decisions,
            "memories": _search_context_store(query, [f["file"] for f in relevant[:limit]], limit=5),
        }
        if g.get("decisions_archive"):
            out["decisions_archive"] = g["decisions_archive"]
        return out

    @mcp.tool()
    def graph_continue(query: str, top_files: int = 5, top_edges: int = 12, limit: int = 8) -> dict[str, Any]:
        """
        Continue a conversation using action-memory search first, then info-graph retrieval only if needed.
        Returns compact context hints instead of full chat dump.

        IMPORTANT — project setup check:
        If the response contains needs_project=True, no project has been scanned yet.
        You MUST:
          1. Ask the user: "Which directory should I scan? (default: current working directory)"
          2. Use their answer (or current working directory / pwd if they confirm the default).
          3. Call graph_scan(project_root=<path>) with that path.
          4. Then call graph_continue again to proceed with the original query.
        Do NOT attempt to answer the query until graph_scan has been called.
        """
        # ── Project setup gate ────────────────────────────────────────────────
        # Only check the graph file — NOT PROJECT_ROOT.is_dir().
        # In the Railway upload model the project directory never exists on the
        # server; the graph arrives via POST /ingest-graph, so the graph file
        # is the only reliable signal that the project has been scanned.
        graph_json = DG_DATA_DIR / "info_graph.json"
        graph_missing = not graph_json.exists()
        graph_empty = False
        gdata: dict[str, Any] = {}
        if not graph_missing:
            try:
                gdata = json.loads(graph_json.read_text(encoding="utf-8-sig"))
                graph_empty = gdata.get("node_count", 0) == 0
            except Exception:
                graph_empty = True
        if graph_missing or graph_empty:
            gb_script = str(Path(__file__).resolve().parent / "graph_builder.py")
            ingest_url = f"{DG_BASE}/ingest-graph"
            return {
                "ok": False,
                "needs_project": True,
                "query": query,
                "project_root": str(PROJECT_ROOT),
                "graph_builder": gb_script,
                "ingest_url": ingest_url,
            }

        # Stale-graph guard (locked/local mode only): info_graph.json was built
        # for a different project. Force a re-scan rather than serving wrong files.
        if _LOCKED_PROJECT_ROOT is not None:
            stamped_root = gdata.get("root")
            if stamped_root:
                try:
                    stamped_resolved = Path(stamped_root).resolve()
                except Exception:
                    stamped_resolved = None
                if stamped_resolved is not None and stamped_resolved != PROJECT_ROOT:
                    return {
                        "ok": False,
                        "needs_project": True,
                        "query": query,
                        "project_root": str(PROJECT_ROOT),
                        "stale_graph_for": str(stamped_resolved),
                        "hint": (
                            f"info_graph.json under .dual-graph/ was built for "
                            f"{stamped_resolved}, not {PROJECT_ROOT}. Call "
                            f"graph_scan(project_root='{PROJECT_ROOT}') to rebuild."
                        ),
                    }

        # Phase 0: Handle truly empty/greenfield projects (< 5 files).
        # Projects with 5+ files get full graph treatment regardless of prior edits.
        file_count = gdata.get("file_count", gdata.get("node_count", 0))
        if file_count < 5:
            _DESIGN_TERMS = {
                "design", "create", "build", "plan", "architecture", "structure",
                "scaffold", "implement", "setup", "initialize", "how should", "what should",
                "start", "begin", "new", "project", "app", "service",
            }
            q_lower = query.lower()
            is_design_query = any(t in q_lower for t in _DESIGN_TERMS)
            if is_design_query:
                retrieved = graph_retrieve(query=query, top_files=top_files, top_edges=top_edges)
                graph_files = retrieved.get("graph_files", [])
                rec_files = [str(f.get("id", "")) for f in graph_files if str(f.get("id", ""))]
                return {
                    "ok": True,
                    "mode": "bootstrap_explore",
                    "project_root": str(PROJECT_ROOT),
                    "note": "Greenfield project — allowing exploratory read to seed graph.",
                    "recommended_files": rec_files[: min(3, len(rec_files))],
                    "graph_edges": retrieved.get("graph_edges", []),
                }
            return {
                "ok": True,
                "skip": True,
                "project_root": str(PROJECT_ROOT),
                "cold_start_reason": "empty_project",
                "file_count": file_count,
                "hint": "Project has fewer than 5 files. Use targeted reads only — do NOT explore broadly.",
                "next_best_action": "Ask the user what they want to work on, or read a specific file if named.",
            }

        hist = _search_action_history(query, limit=limit)
        file_hits = hist.get("file_hits", [])
        action_hits = hist.get("action_hits", [])

        # If we already have relevant cached files from prior turns, prefer those first.
        def _access_type(file: str, files_meta: dict) -> str:
            """Classify a file as 'new', 'read', or 'write' based on action graph history."""
            meta = files_meta.get(file, {})
            if int(meta.get("edited_count", 0)) > 0:
                return "write"
            if meta.get("last_action"):
                return "read"
            return "new"

        files_meta = _load_action_graph().get("files", {})

        # Require min overlap to avoid false memory-first routing on single-word matches.
        strong_file_hits = [f for f in file_hits if int(f.get("overlap", 0)) >= MEMORY_FIRST_MIN_OVERLAP]
        if strong_file_hits:
            file_hits = strong_file_hits
            rec = [f["file"] for f in file_hits[: min(3, len(file_hits))]]
            # Apply time-decay: files only recommended if touched in recent 5 actions.
            recent_files = {a.get("file", "") for a in action_hits}
            rec = [f for f in rec if f in recent_files] or rec
            rec_with_type = [{"file": f, "access_type": _access_type(f, files_meta)} for f in rec]
            # Intent-aware cap: explore queries must not be locked out of supplementary search.
            mem_query_intent = _dg_classify_intent(query) if _dg_classify_intent else "general"
            mem_confidence = "high"
            mem_max_greps = 0
            mem_max_files = 0
            if mem_query_intent == "explore":
                mem_confidence = "medium"
                mem_max_greps = max(mem_max_greps, 1)
            out = {
                "ok": True,
                "mode": "memory_first",
                "project_root": str(PROJECT_ROOT),
                "confidence": mem_confidence,
                "max_supplementary_greps": mem_max_greps,
                "max_supplementary_files": mem_max_files,
                "query": query,
                "intent": mem_query_intent,
                "recommended_files": rec_with_type,
                "memories": _search_context_store(query, rec, limit=3),
            }
            _log_tool("graph_continue", {"query": query, "mode": "memory_first", "recommended_files": rec})
            _record_action("continue_memory_first", {"query": query, "recommended_files": rec})
            return out

        # No relevant memory: do single retrieval and return compact suggestions.
        retrieved = graph_retrieve(query=query, top_files=top_files, top_edges=top_edges)
        graph_files = retrieved.get("graph_files", [])
        rec_files = [str(f.get("id", "")) for f in graph_files if str(f.get("id", ""))]

        # ── Confidence tier based on top file score ───────────────────────────
        # Scores are integers from dg.score_node: 10+ = strong match, 4-9 = moderate, <4 = weak.
        top_score = int(graph_files[0].get("_score", 0)) if graph_files else 0
        if top_score >= 10:
            confidence = "high"
            max_supp_greps = 0
            max_supp_files = 0
        elif top_score >= 4:
            confidence = "medium"
            max_supp_greps = 2
            max_supp_files = 2
        else:
            confidence = "low"
            max_supp_greps = 3
            max_supp_files = 3

        # Exploration cap: broad architecture/trace queries must not be locked out of
        # supplementary search even when keyword scores are high.
        query_intent = _dg_classify_intent(query) if _dg_classify_intent else "general"
        if query_intent == "explore":
            if confidence == "high":
                confidence = "medium"
            max_supp_greps = max(max_supp_greps, 2)
            max_supp_files = max(max_supp_files, 2)
            TURN_STATE["explore_budget_chars"] = EXPLORE_READ_BUDGET_CHARS
            TURN_STATE["explore_hard_max_chars"] = EXPLORE_MAX_READ_CHARS

        rec_slice = rec_files[: min(3, len(rec_files))]
        rec_with_type_rt = [{"file": f, "access_type": _access_type(f, files_meta)} for f in rec_slice]
        out = {
            "ok": True,
            "mode": "retrieve_then_read",
            "project_root": str(PROJECT_ROOT),
            "confidence": confidence,
            "max_supplementary_greps": max_supp_greps,
            "max_supplementary_files": max_supp_files,
            "query": query,
            "intent": query_intent,
            "recommended_files": rec_with_type_rt,
            "memories": _search_context_store(query, rec_slice, limit=3),
        }
        _log_tool("graph_continue", {"query": query, "mode": "retrieve_then_read", "confidence": confidence, "recommended_files": rec_slice})
        _record_action("continue_retrieve", {"query": query, "recommended_files": rec_slice})
        return out

    @mcp.tool()
    def fallback_rg(pattern: str, max_hits: int = 30) -> dict[str, Any]:
        """Controlled fallback grep if retriever confidence is low."""
        calls = int(TURN_STATE.get("fallback_calls", 0))
        if calls >= FALLBACK_MAX_CALLS_PER_TURN:
            payload = {
                "pattern": pattern,
                "max_hits": max_hits,
                "mode": "fallback_blocked_limit",
                "fallback_calls": calls,
                "fallback_max_calls": FALLBACK_MAX_CALLS_PER_TURN,
            }
            _log_tool("fallback_rg", payload)
            _record_action("fallback_blocked_limit", payload)
            return {
                "ok": False,
                "error": "fallback_rg call limit reached for this query turn",
                "fallback_calls": calls,
                "fallback_max_calls": FALLBACK_MAX_CALLS_PER_TURN,
            }
        _log_tool("fallback_rg", {"pattern": pattern, "max_hits": max_hits})
        cmd = ["rg", "-n", "-S", "--max-count", str(max_hits), pattern, "."]
        proc = subprocess.run(
            cmd,
            cwd=str(PROJECT_ROOT),
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        hits = []
        for line in proc.stdout.splitlines():
            parts = line.split(":", 2)
            if len(parts) == 3:
                hits.append({"file": parts[0], "line": parts[1], "text": parts[2]})
            if len(hits) >= max_hits:
                break
        TURN_STATE["fallback_calls"] = calls + 1
        return {"ok": True, "pattern": pattern, "hits": hits}

    @mcp.tool()
    def graph_add_memory(
        type: str,
        content: str,
        tags: list[str] | None = None,
        files: list[str] | None = None,
    ) -> dict[str, Any]:
        """Add a memory entry to the context store with automatic pruning.

        Use this instead of writing context-store.json directly. It ensures
        the store stays healthy and never bloats beyond its cap.

        Args:
            type: Entry kind — decision | task | next | fact | blocker
            content: One sentence, max 15 words.
            tags: Optional list of topic tags.
            files: Optional list of relevant file paths.
        """
        now = datetime.now(timezone.utc)
        entry: dict[str, Any] = {
            "kind": type,
            "content": content,
            "tags": tags or [],
            "files": files or [],
            "created_at": now.isoformat(),
            "created_epoch": int(now.timestamp()),
        }
        existing = _load_context_store()
        existing.append(entry)
        _save_context_store(existing)
        total = len(_load_context_store())
        return {"ok": True, "total": total}

    @mcp.tool()
    def graph_scan(project_root: str) -> dict[str, Any]:
        """Scan a local project directory and build/refresh its information graph.

        Call this once at the start of a session to point the dual-graph at your
        project folder. After scanning, graph_retrieve / graph_read / graph_continue
        will work against that project.

        Args:
            project_root: Absolute path to the project directory to scan.
        """
        global PROJECT_ROOT  # noqa: PLW0603

        if _gb_scan is None:
            return {"ok": False, "error": "graph_builder not available"}

        root = Path(project_root).expanduser().resolve()
        if not root.is_dir():
            return {"ok": False, "error": f"Not a directory: {root}"}

        # Lock check: this MCP process is bound to one project for its lifetime.
        # Refuse to flip to a different project — that would silently corrupt
        # the running session's view of the graph.
        if _LOCKED_PROJECT_ROOT is not None and root != _LOCKED_PROJECT_ROOT:
            return {
                "ok": False,
                "error": (
                    f"MCP server is locked to {_LOCKED_PROJECT_ROOT}; refusing "
                    f"graph_scan({root}). Each Claude/Codex session uses its own "
                    "MCP process bound to one project — run dgc/dg in the other "
                    "project's directory to spawn a separate server for it."
                ),
                "locked_project_root": str(_LOCKED_PROJECT_ROOT),
                "attempted_project_root": str(root),
            }

        # Load existing nodes for incremental re-scan (preserve summaries for unchanged files).
        graph_json = DG_DATA_DIR / "info_graph.json"
        existing_nodes: dict = {}
        if graph_json.exists():
            try:
                old_graph = json.loads(graph_json.read_text(encoding="utf-8-sig"))
                existing_nodes = {n["id"]: n for n in old_graph.get("nodes", []) if n.get("kind") == "file"}
            except Exception:
                pass

        graph = _gb_scan(root, existing_nodes=existing_nodes)

        # Write to the same JSON the dashboard serves.
        graph_json = DG_DATA_DIR / "info_graph.json"
        graph_json.parent.mkdir(parents=True, exist_ok=True)
        graph_json.write_text(json.dumps(graph, indent=2), encoding="utf-8")

        # Build and persist symbol index for O(1) graph_read lookups.
        sym_index = _build_symbol_index(graph)
        SYMBOL_INDEX_FILE.write_text(json.dumps(sym_index), encoding="utf-8")
        _reconcile_context_store(sym_index)

        # Update module-level root so graph_read / fallback_rg resolve correctly.
        PROJECT_ROOT = root

        # ── Reset all project-specific state ─────────────────────────────────
        # Retrieval cache: scores are stale from the old project.
        # Symbol index was already written above — do NOT delete it here.
        RETRIEVAL_CACHE_FILE.unlink(missing_ok=True)

        # Action graph: file reads/edits belong to the old project.
        _save_action_graph({"nodes": [], "edges": [], "files": {}, "actions": []})

        # Turn state: in-memory budgets, seen reads, retrieved file list.
        TURN_STATE.update({
            "query_key": "",
            "used_chars": 0,
            "seen_reads": {},
            "reuse_gate_candidates": [],
            "reuse_gate_satisfied": False,
            "retrieved_files": [],
            "retrieve_count": 0,
            "last_retrieve_out": None,
            "fallback_calls": 0,
        })

        file_count = graph.get("file_count", graph["node_count"])
        symbol_count = graph.get("symbol_count", 0)
        _log_tool("graph_scan", {"project_root": str(root), "files": file_count, "symbols": symbol_count, "edges": graph["edge_count"]})
        return {
            "ok": True,
            "project_root": str(root),
            "file_count": file_count,
            "symbol_count": symbol_count,
            "edge_count": graph["edge_count"],
            "message": "Graph built. Use graph_continue or graph_retrieve to query.",
        }

    return mcp


_HEARTBEAT_INTERVAL_SEC = 15 * 60  # ping every 15 minutes


def _normalize_runtime_toolname(value: object) -> str:
    toolname = str(value or "").strip().lower()
    return toolname if toolname in {"claude", "codex", "graperoot"} else "unknown"


def _ping_license_server() -> None:
    """Startup ping + periodic heartbeat so last_seen stays current during active sessions.
    Auto-creates identity.json on first run. Runs as a daemon thread (dies with the process)
    and works identically on macOS, Linux, and Windows."""
    import platform as _platform
    import threading
    import uuid

    def _generate_random_id() -> str:
        """Generate a random installation ID (no hardware info collected)."""
        return uuid.uuid4().hex

    def _load_payload() -> bytes | None:
        """Load (or create) identity and return the encoded JSON payload."""
        import datetime
        try:
            identity_path = Path.home() / ".dual-graph" / "identity.json"
            if not identity_path.exists():
                identity = {
                    "machine_id": _generate_random_id(),
                    "platform": _platform.system().lower(),
                    "installed_date": datetime.date.today().isoformat(),
                    "tool": "mcp-auto",
                    "toolname": "unknown",
                }
                identity_path.parent.mkdir(parents=True, exist_ok=True)
                identity_path.write_text(json.dumps(identity), encoding="utf-8")
            else:
                identity = json.loads(identity_path.read_text(encoding="utf-8-sig"))
                # Existing users: just stamp installed_date, keep their ID intact
                if "installed_date" not in identity:
                    identity["installed_date"] = datetime.date.today().isoformat()
                    identity_path.write_text(json.dumps(identity), encoding="utf-8")
            machine_id = identity.get("machine_id", "")
            if not machine_id:
                return None
            return json.dumps({
                "machine_id": machine_id,
                "platform": identity.get("platform", "unknown"),
                "tool": identity.get("tool", "unknown"),
                "toolname": _normalize_runtime_toolname(os.environ.get("DG_TOOLNAME") or identity.get("toolname")),
            }).encode("utf-8")
        except Exception:
            return None

    def _send(payload: bytes) -> None:
        try:
            req = urllib.request.Request(
                "https://dual-graph-license-production.up.railway.app/ping",
                data=payload,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            urllib.request.urlopen(req, timeout=4)
        except Exception:
            pass  # never crash the MCP server

    def _read_token_totals() -> dict | None:
        """Read cumulative token totals from token-counter MCP's history.json."""
        try:
            history_path = Path.home() / ".claude" / "token-counter" / "history.json"
            if not history_path.exists():
                return None
            entries = json.loads(history_path.read_text(encoding="utf-8"))
            if not isinstance(entries, list) or not entries:
                return None

            def model_key(model: str) -> str:
                m = (model or "").lower()
                if "opus" in m:   return "claude-opus"
                if "sonnet" in m: return "claude-sonnet"
                if "haiku" in m:  return "claude-haiku"
                return "claude-sonnet"

            totals: dict = {}
            for e in entries:
                mk = model_key(e.get("model", ""))
                t = totals.setdefault(mk, {"input": 0, "output": 0, "cache_write": 0, "cache_read": 0, "cost": 0.0})
                t["input"]       += int(e.get("inputTokens", 0))
                t["output"]      += int(e.get("outputTokens", 0))
                t["cache_write"] += int(e.get("cacheWriteTokens", 0))
                t["cache_read"]  += int(e.get("cacheReadTokens", 0))
                t["cost"]        += float(e.get("totalCost", 0.0))

            gi = go = gcw = gcr = 0
            gc = 0.0
            by_model = {}
            for mk, t in totals.items():
                by_model[mk] = {"input_tokens": t["input"], "output_tokens": t["output"],
                                 "cache_write_tokens": t["cache_write"], "cache_read_tokens": t["cache_read"],
                                 "cost_usd": round(t["cost"], 6)}
                gi += t["input"]; go += t["output"]; gcw += t["cache_write"]; gcr += t["cache_read"]; gc += t["cost"]

            if gi == 0:
                return None
            return {"input_tokens": gi, "output_tokens": go, "cache_write_tokens": gcw,
                    "cache_read_tokens": gcr, "cost_usd": round(gc, 6), "by_model": by_model}
        except Exception:
            return None

    def _heartbeat_loop() -> None:
        base = _load_payload()
        if base is None:
            return
        # Startup ping — no active_seconds yet, but include token totals if available
        try:
            d = json.loads(base.decode("utf-8"))
            tt = _read_token_totals()
            if tt:
                d["token_totals"] = tt
            _send(json.dumps(d).encode("utf-8"))
        except Exception:
            _send(base)
        while True:
            time.sleep(_HEARTBEAT_INTERVAL_SEC)
            # Each heartbeat credits the interval as active time + fresh token totals
            try:
                d = json.loads(base.decode("utf-8"))
                d["active_seconds"] = _HEARTBEAT_INTERVAL_SEC
                tt = _read_token_totals()
                if tt:
                    d["token_totals"] = tt
                payload = json.dumps(d).encode("utf-8")
            except Exception:
                payload = base
            _send(payload)

    threading.Thread(target=_heartbeat_loop, daemon=True).start()


def main() -> int:
    if "--stdio" in _sys.argv:
        return _main_stdio()

    import anyio
    import uvicorn
    from starlette.requests import Request
    from starlette.responses import JSONResponse, Response
    from starlette.routing import Route

    preferred = int(os.environ.get("PORT", 8080))
    port = preferred
    _port_ceiling = max(preferred + 120, 8200)  # match launcher's 8080-8199 scan range
    for _p in range(preferred, min(_port_ceiling, 65535)):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as _s:
            _s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                _s.bind(("127.0.0.1", _p))
                port = _p
                break
            except (OSError, OverflowError):
                continue
    else:
        raise RuntimeError(f"no free port in {preferred}-{min(_port_ceiling, 65535) - 1}")
    DG_DATA_DIR.mkdir(parents=True, exist_ok=True)
    if port != preferred:
        logging.getLogger(__name__).warning("Port %d in use, using %d", preferred, port)
        os.environ["PORT"] = str(port)
        try:
            (DG_DATA_DIR / "mcp_port").write_text(str(port), encoding="utf-8")
        except OSError:
            pass
    _ping_license_server()
    mcp = build_server(host="127.0.0.1", port=port)

    # Custom /ingest-graph route: accepts pre-built graph JSON from local machine
    # so users can run: graph_builder.py locally -> POST here -> chat via MCP
    async def ingest_graph(request: Request) -> JSONResponse:
        try:
            graph = await request.json()
            if "nodes" not in graph or "edges" not in graph:
                return JSONResponse({"ok": False, "error": "missing nodes/edges"}, status_code=400)
        except Exception as exc:
            return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)
        graph_json = DG_DATA_DIR / "info_graph.json"
        graph_json.parent.mkdir(parents=True, exist_ok=True)
        # Rewrite the stamped root to this server's PROJECT_ROOT. The graph was
        # built on a different machine where paths look different; we serve it
        # under the local project, so the stamp must reflect that to keep the
        # stale-graph guard from rejecting valid ingests.
        graph["root"] = str(PROJECT_ROOT)
        graph_json.write_text(json.dumps(graph, indent=2), encoding="utf-8")
        # Build and persist symbol index for O(1) graph_read lookups.
        sym_index = _build_symbol_index(graph)
        SYMBOL_INDEX_FILE.write_text(json.dumps(sym_index), encoding="utf-8")
        _reconcile_context_store(sym_index)
        # Invalidate retrieval cache so new graph is used immediately.
        RETRIEVAL_CACHE_FILE.unlink(missing_ok=True)
        return JSONResponse({
            "ok": True,
            "node_count": graph.get("node_count", len(graph["nodes"])),
            "edge_count": graph.get("edge_count", len(graph["edges"])),
        })

    # ── Static file routes: serve dg + graph_builder so users can curl-install ──
    _HERE = Path(__file__).resolve().parent

    async def serve_graph_builder(request: Request) -> Response:
        gb = _HERE / "graph_builder.py"
        return Response(gb.read_text(encoding="utf-8"), media_type="text/plain")

    async def serve_dg(request: Request) -> Response:
        return Response((_HERE / "dg").read_text(encoding="utf-8"), media_type="text/plain")

    async def serve_dgc(request: Request) -> Response:
        return Response((_HERE / "dgc").read_text(encoding="utf-8"), media_type="text/plain")

    async def serve_mcp_server(request: Request) -> Response:
        return Response((_HERE / "mcp_graph_server.py").read_text(encoding="utf-8"), media_type="text/plain")

    async def serve_install(request: Request) -> Response:
        base = str(request.base_url).rstrip("/")
        script = f"""\
#!/usr/bin/env bash
set -euo pipefail
BASE_URL="{base}"
INSTALL_DIR="$HOME/.dual-graph"
mkdir -p "$INSTALL_DIR"

echo "[install] Downloading files..."
curl -sSL "$BASE_URL/graph_builder.py"    -o "$INSTALL_DIR/graph_builder.py"
curl -sSL "$BASE_URL/mcp_graph_server.py" -o "$INSTALL_DIR/mcp_graph_server.py"
curl -sSL "$BASE_URL/dg"  -o "$INSTALL_DIR/dg"  && chmod +x "$INSTALL_DIR/dg"
curl -sSL "$BASE_URL/dgc" -o "$INSTALL_DIR/dgc" && chmod +x "$INSTALL_DIR/dgc"

echo "[install] Installing Python dependencies..."
python3 -m pip install "mcp>=1.3.0" uvicorn anyio starlette --quiet

# Add to PATH if not already there
SHELL_RC="$HOME/.zshrc"
[[ "$SHELL" == */bash ]] && SHELL_RC="$HOME/.bashrc"
if ! grep -q '.dual-graph' "$SHELL_RC" 2>/dev/null; then
  echo 'export PATH="$PATH:$HOME/.dual-graph"' >> "$SHELL_RC"
  echo "[install] Added ~/.dual-graph to PATH in $SHELL_RC"
fi

echo ""
echo "[install] Done! Run these once:"
echo "  source $SHELL_RC"
echo ""
echo "  # Register for Codex CLI (uses Railway):"
echo "  codex mcp add dual-graph --url $BASE_URL/mcp"
echo ""
echo "  # Register for Claude Code (uses local server):"
echo "  claude mcp add --transport http dual-graph http://localhost:8080/mcp"
echo ""
echo "Then per project:"
echo "  dg /path/to/project    # Codex CLI  (Railway MCP)"
echo "  dgc /path/to/project   # Claude Code (local MCP, fully private)"
"""
        return Response(script, media_type="text/plain")

    # Get the MCP app with its lifespan (session manager) intact.
    # IMPORTANT: do NOT wrap mcp_app in a new Starlette app via Mount("/") —
    # that kills the inner lifespan so the session manager never starts,
    # causing every /mcp request to return HTTP 500.
    # Instead, prepend our custom routes directly into mcp_app's own router
    # so it remains the top-level ASGI app and its lifespan runs normally.
    async def prime(request: Request) -> Response:
        """Compact plain-text action graph summary for Claude Code hooks (SessionStart/PreCompact)."""
        g = _load_action_graph()
        files_meta = g.get("files", {})
        decisions = g.get("decisions", [])[-5:]
        decisions_archive = g.get("decisions_archive", "")
        memories = _search_context_store("", [], limit=5)

        edited = sorted(
            [(f, m) for f, m in files_meta.items() if int(m.get("edited_count", 0)) > 0],
            key=lambda x: -int(x[1].get("edited_count", 0)),
        )

        lines = ["# Dual-Graph Context", f"Project: {PROJECT_ROOT}"]
        graph_json = DG_DATA_DIR / "info_graph.json"
        if graph_json.exists():
            try:
                gdata = json.loads(graph_json.read_text(encoding="utf-8-sig"))
                lines.append(f"Files scanned: {gdata.get('file_count', gdata.get('node_count', '?'))}")
            except Exception:
                pass

        if edited:
            lines.append("\n## Recently edited")
            for f, m in edited[:8]:
                lines.append(f"- {f} (edited {int(m.get('edited_count', 0))}x)")

        if decisions or decisions_archive:
            lines.append("\n## Decisions")
            if decisions_archive:
                lines.append(f"(older) {decisions_archive}")
            for d in decisions:
                lines.append(f"- {d.get('summary', '')}")

        if memories:
            lines.append("\n## Memories")
            for mem in memories:
                label = "[STALE] " if mem.get("stale") else ""
                anchor = mem.get("symbol_id") or mem.get("file_path") or ""
                suffix = f" ({anchor})" if anchor else ""
                lines.append(f"- {label}{mem.get('content', '')}{suffix}")

        if not edited and not decisions and not memories:
            lines.append("\n(No prior edits recorded — graph is fresh)")

        return Response("\n".join(lines), media_type="text/plain")

    # ── Token usage log endpoint ────────────────────────────────────────────
    # The Stop hook POSTs session usage here. Saved to .dual-graph/token_log.jsonl
    # so the dashboard can read it via /api/token-summary and /api/token-dataset.
    async def log_token_usage(request: Request) -> Response:
        try:
            body = await request.json()
        except Exception:
            return Response('{"ok":false}', status_code=400, media_type="application/json")
        ts = datetime.now(timezone.utc).isoformat()
        # input_tokens = raw (non-cached) input only. Cache sent separately.
        raw = int(body.get("input_tokens", 0))
        output_tk = int(body.get("output_tokens", 0))
        cc = int(body.get("cache_creation_input_tokens", 0))
        cr = int(body.get("cache_read_input_tokens", 0))
        model = str(body.get("model", "unknown"))
        # Cost calculation
        is_opus = "opus" in model.lower()
        if is_opus:
            cost = (raw * 15.0 + cc * 18.75 + cr * 1.50 + output_tk * 75.0) / 1_000_000
        else:  # sonnet / default
            cost = (raw * 3.0 + cc * 3.75 + cr * 0.30 + output_tk * 15.0) / 1_000_000
        event = {
            "timestamp": ts,
            "model": model,
            "input_tokens": raw,
            "output_tokens": output_tk,
            "cache_creation_input_tokens": cc,
            "cache_read_input_tokens": cr,
            "total_tokens": raw + cc + cr + output_tk,
            "cost_usd": round(cost, 6),
            "project": str(body.get("project", "")),
            "description": str(body.get("description", "")),
            "mode": "session",
        }
        log_path = DG_DATA_DIR / "token_log.jsonl"
        try:
            with open(log_path, "a", encoding="utf-8") as f:
                f.write(json.dumps(event) + "\n")
        except OSError:
            pass
        return Response(json.dumps({"ok": True, "cost_usd": event["cost_usd"]}), media_type="application/json")

    mcp_app = mcp.streamable_http_app()
    mcp_app.router.routes[0:0] = [
        Route("/prime", prime, methods=["GET"]),
        Route("/log", log_token_usage, methods=["POST"]),
        Route("/ingest-graph", ingest_graph, methods=["POST"]),
        Route("/install.sh", serve_install, methods=["GET"]),
        Route("/dgc", serve_dgc, methods=["GET"]),
        Route("/dg", serve_dg, methods=["GET"]),
        Route("/graph_builder.py", serve_graph_builder, methods=["GET"]),
        Route("/mcp_graph_server.py", serve_mcp_server, methods=["GET"]),
    ]

    async def serve() -> None:
        config = uvicorn.Config(mcp_app, host="127.0.0.1", port=port, log_level="error")
        await uvicorn.Server(config).serve()

    anyio.run(serve)
    return 0


def _main_stdio() -> int:
    """stdio MCP transport — Claude Code spawns + owns the lifecycle.

    No port needed. Claude Code sends JSON-RPC over stdin, reads from stdout.
    Set DG_DATA_DIR and DUAL_GRAPH_PROJECT_ROOT env vars before invoking.
    """
    if FastMCP is None:
        print("[dual-graph] FastMCP not installed; run: pip install mcp", file=_sys.stderr)
        return 1
    DG_DATA_DIR.mkdir(parents=True, exist_ok=True)
    mcp = build_server(host="127.0.0.1", port=0)
    mcp.run("stdio")
    return 0


if __name__ == "__main__":
    if "--stdio" in _sys.argv:
        raise SystemExit(_main_stdio())
    raise SystemExit(main())
