# Security Notes

Generated: 2026-05-26 23:22:58

## Non-Blocking Findings (MEDIUM/LOW)
- [LOW] [category:A03] [tests/test_m84_static_analysis.sh:55] fixable:yes — `_strip_m27_defaults` passes `fname` directly to `grep -v "${fname}}"` without escaping regex metacharacters. The `.` in filenames like `SCOUT_REPORT.md}` is treated as "any character" by grep rather than a literal dot. Since `M84_FILES` is hardcoded and never user-supplied this is not exploitable, but the pattern could over-exclude lines like `SCOUT_REPORTXmd}`. Fix: use `grep -vF "${fname}}"` (fixed-string mode) or escape the dot.
