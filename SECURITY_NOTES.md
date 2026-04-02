# Security Notes

Generated: 2026-04-01 23:26:56

## Non-Blocking Findings (MEDIUM/LOW)
- [LOW] [category:A03] [lib/dashboard_parsers.sh:362] fixable:yes — Bash fallback JSON construction in `_parse_run_summaries_from_jsonl` interpolates `${task_label}` directly into a JSON string without calling `_json_escape`. If a task label contains backslashes or control characters, the resulting JSON is malformed. Use `$(_json_escape "${task_label}")` consistent with how other string fields are handled in `_parse_intake_report` and `_parse_coder_summary`.
- [LOW] [category:A03] [lib/dashboard_parsers.sh:448] fixable:yes — Same issue in `_parse_run_summaries_from_files`: `${milestone}`, `${run_type}`, `${task_label}`, and `${outcome}` are interpolated into JSON without `_json_escape`. These fields are sourced from RUN_SUMMARY_*.json files which could contain arbitrary task label strings.
- [LOW] [category:A04] [lib/dashboard_parsers.sh:35] fixable:yes — Temporary file in `_write_js_file` uses `${filepath}.tmp.$$` (PID-based). PID is guessable in low-process-count environments. Prefer `mktemp "${filepath}.tmp.XXXXXX"` for an unpredictable suffix, reducing the TOCTOU window on shared filesystems.
