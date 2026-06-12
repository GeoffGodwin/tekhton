## Summary
This change migrates `_call_planning_batch()` in `lib/plan_batch.sh` from direct `claude` CLI invocation to the `tekhton supervise` seam, adds provider-awareness guards in `lib/common.sh` and `lib/mcp_resolve.sh`, and threads a hardcoded `label` argument through five callers. No authentication, cryptography, or network I/O is introduced. All shell variable expansions in new code are quoted. The attack surface is limited to local filesystem temp files and an internal awk-based JSON tail parser. Overall posture is good.

## Findings
- [LOW] [category:A05] [lib/plan_batch.sh:88-90] fixable:yes — Temp files `$_pf`, `$_rf`, `$_zf` are created under `${TEKHTON_SESSION_DIR:-/tmp}` with only PID-based disambiguation. When the session dir falls back to `/tmp` on a multi-user system, the planning prompt (which may contain project-sensitive task descriptions) is transiently world-readable until cleanup. Suggested fix: wrap the file creation with `(umask 077; printf '%s' "$prompt" > "$_pf")`, or create a private temp directory with `mktemp -d -p "${TEKHTON_SESSION_DIR:-/tmp}" tekhton.XXXXXX` and restrict it to `chmod 700`.

## Verdict
FINDINGS_PRESENT
