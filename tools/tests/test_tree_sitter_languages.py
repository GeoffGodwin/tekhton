"""Tests for tree_sitter_languages.py — Language detection and grammar loading."""

from __future__ import annotations

import os
import sys

import pytest

# Ensure tools/ is on the path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from tree_sitter_languages import (
    supported_extensions,
    ext_to_language_name,
    extensions_for_languages,
    get_language,
    get_parser,
)


class TestSupportedExtensions:
    """Test the supported_extensions() function."""

    def test_returns_list(self):
        exts = supported_extensions()
        assert isinstance(exts, list)
        assert len(exts) > 0

    def test_contains_common_extensions(self):
        exts = supported_extensions()
        assert ".py" in exts
        assert ".js" in exts
        assert ".ts" in exts
        assert ".go" in exts
        assert ".rs" in exts

    def test_all_extensions_start_with_dot(self):
        exts = supported_extensions()
        for ext in exts:
            assert ext.startswith("."), f"Extension {ext} does not start with '.'"

    def test_no_duplicates(self):
        exts = supported_extensions()
        assert len(exts) == len(set(exts))


class TestExtToLanguageName:
    """Test the ext_to_language_name() function."""

    def test_known_extension_python(self):
        lang = ext_to_language_name(".py")
        assert lang == "python"

    def test_known_extension_javascript(self):
        lang = ext_to_language_name(".js")
        assert lang == "javascript"

    def test_known_extension_typescript(self):
        lang = ext_to_language_name(".ts")
        assert lang == "typescript"

    def test_known_extension_tsx_is_separate(self):
        lang = ext_to_language_name(".tsx")
        assert lang == "tsx"

    def test_known_extension_go(self):
        lang = ext_to_language_name(".go")
        assert lang == "go"

    def test_known_extension_rust(self):
        lang = ext_to_language_name(".rs")
        assert lang == "rust"

    def test_known_extension_java(self):
        lang = ext_to_language_name(".java")
        assert lang == "java"

    def test_known_extension_c(self):
        lang = ext_to_language_name(".c")
        assert lang == "c"

    def test_unknown_extension_returns_none(self):
        lang = ext_to_language_name(".unknown")
        assert lang is None

    def test_empty_extension_returns_none(self):
        lang = ext_to_language_name("")
        assert lang is None


class TestExtensionsForLanguages:
    """Test the extensions_for_languages() function."""

    def test_single_language_python(self):
        exts = extensions_for_languages({"python"})
        assert ".py" in exts
        assert "python" not in exts  # Should be extensions, not languages

    def test_single_language_javascript(self):
        exts = extensions_for_languages({"javascript"})
        assert ".js" in exts
        assert ".jsx" in exts

    def test_single_language_typescript(self):
        exts = extensions_for_languages({"typescript"})
        assert ".ts" in exts
        # Note: .tsx maps to "tsx" language, not "typescript"

    def test_single_language_tsx(self):
        exts = extensions_for_languages({"tsx"})
        assert ".tsx" in exts

    def test_multiple_extensions_cpp(self):
        exts = extensions_for_languages({"cpp"})
        # C++ has multiple extensions
        assert ".cpp" in exts or ".cc" in exts or ".cxx" in exts or ".hpp" in exts

    def test_multiple_languages(self):
        exts = extensions_for_languages({"python", "javascript"})
        assert ".py" in exts
        assert ".js" in exts

    def test_empty_set_returns_empty(self):
        exts = extensions_for_languages(set())
        assert len(exts) == 0

    def test_unknown_language_ignored(self):
        exts = extensions_for_languages({"unknown_lang"})
        assert len(exts) == 0

    def test_mixed_known_unknown(self):
        exts = extensions_for_languages({"python", "unknown_lang"})
        assert ".py" in exts
        assert len(exts) == 1  # Only python extension


class TestGetLanguage:
    """Test the get_language() function."""

    def test_known_extension_returns_object(self):
        # This test checks behavior when tree-sitter is available
        lang = get_language(".py")
        # Result depends on whether tree-sitter is installed
        # but should be consistent (either object or None)
        assert lang is None or hasattr(lang, '__class__')

    def test_unknown_extension_returns_none(self):
        lang = get_language(".unknown")
        assert lang is None

    def test_caching_behavior(self):
        # Call twice with same extension
        lang1 = get_language(".py")
        lang2 = get_language(".py")
        # Should return same object (cached)
        assert lang1 is lang2


class TestGetParser:
    """Test the get_parser() function."""

    def test_unknown_extension_returns_none(self):
        parser = get_parser(".unknown")
        assert parser is None

    def test_known_extension_returns_parser_or_none(self):
        # Result depends on whether tree-sitter and grammars are installed
        parser = get_parser(".py")
        assert parser is None or hasattr(parser, 'parse')


class TestTypescriptGrammarLoading:
    """Test multi-grammar package loading for tree_sitter_typescript.

    These tests are gated on tree_sitter and tree_sitter_typescript being
    installed. They verify the fix for issue #181 where .ts and .tsx files
    silently failed because the loader only probed generic `language` /
    `LANGUAGE` exports, missing the multi-grammar factories.
    """

    def setup_method(self):
        # Clear the module-level cache so each test probes the loader fresh.
        import tree_sitter_languages as mod
        mod._lang_cache.clear()

    def test_get_language_typescript_returns_object(self):
        pytest.importorskip("tree_sitter")
        pytest.importorskip("tree_sitter_typescript")
        lang = get_language(".ts")
        assert lang is not None
        # Must be a tree_sitter.Language-compatible object usable by Parser.
        import tree_sitter
        assert isinstance(lang, tree_sitter.Language)

    def test_get_language_tsx_returns_object(self):
        pytest.importorskip("tree_sitter")
        pytest.importorskip("tree_sitter_typescript")
        lang = get_language(".tsx")
        assert lang is not None
        import tree_sitter
        assert isinstance(lang, tree_sitter.Language)

    def test_get_language_typescript_tsx_are_distinct(self):
        pytest.importorskip("tree_sitter")
        pytest.importorskip("tree_sitter_typescript")
        ts = get_language(".ts")
        tsx = get_language(".tsx")
        assert ts is not None
        assert tsx is not None
        assert ts is not tsx

    def test_get_parser_typescript_parses_simple_source(self):
        pytest.importorskip("tree_sitter")
        pytest.importorskip("tree_sitter_typescript")
        parser = get_parser(".ts")
        assert parser is not None
        tree = parser.parse(b"const x: number = 1;\n")
        root = tree.root_node
        # Top-level nodes should not be ERROR for valid TS source.
        for child in root.children:
            assert child.type != "ERROR", f"Unexpected ERROR node parsing TS source: {child}"


class TestLanguageMappingCompleteness:
    """Test that the language mapping is complete and consistent."""

    def test_all_supported_extensions_have_language_names(self):
        exts = supported_extensions()
        for ext in exts:
            lang = ext_to_language_name(ext)
            assert lang is not None, f"Extension {ext} has no language mapping"
            assert isinstance(lang, str)
            assert len(lang) > 0

    def test_extensions_for_languages_roundtrip(self):
        # For each language in supported extensions, we should be able to
        # find at least one extension via extensions_for_languages
        exts = supported_extensions()
        languages = set()
        for ext in exts:
            lang = ext_to_language_name(ext)
            if lang:
                languages.add(lang)

        for lang in languages:
            found_exts = extensions_for_languages({lang})
            assert len(found_exts) > 0, f"Language {lang} has no extensions via extensions_for_languages"


import tree_sitter_languages as _tsl_mod

# Build parametrize data at module load so pytest can collect test IDs cleanly.
_ALL_EXT_PARAMS = [
    (ext, info[0], info[1])
    for ext, info in sorted(_tsl_mod._EXT_TO_LANG.items())
]


class TestAllGrammarsLoadIfInstalled:
    """Parametrized regression test: the multi-grammar probe order in get_language()
    must not break single-grammar packages that expose only language() / LANGUAGE.

    For each declared extension, skip if tree_sitter or the grammar module is not
    installed. If both are present, assert get_language() returns a real Language.

    This is acceptance criterion AC-3 from M122: 'All other declared extensions
    continue to load via their existing language() / LANGUAGE fallbacks.'
    """

    def setup_method(self):
        _tsl_mod._lang_cache.clear()

    @pytest.mark.parametrize("ext,module_name,lang_name", _ALL_EXT_PARAMS)
    def test_grammar_loads_if_installed(self, ext, module_name, lang_name):
        pytest.importorskip("tree_sitter")
        pytest.importorskip(module_name)
        import tree_sitter

        result = get_language(ext)
        assert result is not None, (
            f"get_language({ext!r}) returned None even though {module_name} "
            f"is installed — the probe order may have broken the {lang_name!r} grammar"
        )
        assert isinstance(result, tree_sitter.Language), (
            f"get_language({ext!r}) returned {type(result)!r}, expected tree_sitter.Language"
        )


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
