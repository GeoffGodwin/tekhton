"""Tests for repo_map.py — repo map generation and ranking."""

from __future__ import annotations

import os
import sys

import pytest

# Ensure tools/ is on the path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from repo_map import (
    _extract_task_keywords,
    _build_graph,
    _rank_files,
    _build_output,
    _format_file_entry,
)


class TestTaskKeywords:
    def test_extracts_meaningful_words(self):
        kw = _extract_task_keywords("add user authentication to the API")
        assert "user" in kw
        assert "authentication" in kw
        assert "api" in kw
        # Stop words removed
        assert "the" not in kw
        assert "to" not in kw
        assert "add" not in kw

    def test_empty_task(self):
        assert _extract_task_keywords("") == []

    def test_single_char_words_filtered(self):
        kw = _extract_task_keywords("a b c database")
        assert "database" in kw
        assert "a" not in kw


class TestGraphBuilding:
    def test_builds_edges_from_references(self):
        tags = {
            "a.py": {
                "definitions": [{"name": "foo", "type": "function"}],
                "references": [{"name": "bar", "type": "call"}],
            },
            "b.py": {
                "definitions": [{"name": "bar", "type": "function"}],
                "references": [],
            },
        }
        g = _build_graph(tags)
        assert g.has_edge("a.py", "b.py")
        assert not g.has_edge("b.py", "a.py")

    def test_no_self_edges(self):
        tags = {
            "a.py": {
                "definitions": [{"name": "foo", "type": "function"}],
                "references": [{"name": "foo", "type": "call"}],
            },
        }
        g = _build_graph(tags)
        assert not g.has_edge("a.py", "a.py")

    def test_empty_tags(self):
        g = _build_graph({})
        assert len(g.nodes) == 0

    def test_edge_weight_accumulates(self):
        tags = {
            "a.py": {
                "definitions": [],
                "references": [
                    {"name": "bar", "type": "call"},
                    {"name": "bar", "type": "call"},
                    {"name": "bar", "type": "call"},
                ],
            },
            "b.py": {
                "definitions": [{"name": "bar", "type": "function"}],
                "references": [],
            },
        }
        g = _build_graph(tags)
        assert g.has_edge("a.py", "b.py")
        assert g["a.py"]["b.py"]["weight"] == 3


class TestRanking:
    def test_keyword_files_rank_higher(self):
        import networkx as nx

        g = nx.DiGraph()
        g.add_node("src/auth/login.py")
        g.add_node("src/utils/helpers.py")
        g.add_node("src/db/connection.py")

        ranked = _rank_files(g, ["auth", "login"], list(g.nodes))
        # auth/login.py should be first
        assert ranked[0][0] == "src/auth/login.py"

    def test_empty_keywords_uniform(self):
        import networkx as nx

        g = nx.DiGraph()
        g.add_node("a.py")
        g.add_node("b.py")

        ranked = _rank_files(g, [], list(g.nodes))
        # All should have equal scores
        scores = [s for _, s in ranked]
        assert abs(scores[0] - scores[1]) < 0.01

    def test_files_not_in_graph_included(self):
        import networkx as nx

        g = nx.DiGraph()
        g.add_node("a.py")

        ranked = _rank_files(g, [], ["a.py", "b.py"])
        names = [n for n, _ in ranked]
        assert "b.py" in names


class TestOutputFormatting:
    def test_format_file_entry(self):
        tags = {
            "definitions": [
                {"name": "User", "type": "class", "signature": "class User"},
                {"name": "__init__", "type": "function", "signature": "def __init__(self, name)"},
            ],
            "references": [],
        }
        result = _format_file_entry("src/user.py", tags)
        assert "## src/user.py" in result
        assert "class User" in result
        assert "def __init__" in result

    def test_empty_definitions_returns_empty(self):
        tags = {"definitions": [], "references": []}
        result = _format_file_entry("empty.py", tags)
        assert result == ""

    def test_budget_enforcement(self):
        tags_a = {
            "definitions": [
                {"name": f"func_{i}", "type": "function", "signature": f"def func_{i}()"}
                for i in range(50)
            ],
            "references": [],
        }
        tags_b = {
            "definitions": [
                {"name": f"other_{i}", "type": "function", "signature": f"def other_{i}()"}
                for i in range(50)
            ],
            "references": [],
        }
        all_tags = {"a.py": tags_a, "b.py": tags_b}
        ranked = [("a.py", 1.0), ("b.py", 0.5)]

        # Very small budget: should include at least first file
        output = _build_output(ranked, all_tags, token_budget=10)
        assert "## a.py" in output

    def test_always_includes_first_file(self):
        tags = {
            "definitions": [
                {"name": "big_function", "type": "function", "signature": "def big_function(a, b, c, d, e)"}
            ],
            "references": [],
        }
        output = _build_output([("big.py", 1.0)], {"big.py": tags}, token_budget=1)
        assert "## big.py" in output
