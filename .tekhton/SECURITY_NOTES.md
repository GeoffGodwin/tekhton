# Security Notes

Generated: 2026-05-29 09:42:26

## Non-Blocking Findings (MEDIUM/LOW)
- [LOW] [category:A03] [lib/mcp_resolve.sh:135-140] fixable:yes — Sed delimiter injection: `_resolve_mcp_config` substitutes `_SERENA_BIN`, `PROJECT_DIR`, `_SERENA_DIR`, and `lang_servers` directly into sed `-e "s|{{VAR}}|${VAR}|g"` expressions using `|` as the delimiter. If any variable contains a literal `|`, the sed expression is silently truncated; on GNU sed, a value of the form `<cmd>|e` could cause `e`-flag execution of the replacement as a shell command. Realistic vectors: (a) `SERENA_LANGUAGE_SERVERS` env var set to a value containing `|e` with a shell-executable prefix; (b) a project directory path containing `|`. An attacker exploiting (a) already controls config/env and has other code-execution paths. Fix: escape `|` in each variable before substitution (e.g. `"${VAR//|/\\|}"`) or replace sed with a Python one-liner that uses string replacement instead of regex.
