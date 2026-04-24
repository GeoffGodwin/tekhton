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


class TestExtractTagsTypescript:
    """Integration tests for .ts / .tsx extraction via the multi-grammar loader.

    Skipped entirely when tree_sitter_typescript isn't installed — these
    tests exercise the fix for issue #181 and require the real grammar.
    """

    def _fixture_root(self):
        return os.path.abspath(
            os.path.join(os.path.dirname(__file__), "..", "..", "tests",
                         "fixtures", "indexer_project")
        )

    def test_extract_tags_typescript_file(self, tmp_path):
        pytest.importorskip("tree_sitter_typescript")
        # Clear cache so we actually exercise the loader, not cached tags.
        import tree_sitter_languages as ts_lang
        ts_lang._lang_cache.clear()

        root = self._fixture_root()
        cache = TagCache(str(tmp_path / "tags.json"))

        result = _extract_tags("web/client.ts", root, cache)

        assert result is not None, "Expected _extract_tags to return tags for a TS file"
        assert "definitions" in result
        names = [d["name"] for d in result["definitions"]]
        assert "fetchUser" in names, f"fetchUser not in {names}"

    def test_extract_tags_tsx_file(self, tmp_path):
        pytest.importorskip("tree_sitter_typescript")
        import tree_sitter_languages as ts_lang
        ts_lang._lang_cache.clear()

        root = self._fixture_root()
        cache = TagCache(str(tmp_path / "tags.json"))

        result = _extract_tags("web/component.tsx", root, cache)

        assert result is not None, "Expected _extract_tags to return tags for a TSX file"
        assert "definitions" in result
        names = [d["name"] for d in result["definitions"]]
        assert "Greeting" in names, f"Greeting not in {names}"


# M123: parametrized fixture coverage across commonly-installed grammars.
# Each entry is (relative fixture path, grammar module). The test asserts
# that _extract_tags returns non-None when the grammar is installed — this
# proves the loader probe works across all commonly-supported grammars.
# Definition extraction is walker-dependent and covered elsewhere; this
# test is specifically about the grammar load + parse path.
_M123_FIXTURES = [
    ("services/server.go", "tree_sitter_go"),
    ("services/handler.rs", "tree_sitter_rust"),
    ("services/Worker.java", "tree_sitter_java"),
    ("native/engine.cpp", "tree_sitter_cpp"),
    ("scripts/helper.rb", "tree_sitter_ruby"),
]


def _m123_fixture_root():
    return os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..", "..", "tests",
                     "fixtures", "indexer_project")
    )


@pytest.mark.parametrize("rel_path,grammar_module", _M123_FIXTURES)
def test_m123_fixture_parses_if_grammar_installed(
    rel_path, grammar_module, tmp_path
):
    """If the grammar is installed, _extract_tags must succeed for the fixture.

    Skipped when the grammar module is not installed — the M123 audit alone
    is enough regression protection for platforms where a grammar is absent.
    """
    pytest.importorskip(grammar_module)
    import tree_sitter_languages as ts_lang
    ts_lang._lang_cache.clear()

    root = _m123_fixture_root()
    cache = TagCache(str(tmp_path / "tags.json"))

    result = _extract_tags(rel_path, root, cache)
    assert result is not None, (
        f"_extract_tags({rel_path!r}) returned None even though {grammar_module} "
        f"is installed — the loader probe may be broken for this grammar"
    )
    assert "definitions" in result and "references" in result
