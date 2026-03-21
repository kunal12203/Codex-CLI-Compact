"""
graph_snapshot.py — Snapshot info_graph.json before each rescan.

Saves a timestamped copy plus a metadata sidecar so that bad graph
recommendations can be traced post-session.  Rotates to the last 5
snapshot pairs.  Fails silently on any error — must never block a scan.

Usage (from launch scripts):
    python graph_snapshot.py <data_dir> [trigger]

    data_dir  — path to .dual-graph/ (contains info_graph.json)
    trigger   — "manual" (default) or "auto"
"""

from __future__ import annotations

import json
import os
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

MAX_SNAPSHOTS = 5


def save_graph_snapshot(
    info_graph_path: str | os.PathLike,
    data_dir: str | os.PathLike,
    trigger: str = "manual",
) -> None:
    """Save a timestamped snapshot of info_graph.json before it is overwritten.

    Also writes a .meta.json sidecar with:
    - scan_trigger
    - file_count (number of nodes in current graph)
    - action_log_offset (line count of mcp_tool_calls.jsonl at this moment)

    Fails silently on any error — must never block a scan.
    """
    try:
        info_graph = Path(info_graph_path)
        if not info_graph.is_file():
            return  # nothing to snapshot

        data = Path(data_dir)
        snap_dir = data / "graph_snapshots"
        snap_dir.mkdir(parents=True, exist_ok=True)

        # ISO timestamp safe for filenames (colons replaced with dashes)
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%S")

        snapshot_path = snap_dir / f"info_graph_{ts}.json"
        meta_path = snap_dir / f"info_graph_{ts}.meta.json"

        # 1. Copy existing info_graph.json
        shutil.copy2(str(info_graph), str(snapshot_path))

        # 2. Read file_count from graph
        file_count = 0
        try:
            with open(info_graph, "r", encoding="utf-8") as f:
                graph_data = json.load(f)
            if isinstance(graph_data, dict):
                # count top-level nodes (files) — common structures:
                # {"nodes": [...]} or {"files": {...}} or flat dict of paths
                if "nodes" in graph_data:
                    file_count = len(graph_data["nodes"])
                elif "files" in graph_data:
                    file_count = len(graph_data["files"])
                else:
                    file_count = len(graph_data)
            elif isinstance(graph_data, list):
                file_count = len(graph_data)
        except Exception:
            pass

        # 3. Read action_log_offset (line count of mcp_tool_calls.jsonl)
        action_log_offset = 0
        tool_calls_path = data / "mcp_tool_calls.jsonl"
        if tool_calls_path.is_file():
            try:
                with open(tool_calls_path, "r", encoding="utf-8") as f:
                    action_log_offset = sum(1 for _ in f)
            except Exception:
                pass

        # 4. Write meta sidecar
        meta = {
            "timestamp": ts,
            "scan_trigger": trigger,
            "file_count": file_count,
            "action_log_offset": action_log_offset,
        }
        with open(meta_path, "w", encoding="utf-8") as f:
            json.dump(meta, f, indent=2)

        # 5. Rotate — keep only the last MAX_SNAPSHOTS pairs
        _rotate_snapshots(snap_dir)

    except Exception:
        pass  # never block the scan


def _rotate_snapshots(snap_dir: Path) -> None:
    """Keep only the newest MAX_SNAPSHOTS snapshot pairs."""
    snapshots = sorted(snap_dir.glob("info_graph_*.json"))
    # Exclude .meta.json from the main list
    snapshots = [s for s in snapshots if not s.name.endswith(".meta.json")]

    while len(snapshots) > MAX_SNAPSHOTS:
        oldest = snapshots.pop(0)
        oldest.unlink(missing_ok=True)
        meta = oldest.with_suffix("").with_suffix(".meta.json")
        # The meta file name is info_graph_<ts>.meta.json
        meta_path = oldest.parent / oldest.name.replace(".json", ".meta.json")
        meta_path.unlink(missing_ok=True)


# CLI entry point for launch scripts
if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(0)  # no data dir — silently skip
    data_dir = sys.argv[1]
    trigger = sys.argv[2] if len(sys.argv) > 2 else "manual"
    info_graph = os.path.join(data_dir, "info_graph.json")
    save_graph_snapshot(info_graph, data_dir, trigger)
