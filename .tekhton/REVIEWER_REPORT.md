## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/plan_batch.sh:88-94` — LOW security finding from the security agent was not applied: temp files `$_pf`, `$_rf`, `$_zf` are created without umask restriction, making them world-readable when `TEKHTON_SESSION_DIR` falls back to `/tmp`. Fix: `(umask 077; printf '%s' "$prompt" > "$_pf")`.
- `lib/plan_batch.sh:165-178` — `_plan_batch_emit_tail` awk handles only 4 of 8 standard JSON escape sequences (`\n`, `\t`, `\"`, `\\`). Missing `\r`, `\/`, `\b`, `\f`, `\uXXXX`. Unlikely to matter for markdown planning output but would silently corrupt output containing non-ASCII characters encoded as `\uXXXX` by Go's JSON marshaller.

## Coverage Gaps
- `_plan_batch_emit_tail` has no unit test. The awk JSON unescape logic is non-trivial and warrants a `tests/test_plan_batch.sh` fixture exercising at least the handled escapes and a multi-line `stdout_tail`.
- No shim-boundary integration test for the new `label → PROVIDER_<LABEL>` routing path through `_call_planning_batch` (e.g., verifying `PROVIDER=codex` skips the `claude` MCP/usage probes and routes through the shim).

## Drift Observations
- `lib/replan_midrun.sh` sits at 299 lines — 1 line under the 300-line hard ceiling. The next addition forces a split.
- `lib/common.sh` sits at 291 lines — approaching ceiling.
- `lib/plan_batch.sh:2`, `stages/plan_generate.sh:17`, and several other sourced `lib/`/`stages/` files have `set -euo pipefail` explicitly, which the reviewer checklist flags as wrong for sourced files (they should inherit from the caller). Pre-existing across multiple files; not introduced by this change.
