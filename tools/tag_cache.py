"""Disk-based tag cache with mtime tracking.

Caches tree-sitter parse results keyed by (filepath, mtime) so unchanged files
skip re-parsing on subsequent runs. Stored as JSON in the cache directory.

Features (v3 Milestone 7):
- Cache versioning: automatic invalidation on format changes
- Statistics: hit/miss counts, parse time saved
- Pruning: remove entries for files that no longer exist
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any, Optional

# Bump this when the cache format changes to trigger automatic rebuild.
CACHE_VERSION = 2


class TagCache:
    """File-level tag cache backed by a JSON file on disk."""

    def __init__(self, cache_path: str) -> None:
        self._path = cache_path
        self._data: dict[str, dict[str, Any]] = {}
        self._dirty = False
        # Statistics (reset on load)
        self._hits = 0
        self._misses = 0
        self._parse_time_saved_ms = 0.0

    def load(self) -> None:
        """Load cache from disk. No-op if file doesn't exist.

        Checks cache version — if it doesn't match CACHE_VERSION, the cache
        is cleared (triggers a full rebuild on next run).
        """
        if not os.path.exists(self._path):
            self._data = {}
            return
        try:
            with open(self._path, "r", encoding="utf-8") as f:
                raw = json.load(f)
        except (json.JSONDecodeError, OSError):
            self._data = {}
            return

        # Version check
        stored_version = raw.get("_cache_version", None)
        if stored_version != CACHE_VERSION:
            print(f"[indexer] Cache version mismatch (stored={stored_version}, expected={CACHE_VERSION}) — rebuilding.", file=sys.stderr)
            self._data = {}
            self._dirty = True  # Will write new version on save
            return

        # Strip metadata keys from data dict
        self._data = {k: v for k, v in raw.items() if not k.startswith("_")}

    def save(self) -> None:
        """Write cache to disk atomically (tmpfile + rename)."""
        if not self._dirty:
            return
        os.makedirs(os.path.dirname(self._path) or ".", exist_ok=True)
        tmp_path = self._path + ".tmp"
        try:
            out = dict(self._data)
            out["_cache_version"] = CACHE_VERSION
            with open(tmp_path, "w", encoding="utf-8") as f:
                json.dump(out, f, separators=(",", ":"))
            os.replace(tmp_path, self._path)
            self._dirty = False
        except OSError:
            if os.path.exists(tmp_path):
                os.unlink(tmp_path)

    def get_tags(self, filepath: str, mtime: float) -> Optional[dict[str, Any]]:
        """Retrieve cached tags if mtime matches. Returns None on miss."""
        entry = self._data.get(filepath)
        if entry is None:
            self._misses += 1
            return None
        if abs(entry.get("mtime", 0) - mtime) > 0.001:
            self._misses += 1
            return None
        self._hits += 1
        # Track parse time saved (if recorded)
        saved = entry.get("parse_ms", 0.0)
        if saved:
            self._parse_time_saved_ms += saved
        return entry.get("tags")

    def set_tags(
        self, filepath: str, mtime: float, tags: dict[str, Any],
        parse_ms: Optional[float] = None,
    ) -> None:
        """Store tags with mtime for a file. Optionally record parse time."""
        entry: dict[str, Any] = {"mtime": mtime, "tags": tags}
        if parse_ms is not None:
            entry["parse_ms"] = parse_ms
        self._data[filepath] = entry
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

    def prune_cache(self, root_dir: str) -> int:
        """Remove entries for files that no longer exist on disk.

        Args:
            root_dir: Project root directory (paths in cache are relative to this).

        Returns:
            Number of entries pruned.
        """
        to_remove = []
        for filepath in self._data:
            full_path = os.path.join(root_dir, filepath)
            if not os.path.exists(full_path):
                to_remove.append(filepath)

        for filepath in to_remove:
            del self._data[filepath]

        if to_remove:
            self._dirty = True
        return len(to_remove)

    @property
    def size(self) -> int:
        """Number of cached file entries."""
        return len(self._data)

    @property
    def hits(self) -> int:
        """Number of cache hits since load."""
        return self._hits

    @property
    def misses(self) -> int:
        """Number of cache misses since load."""
        return self._misses

    @property
    def parse_time_saved_ms(self) -> float:
        """Cumulative parse time saved by cache hits (milliseconds)."""
        return self._parse_time_saved_ms

    def hit_rate(self) -> float:
        """Cache hit rate as a float [0.0, 1.0]. Returns 0.0 if no lookups."""
        total = self._hits + self._misses
        if total == 0:
            return 0.0
        return self._hits / total

    def stats_dict(self) -> dict[str, Any]:
        """Return cache statistics as a dictionary."""
        return {
            "hits": self._hits,
            "misses": self._misses,
            "cache_size": self.size,
            "hit_rate": self.hit_rate(),
            "parse_time_saved_ms": self._parse_time_saved_ms,
        }
