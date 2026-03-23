"""Tests for tag_cache.py — disk-based tag cache with mtime tracking."""

from __future__ import annotations

import json
import os

import pytest

# Ensure tools/ is on the path
import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from tag_cache import TagCache


class TestTagCache:
    def test_empty_cache(self, tmp_path):
        cache = TagCache(str(tmp_path / "tags.json"))
        cache.load()
        assert cache.size == 0
        assert cache.get_tags("foo.py", 123.0) is None

    def test_set_and_get(self, tmp_path):
        cache = TagCache(str(tmp_path / "tags.json"))
        cache.load()
        tags = {"definitions": [{"name": "foo", "type": "function"}], "references": []}
        cache.set_tags("foo.py", 100.0, tags)
        result = cache.get_tags("foo.py", 100.0)
        assert result is not None
        assert result["definitions"][0]["name"] == "foo"

    def test_mtime_mismatch(self, tmp_path):
        cache = TagCache(str(tmp_path / "tags.json"))
        cache.load()
        tags = {"definitions": [], "references": []}
        cache.set_tags("foo.py", 100.0, tags)
        assert cache.get_tags("foo.py", 200.0) is None

    def test_save_and_reload(self, tmp_path):
        path = str(tmp_path / "tags.json")
        cache = TagCache(path)
        cache.load()
        cache.set_tags("bar.py", 50.0, {"definitions": [{"name": "bar"}], "references": []})
        cache.save()

        # Reload from disk
        cache2 = TagCache(path)
        cache2.load()
        assert cache2.size == 1
        result = cache2.get_tags("bar.py", 50.0)
        assert result is not None
        assert result["definitions"][0]["name"] == "bar"

    def test_remove(self, tmp_path):
        cache = TagCache(str(tmp_path / "tags.json"))
        cache.load()
        cache.set_tags("a.py", 1.0, {"definitions": [], "references": []})
        cache.set_tags("b.py", 2.0, {"definitions": [], "references": []})
        assert cache.size == 2
        cache.remove("a.py")
        assert cache.size == 1
        assert cache.get_tags("a.py", 1.0) is None

    def test_clear(self, tmp_path):
        cache = TagCache(str(tmp_path / "tags.json"))
        cache.load()
        cache.set_tags("a.py", 1.0, {"definitions": [], "references": []})
        cache.set_tags("b.py", 2.0, {"definitions": [], "references": []})
        cache.clear()
        assert cache.size == 0

    def test_corrupt_cache_file(self, tmp_path):
        path = tmp_path / "tags.json"
        path.write_text("not valid json{{{")
        cache = TagCache(str(path))
        cache.load()  # Should not raise
        assert cache.size == 0

    def test_no_save_when_clean(self, tmp_path):
        path = str(tmp_path / "tags.json")
        cache = TagCache(path)
        cache.load()
        cache.save()  # Should be no-op (not dirty)
        assert not os.path.exists(path)
