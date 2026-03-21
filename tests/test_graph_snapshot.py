"""Tests for bin/graph_snapshot.py — snapshot + meta sidecar logic."""

import json
import os
import sys
import time
from pathlib import Path

import pytest

# Add bin/ to path so we can import graph_snapshot
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bin"))
from graph_snapshot import save_graph_snapshot, MAX_SNAPSHOTS


@pytest.fixture
def data_dir(tmp_path):
    """Create a temporary data directory with a sample info_graph.json."""
    graph = {
        "nodes": [
            {"id": "src/main.py"},
            {"id": "src/utils.py"},
            {"id": "src/config.py"},
        ],
        "edges": [
            {"from": "src/main.py", "to": "src/utils.py"},
        ],
    }
    info_graph = tmp_path / "info_graph.json"
    info_graph.write_text(json.dumps(graph), encoding="utf-8")
    return tmp_path


class TestSnapshotCreation:
    def test_snapshot_created_before_overwrite(self, data_dir):
        """Snapshot is created from the current info_graph.json content."""
        original_content = (data_dir / "info_graph.json").read_text(encoding="utf-8")

        save_graph_snapshot(data_dir / "info_graph.json", data_dir, trigger="manual")

        snap_dir = data_dir / "graph_snapshots"
        snapshots = list(snap_dir.glob("info_graph_*.json"))
        snapshots = [s for s in snapshots if not s.name.endswith(".meta.json")]
        assert len(snapshots) == 1

        snapshot_content = snapshots[0].read_text(encoding="utf-8")
        assert snapshot_content == original_content

    def test_no_snapshot_when_info_graph_missing(self, tmp_path):
        """No snapshot or error when info_graph.json doesn't exist."""
        save_graph_snapshot(tmp_path / "info_graph.json", tmp_path, trigger="auto")
        snap_dir = tmp_path / "graph_snapshots"
        assert not snap_dir.exists() or len(list(snap_dir.iterdir())) == 0


class TestMetaSidecar:
    def test_meta_created_with_correct_fields(self, data_dir):
        """Meta sidecar is created alongside snapshot with all required fields."""
        # Create a tool calls log with known line count
        tool_calls = data_dir / "mcp_tool_calls.jsonl"
        tool_calls.write_text(
            '{"tool":"graph_read"}\n{"tool":"graph_retrieve"}\n{"tool":"graph_scan"}\n',
            encoding="utf-8",
        )

        save_graph_snapshot(data_dir / "info_graph.json", data_dir, trigger="manual")

        snap_dir = data_dir / "graph_snapshots"
        metas = list(snap_dir.glob("*.meta.json"))
        assert len(metas) == 1

        meta = json.loads(metas[0].read_text(encoding="utf-8"))
        assert meta["scan_trigger"] == "manual"
        assert meta["file_count"] == 3  # 3 nodes in fixture
        assert meta["action_log_offset"] == 3  # 3 lines in jsonl
        assert "timestamp" in meta

    def test_action_log_offset_zero_when_no_jsonl(self, data_dir):
        """action_log_offset is 0 when mcp_tool_calls.jsonl does not exist."""
        save_graph_snapshot(data_dir / "info_graph.json", data_dir, trigger="auto")

        snap_dir = data_dir / "graph_snapshots"
        metas = list(snap_dir.glob("*.meta.json"))
        assert len(metas) == 1

        meta = json.loads(metas[0].read_text(encoding="utf-8"))
        assert meta["action_log_offset"] == 0

    def test_trigger_auto_recorded(self, data_dir):
        """scan_trigger correctly records 'auto'."""
        save_graph_snapshot(data_dir / "info_graph.json", data_dir, trigger="auto")

        snap_dir = data_dir / "graph_snapshots"
        metas = list(snap_dir.glob("*.meta.json"))
        meta = json.loads(metas[0].read_text(encoding="utf-8"))
        assert meta["scan_trigger"] == "auto"


class TestRotation:
    def test_only_five_pairs_retained(self, data_dir):
        """After 6 scans, only 5 snapshot pairs remain."""
        for i in range(6):
            save_graph_snapshot(
                data_dir / "info_graph.json", data_dir, trigger="manual"
            )
            # Ensure unique timestamps by waiting briefly
            time.sleep(1.1)

        snap_dir = data_dir / "graph_snapshots"
        snapshots = [
            s for s in snap_dir.glob("info_graph_*.json")
            if not s.name.endswith(".meta.json")
        ]
        metas = list(snap_dir.glob("*.meta.json"))

        assert len(snapshots) == MAX_SNAPSHOTS
        assert len(metas) == MAX_SNAPSHOTS


class TestFailSafe:
    def test_write_error_does_not_propagate(self, data_dir):
        """A write error in save_graph_snapshot does not raise — scan continues."""
        # Pass a read-only directory to force a write failure
        readonly_dir = data_dir / "readonly"
        readonly_dir.mkdir()
        fake_graph = readonly_dir / "info_graph.json"
        fake_graph.write_text("{}", encoding="utf-8")

        # Make graph_snapshots path a file so mkdir fails
        blocker = readonly_dir / "graph_snapshots"
        blocker.write_text("block", encoding="utf-8")

        # This should NOT raise
        save_graph_snapshot(fake_graph, readonly_dir, trigger="manual")

    def test_corrupt_graph_json_does_not_propagate(self, tmp_path):
        """Corrupt info_graph.json doesn't crash the snapshot."""
        info_graph = tmp_path / "info_graph.json"
        info_graph.write_text("NOT VALID JSON {{{{", encoding="utf-8")

        # Should not raise — file_count defaults to 0
        save_graph_snapshot(info_graph, tmp_path, trigger="auto")

        snap_dir = tmp_path / "graph_snapshots"
        snapshots = [
            s for s in snap_dir.glob("info_graph_*.json")
            if not s.name.endswith(".meta.json")
        ]
        assert len(snapshots) == 1  # snapshot still created (it's a copy)
