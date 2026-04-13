# Security Notes

Generated: 2026-04-12 20:55:53

## Non-Blocking Findings (MEDIUM/LOW)
- [LOW] [category:A04] [lib/notes_core_normalize.sh:27] fixable:yes — The tempfile created by `mktemp` is not cleaned up if the process is interrupted after `mktemp` but before `mv "$tmpfile" "$file"` completes (e.g. SIGKILL or disk-full abort). The orphaned file in `TEKHTON_SESSION_DIR`/`/tmp` contains only markdown content — no credentials or sensitive data — making this a resource-leak concern rather than a data-exposure risk. Fix: add `trap 'rm -f "$tmpfile"' RETURN ERR` immediately after the `mktemp` call.
