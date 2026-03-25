# Security Notes

Generated: 2026-03-25 09:33:40

## Non-Blocking Findings (MEDIUM/LOW)
- [LOW] [category:A05] [lib/init_config.sh:202] fixable:yes — `_merge_preserved_values()` creates a predictable tmpfile (`${conf_file}.merge.$$`) with no cleanup trap. If the process is killed mid-rewrite (SIGINT, SIGTERM, or `set -e` exit), the stale `.merge.<PID>` file is left in the project directory alongside the original config. Add `trap 'rm -f "$tmpfile"' EXIT INT TERM` immediately after `local tmpfile=...` to guarantee cleanup on abnormal exit.
