"""Language detection and tree-sitter grammar loading.

Maps file extensions to tree-sitter grammars and provides configured parsers.
Gracefully handles missing grammars — returns None for unsupported languages.
"""

from __future__ import annotations

import importlib
from typing import Optional

try:
    import tree_sitter
except ImportError:
    tree_sitter = None  # type: ignore[assignment]

# Extension → (tree-sitter language module name, language function name)
# Uses the individual grammar package convention: tree_sitter_python.language()
_EXT_TO_LANG: dict[str, tuple[str, str]] = {
    ".py": ("tree_sitter_python", "python"),
    ".js": ("tree_sitter_javascript", "javascript"),
    ".jsx": ("tree_sitter_javascript", "javascript"),
    ".ts": ("tree_sitter_typescript", "typescript"),
    ".tsx": ("tree_sitter_typescript", "tsx"),
    ".go": ("tree_sitter_go", "go"),
    ".rs": ("tree_sitter_rust", "rust"),
    ".java": ("tree_sitter_java", "java"),
    ".c": ("tree_sitter_c", "c"),
    ".h": ("tree_sitter_c", "c"),
    ".cpp": ("tree_sitter_cpp", "cpp"),
    ".cc": ("tree_sitter_cpp", "cpp"),
    ".cxx": ("tree_sitter_cpp", "cpp"),
    ".hpp": ("tree_sitter_cpp", "cpp"),
    ".rb": ("tree_sitter_ruby", "ruby"),
    ".sh": ("tree_sitter_bash", "bash"),
    ".bash": ("tree_sitter_bash", "bash"),
    ".dart": ("tree_sitter_dart", "dart"),
    ".swift": ("tree_sitter_swift", "swift"),
    ".kt": ("tree_sitter_kotlin", "kotlin"),
    ".kts": ("tree_sitter_kotlin", "kotlin"),
    ".cs": ("tree_sitter_c_sharp", "c_sharp"),
}

# Cache loaded languages to avoid re-importing
_lang_cache: dict[str, object] = {}


def get_language(ext: str) -> Optional[object]:
    """Return the tree-sitter Language object for a file extension, or None."""
    if tree_sitter is None:
        return None

    info = _EXT_TO_LANG.get(ext)
    if info is None:
        return None

    module_name, lang_name = info
    cache_key = f"{module_name}.{lang_name}"

    if cache_key in _lang_cache:
        return _lang_cache[cache_key]

    try:
        mod = importlib.import_module(module_name)
        # Modern tree-sitter grammar packages expose a language() function
        lang_fn = getattr(mod, "language", None)
        if lang_fn is None:
            # Some packages use LANGUAGE constant
            lang_fn = getattr(mod, "LANGUAGE", None)
        if lang_fn is None:
            return None
        lang = lang_fn() if callable(lang_fn) else lang_fn
        # tree-sitter >= 0.22: grammar packages return a PyCapsule that
        # must be wrapped in tree_sitter.Language() for the Parser API
        if not isinstance(lang, tree_sitter.Language):
            lang = tree_sitter.Language(lang)
        _lang_cache[cache_key] = lang
        return lang
    except (ImportError, OSError, AttributeError):
        _lang_cache[cache_key] = None  # type: ignore[assignment]
        return None


def get_parser(ext: str) -> Optional["tree_sitter.Parser"]:
    """Return a configured tree-sitter Parser for a file extension, or None."""
    if tree_sitter is None:
        return None

    lang = get_language(ext)
    if lang is None:
        return None

    try:
        parser = tree_sitter.Parser(lang)
        return parser
    except Exception:
        return None


def supported_extensions() -> list[str]:
    """Return all file extensions that have grammar mappings."""
    return list(_EXT_TO_LANG.keys())


def ext_to_language_name(ext: str) -> Optional[str]:
    """Return the language name for an extension, or None."""
    info = _EXT_TO_LANG.get(ext)
    return info[1] if info else None


def extensions_for_languages(requested: set[str]) -> set[str]:
    """Return the set of file extensions for the requested language names."""
    return {ext for ext, (_, lang) in _EXT_TO_LANG.items() if lang in requested}
