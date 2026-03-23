"""Integration tests for _extract_tags() in repo_map.py.

These tests exercise the full tree-sitter parse path with real source files.
The entire module is skipped if tree_sitter or tree_sitter_python is unavailable,
so CI environments without the grammar packages still pass.
"""

from __future__ import annotations

import os
import sys

import pytest

# Skip entire module if tree_sitter is not installed
pytest.importorskip("tree_sitter")
# Skip if the Python grammar package is not installed (needed for .py test files)
pytest.importorskip("tree_sitter_python")

# Ensure tools/ is on the path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from tag_cache import TagCache
from repo_map import _extract_tags


class TestExtractTagsIntegration:
    def test_extracts_function_definitions_from_python_file(self, tmp_path):
        py_file = tmp_path / "sample.py"
        py_file.write_text(
            "def my_function(x, y):\n"
            "    return x + y\n"
            "\n"
            "def another_func():\n"
            "    pass\n"
        )
        cache = TagCache(str(tmp_path / "tags.json"))

        result = _extract_tags("sample.py", str(tmp_path), cache)

        assert result is not None
        assert "definitions" in result
        names = [d["name"] for d in result["definitions"]]
        assert "my_function" in names
        assert "another_func" in names

    def test_extracts_class_definitions_from_python_file(self, tmp_path):
        py_file = tmp_path / "models.py"
        py_file.write_text(
            "class User:\n"
            "    def __init__(self, name):\n"
            "        self.name = name\n"
            "\n"
            "    def validate(self) -> bool:\n"
            "        return bool(self.name)\n"
        )
        cache = TagCache(str(tmp_path / "tags.json"))

        result = _extract_tags("models.py", str(tmp_path), cache)

        assert result is not None
        assert "definitions" in result
        names = [d["name"] for d in result["definitions"]]
        assert "User" in names
        # Methods should also be extracted
        assert "__init__" in names or "validate" in names

    def test_returns_none_for_missing_file(self, tmp_path):
        cache = TagCache(str(tmp_path / "tags.json"))

        result = _extract_tags("nonexistent.py", str(tmp_path), cache)

        assert result is None

    def test_returns_none_for_unsupported_extension(self, tmp_path):
        txt_file = tmp_path / "readme.txt"
        txt_file.write_text("just some text\n")
        cache = TagCache(str(tmp_path / "tags.json"))

        result = _extract_tags("readme.txt", str(tmp_path), cache)

        assert result is None

    def test_cache_hit_returns_same_definitions(self, tmp_path):
        py_file = tmp_path / "cached.py"
        py_file.write_text("def cached_fn(x):\n    return x\n")
        cache = TagCache(str(tmp_path / "tags.json"))

        # First call: parses and caches
        result1 = _extract_tags("cached.py", str(tmp_path), cache)
        assert result1 is not None

        # Second call: should return cached result with same definitions
        result2 = _extract_tags("cached.py", str(tmp_path), cache)
        assert result2 is not None
        assert result2["definitions"] == result1["definitions"]

    def test_result_contains_references_key(self, tmp_path):
        py_file = tmp_path / "caller.py"
        py_file.write_text(
            "import os\n"
            "\n"
            "def main():\n"
            "    os.path.join('a', 'b')\n"
        )
        cache = TagCache(str(tmp_path / "tags.json"))

        result = _extract_tags("caller.py", str(tmp_path), cache)

        assert result is not None
        assert "references" in result
        assert isinstance(result["references"], list)

    def test_empty_python_file_returns_empty_definitions(self, tmp_path):
        py_file = tmp_path / "empty.py"
        py_file.write_text("")
        cache = TagCache(str(tmp_path / "tags.json"))

        result = _extract_tags("empty.py", str(tmp_path), cache)

        # Should return a valid (possibly empty) result, not None
        assert result is not None
        assert result["definitions"] == []
