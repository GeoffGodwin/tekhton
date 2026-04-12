# Security Notes

Generated: 2026-04-12 16:18:53

## Non-Blocking Findings (MEDIUM/LOW)
- [LOW] [category:A04] [lib/notes_core_normalize.sh:27-42] fixable:yes — No `trap` is set to remove `$tmpfile` on failure. If `awk` exits non-zero (e.g. disk full, SIGINT), the partial temp file containing notes content is left in `TEKHTON_SESSION_DIR` or `/tmp` and never cleaned up. Fix: add `trap 'rm -f "$tmpfile"' EXIT` immediately after the `mktemp` call and remove it on success.
- [LOW] [category:A04] [lib/notes_core_normalize.sh:42] fixable:yes — `mv "$tmpfile" "$file"` replaces the original file without preserving its permissions. `mktemp` creates files with mode 0600; if the target file had wider permissions (e.g. 0644), the replacement silently tightens them. Fix: capture permissions with `stat` before writing and restore with `chmod` after `mv`, or use `install -m` instead.
