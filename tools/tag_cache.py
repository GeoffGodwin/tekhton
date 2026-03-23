"""Disk-based tag cache with mtime tracking.

Caches tree-sitter parse results keyed by (filepath, mtime) so unchanged files
skip re-parsing on subsequent runs. Stored as JSON in the cache directory.
"""

from __future__ import annotations

import json
import os
from typing import Any, Optional


class TagCache:
    """File-level tag cache backed by a JSON file on disk."""

    def __init__(self, cache_path: str) -> None:
        self._path = cache_path
        self._data: dict[str, dict[str, Any]] = {}
        self._dirty = False

    def load(self) -> None:
        """Load cache from disk. No-op if file doesn't exist."""
        if not os.path.exists(self._path):
            self._data = {}
            return
        try:
            with open(self._path, "r", encoding="utf-8") as f:
                self._data = json.load(f)
        except (json.JSONDecodeError, OSError):
            self._data = {}

    def save(self) -> None:
        """Write cache to disk atomically (tmpfile + rename)."""
        if not self._dirty:
            return
        os.makedirs(os.path.dirname(self._path) or ".", exist_ok=True)
        tmp_path = self._path + ".tmp"
        try:
            with open(tmp_path, "w", encoding="utf-8") as f:
                json.dump(self._data, f, separators=(",", ":"))
            os.replace(tmp_path, self._path)
            self._dirty = False
        except OSError:
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)

    def get_tags(self, filepath: str, mtime: float) -> Optional[dict[str, Any]]:
        """Retrieve cached tags if mtime matches. Returns None on miss."""
        entry = self._data.get(filepath)
        if entry is None:
            return None
        if abs(entry.get("mtime", 0) - mtime) > 0.001:
            return None
        return entry.get("tags")

    def set_tags(
        self, filepath: str, mtime: float, tags: dict[str, Any]
    ) -> None:
        """Store tags with mtime for a file."""
        self._data[filepath] = {"mtime": mtime, "tags": tags}
        self._dirty = True

    def remove(self, filepath: str) -> None:
        """Remove a file's entry from the cache."""
        if filepath in self._data:
            del self._data[filepath]
            self._dirty = True

    def clear(self) -> None:
        """Clear all cached entries."""
        self._data.clear()
        self._dirty = True

    @property
    def size(self) -> int:
        """Number of cached file entries."""
        return len(self._data)
