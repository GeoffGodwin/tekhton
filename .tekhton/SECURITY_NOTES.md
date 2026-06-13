# Security Notes

Generated: 2026-06-13 11:30:08

## Non-Blocking Findings (MEDIUM/LOW)
- [LOW] [category:A05] [lib/plan_batch.sh:88-90] fixable:yes — Temp files `$_pf`, `$_rf`, `$_zf` are created under `${TEKHTON_SESSION_DIR:-/tmp}` with only PID-based disambiguation. When the session dir falls back to `/tmp` on a multi-user system, the planning prompt (which may contain project-sensitive task descriptions) is transiently world-readable until cleanup. Suggested fix: wrap the file creation with `(umask 077; printf '%s' "$prompt" > "$_pf")`, or create a private temp directory with `mktemp -d -p "${TEKHTON_SESSION_DIR:-/tmp}" tekhton.XXXXXX` and restrict it to `chmod 700`.

