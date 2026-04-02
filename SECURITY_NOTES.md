# Security Notes

Generated: 2026-04-02 08:47:03

## Non-Blocking Findings (MEDIUM/LOW)
- [LOW] [category:A03] [lib/dashboard_parsers_runs_files.sh:75] fixable:yes — SECURITY_NOTES.md cites line 84 as the location of the `_json_escape` fix in the sed fallback path, but the JSON construction where the fix applies is at line 75. Line 84 is `result="${result}${json_content}"`. The fix is present and correct; only the reference line number in the notes is off by ~9 lines. Informational only — no security risk.
