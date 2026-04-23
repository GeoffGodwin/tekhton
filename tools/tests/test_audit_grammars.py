"""Tests for audit_grammars() — the M123 startup diagnostic helper.

Exercises the three failure modes the loader must distinguish cleanly:
module missing, module imported but API mismatch, and success. The final
test is the regression gate against future grammar API drift (issue #181).
"""

from __future__ import annotations

import os
import sys
import types

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import tree_sitter_languages as _tsl_mod  # noqa: E402
from tree_sitter_languages import audit_grammars  # noqa: E402


class TestAuditGrammars:
    def test_returns_entry_per_extension(self):
        result = audit_grammars()
        assert isinstance(result, dict)
        assert set(result.keys()) == set(_tsl_mod._EXT_TO_LANG.keys())
        for _ext, entry in result.items():
            assert "module" in entry
            assert "lang_name" in entry
            assert "module_importable" in entry
            assert "language_loaded" in entry
            assert "error" in entry
            assert isinstance(entry["module_importable"], bool)
            assert isinstance(entry["language_loaded"], bool)

    def test_marks_missing_module_cleanly(self, monkeypatch):
        fake_ext = ".__m123_missing__"
        fake_map = {fake_ext: ("tree_sitter_definitely_not_installed_m123", "ghost")}
        monkeypatch.setattr(_tsl_mod, "_EXT_TO_LANG", fake_map)
        result = audit_grammars()
        assert fake_ext in result
        entry = result[fake_ext]
        assert entry["module_importable"] is False
        assert entry["language_loaded"] is False
        assert entry["error"] is not None
        err = str(entry["error"])
        assert "ImportError" in err or "ModuleNotFoundError" in err

    def test_marks_bad_api_cleanly(self, monkeypatch):
        fake_module_name = "tree_sitter_m123_fake_no_api"
        fake_ext = ".__m123_badapi__"

        fake_mod = types.ModuleType(fake_module_name)
        monkeypatch.setitem(sys.modules, fake_module_name, fake_mod)
        monkeypatch.setattr(
            _tsl_mod, "_EXT_TO_LANG",
            {fake_ext: (fake_module_name, "fake")},
        )

        result = audit_grammars()
        entry = result[fake_ext]
        assert entry["module_importable"] is True
        assert entry["language_loaded"] is False
        assert entry["error"] is not None
        err = str(entry["error"])
        assert "AttributeError" in err or "no language" in err.lower()

    def test_all_installed_grammars_load(self):
        """Regression gate: if a grammar module imports, its language must load."""
        result = audit_grammars()
        for ext, entry in result.items():
            if not entry["module_importable"]:
                continue
            assert entry["language_loaded"], (
                f"{ext} ({entry['module']}) imported but language did not load: "
                f"{entry.get('error')}"
            )


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
