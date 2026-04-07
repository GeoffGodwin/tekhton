"""Tests for cross-run cache features: task history, personalization, pruning, versioning."""

from __future__ import annotations

import json
import os
import sys

import pytest

# Ensure tools/ is on the path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from repo_map import (
    _extract_task_keywords,
    _load_task_history,
    _compute_history_scores,
    _get_git_recency_scores,
    _rank_files,
)
from tag_cache import TagCache, CACHE_VERSION


# =============================================================================
# Task history loading
# =============================================================================


class TestLoadTaskHistory:
    def test_load_from_valid_jsonl(self, tmp_path):
        history_file = tmp_path / "history.jsonl"
        records = [
            {"ts": "2026-03-21T10:00:00Z", "task": "add user auth", "files": ["src/auth.py"], "task_type": "feature"},
            {"ts": "2026-03-21T11:00:00Z", "task": "fix login bug", "files": ["src/auth.py", "src/login.py"], "task_type": "bug"},
        ]
        history_file.write_text("\n".join(json.dumps(r) for r in records) + "\n")

        result = _load_task_history(str(history_file))
        assert len(result) == 2
        assert result[0]["task"] == "add user auth"
        assert result[1]["files"] == ["src/auth.py", "src/login.py"]

    def test_load_missing_file(self, tmp_path):
        result = _load_task_history(str(tmp_path / "nonexistent.jsonl"))
        assert result == []

    def test_skip_malformed_lines(self, tmp_path):
        history_file = tmp_path / "history.jsonl"
        history_file.write_text(
            '{"task":"good","files":["a.py"]}\n'
            'not json at all\n'
            '{"missing_task_key":true}\n'
            '{"task":"also good","files":["b.py"]}\n'
        )
        result = _load_task_history(str(history_file))
        assert len(result) == 2
        assert result[0]["task"] == "good"
        assert result[1]["task"] == "also good"

    def test_empty_file(self, tmp_path):
        history_file = tmp_path / "history.jsonl"
        history_file.write_text("")
        result = _load_task_history(str(history_file))
        assert result == []


# =============================================================================
# History-based personalization scores
# =============================================================================


class TestComputeHistoryScores:
    def test_similar_tasks_boost_files(self):
        history = [
            {"task": "add user authentication", "files": ["src/auth.py", "src/user.py"]},
            {"task": "fix database connection", "files": ["src/db.py"]},
        ]
        keywords = _extract_task_keywords("implement user login")
        scores = _compute_history_scores(keywords, history)

        # "user" overlaps with first record → auth.py and user.py should score
        assert scores.get("src/auth.py", 0) > 0
        assert scores.get("src/user.py", 0) > 0
        # db.py has no keyword overlap → should not appear
        assert scores.get("src/db.py", 0) == 0

    def test_no_overlap_returns_empty(self):
        history = [
            {"task": "setup CI pipeline", "files": ["ci/config.yml"]},
        ]
        keywords = _extract_task_keywords("add user authentication")
        scores = _compute_history_scores(keywords, history)
        assert scores.get("ci/config.yml", 0) == 0

    def test_empty_history_returns_empty(self):
        scores = _compute_history_scores(["user", "auth"], [])
        assert scores == {}

    def test_empty_keywords_returns_empty(self):
        history = [{"task": "anything", "files": ["a.py"]}]
        scores = _compute_history_scores([], history)
        assert scores == {}

    def test_multiple_overlaps_accumulate(self):
        history = [
            {"task": "add user model", "files": ["src/user.py"]},
            {"task": "update user serializer", "files": ["src/user.py", "src/serializer.py"]},
        ]
        keywords = _extract_task_keywords("user validation")
        scores = _compute_history_scores(keywords, history)
        # user.py appears in both matching records → higher score
        assert scores.get("src/user.py", 0) > scores.get("src/serializer.py", 0)


# =============================================================================
# Personalized ranking integration
# =============================================================================


class TestPersonalizedRanking:
    def test_history_influences_ranking(self):
        import networkx as nx

        g = nx.DiGraph()
        g.add_node("src/auth.py")
        g.add_node("src/utils.py")
        g.add_node("src/db.py")

        history = [
            {"task": "add authentication", "files": ["src/auth.py"]},
            {"task": "improve auth flow", "files": ["src/auth.py"]},
        ]

        # Task with "auth" keyword + history pointing to auth.py
        ranked = _rank_files(g, ["auth"], list(g.nodes), history=history)
        file_order = [f for f, _ in ranked]
        assert file_order[0] == "src/auth.py"

    def test_no_history_falls_back_to_keywords(self):
        import networkx as nx

        g = nx.DiGraph()
        g.add_node("src/auth/login.py")
        g.add_node("src/utils/helpers.py")

        ranked = _rank_files(g, ["auth", "login"], list(g.nodes), history=None)
        assert ranked[0][0] == "src/auth/login.py"

    def test_git_recency_contributes(self):
        import networkx as nx

        g = nx.DiGraph()
        g.add_node("old_file.py")
        g.add_node("recent_file.py")

        git_recency = {"recent_file.py": 1.0, "old_file.py": 0.1}

        # No keywords, no history — only git recency differentiates
        ranked = _rank_files(g, [], list(g.nodes), history=None, git_recency=git_recency)
        # With only recency signal, both should appear (uniform PageRank)
        file_names = [f for f, _ in ranked]
        assert "recent_file.py" in file_names
        assert "old_file.py" in file_names


# =============================================================================
# Cache pruning
# =============================================================================


class TestCachePruning:
    def test_prune_removes_deleted_files(self, tmp_path):
        # Create a real file
        (tmp_path / "exists.py").write_text("x = 1")

        cache = TagCache(str(tmp_path / "tags.json"))
        cache.load()
        cache.set_tags("exists.py", 100.0, {"definitions": [], "references": []})
        cache.set_tags("deleted.py", 100.0, {"definitions": [], "references": []})

        assert cache.size == 2
        pruned = cache.prune_cache(str(tmp_path))
        assert pruned == 1
        assert cache.size == 1
        assert cache.get_tags("deleted.py", 100.0) is None
        assert cache.get_tags("exists.py", 100.0) is not None

    def test_prune_no_deletions(self, tmp_path):
        (tmp_path / "a.py").write_text("x = 1")
        (tmp_path / "b.py").write_text("y = 2")

        cache = TagCache(str(tmp_path / "tags.json"))
        cache.load()
        cache.set_tags("a.py", 100.0, {"definitions": [], "references": []})
        cache.set_tags("b.py", 100.0, {"definitions": [], "references": []})

        pruned = cache.prune_cache(str(tmp_path))
        assert pruned == 0
        assert cache.size == 2


# =============================================================================
# Cache versioning
# =============================================================================


class TestCacheVersioning:
    def test_version_mismatch_clears_cache(self, tmp_path):
        path = tmp_path / "tags.json"
        # Write a cache with old version
        old_data = {
            "_cache_version": 1,
            "foo.py": {"mtime": 100.0, "tags": {"definitions": [], "references": []}},
        }
        path.write_text(json.dumps(old_data))

        cache = TagCache(str(path))
        cache.load()
        # Old version data should be cleared
        assert cache.size == 0

    def test_current_version_preserved(self, tmp_path):
        path = tmp_path / "tags.json"
        # Write a cache with current version
        data = {
            "_cache_version": CACHE_VERSION,
            "foo.py": {"mtime": 100.0, "tags": {"definitions": [{"name": "foo"}], "references": []}},
        }
        path.write_text(json.dumps(data))

        cache = TagCache(str(path))
        cache.load()
        assert cache.size == 1
        result = cache.get_tags("foo.py", 100.0)
        assert result is not None

    def test_no_version_field_clears_cache(self, tmp_path):
        path = tmp_path / "tags.json"
        # Write cache without version field (old format)
        old_data = {
            "foo.py": {"mtime": 100.0, "tags": {"definitions": [], "references": []}},
        }
        path.write_text(json.dumps(old_data))

        cache = TagCache(str(path))
        cache.load()
        assert cache.size == 0

    def test_save_includes_version(self, tmp_path):
        path = str(tmp_path / "tags.json")
        cache = TagCache(path)
        cache.load()
        cache.set_tags("bar.py", 50.0, {"definitions": [], "references": []})
        cache.save()

        with open(path, "r") as f:
            raw = json.load(f)
        assert raw["_cache_version"] == CACHE_VERSION


# =============================================================================
# Cache statistics
# =============================================================================


class TestCacheStatistics:
    def test_hit_miss_tracking(self, tmp_path):
        cache = TagCache(str(tmp_path / "tags.json"))
        cache.load()

        cache.set_tags("a.py", 100.0, {"definitions": [], "references": []})

        # Hit
        cache.get_tags("a.py", 100.0)
        assert cache.hits == 1
        assert cache.misses == 0

        # Miss (wrong mtime)
        cache.get_tags("a.py", 200.0)
        assert cache.hits == 1
        assert cache.misses == 1

        # Miss (missing file)
        cache.get_tags("nonexistent.py", 100.0)
        assert cache.hits == 1
        assert cache.misses == 2

    def test_hit_rate(self, tmp_path):
        cache = TagCache(str(tmp_path / "tags.json"))
        cache.load()

        assert cache.hit_rate() == 0.0  # no lookups

        cache.set_tags("a.py", 100.0, {"definitions": [], "references": []})
        cache.get_tags("a.py", 100.0)  # hit
        cache.get_tags("b.py", 100.0)  # miss

        assert cache.hit_rate() == 0.5

    def test_stats_dict(self, tmp_path):
        cache = TagCache(str(tmp_path / "tags.json"))
        cache.load()
        cache.set_tags("a.py", 100.0, {"definitions": [], "references": []})
        cache.get_tags("a.py", 100.0)

        stats = cache.stats_dict()
        assert stats["hits"] == 1
        assert stats["misses"] == 0
        assert stats["cache_size"] == 1
        assert stats["hit_rate"] == 1.0

    def test_parse_time_saved_tracking(self, tmp_path):
        cache = TagCache(str(tmp_path / "tags.json"))
        cache.load()
        cache.set_tags("a.py", 100.0, {"definitions": [], "references": []}, parse_ms=15.0)

        cache.get_tags("a.py", 100.0)
        assert cache.parse_time_saved_ms == 15.0


# =============================================================================
# JSONL append safety
# =============================================================================


class TestJSONLSafety:
    def test_append_multiple_records(self, tmp_path):
        history_file = tmp_path / "history.jsonl"
        records = [
            {"ts": "2026-03-21T10:00:00Z", "task": "task 1", "files": ["a.py"], "task_type": "feature"},
            {"ts": "2026-03-21T11:00:00Z", "task": "task 2", "files": ["b.py"], "task_type": "bug"},
        ]
        # Simulate append-only writes
        for r in records:
            with open(str(history_file), "a") as f:
                f.write(json.dumps(r) + "\n")

        result = _load_task_history(str(history_file))
        assert len(result) == 2

    def test_partial_write_resilience(self, tmp_path):
        history_file = tmp_path / "history.jsonl"
        # Simulate a partial write (truncated JSON line)
        history_file.write_text(
            '{"task":"good","files":["a.py"]}\n'
            '{"task":"trunca\n'
        )
        result = _load_task_history(str(history_file))
        assert len(result) == 1
        assert result[0]["task"] == "good"
