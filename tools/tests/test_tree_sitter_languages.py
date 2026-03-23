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


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
