## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/plan_batch.sh:165-178` (`_plan_batch_emit_tail`) — awk unescape order is wrong for sequences like `\\n`. `gsub(/\\\\/, "\\", line)` must run BEFORE `gsub(/\\n/, ...)` etc.; otherwise a JSON element containing `\\n` (literal backslash + n) decodes as `\<newline>` instead of `\n`. Also missing `\r`, `\b`, `\f`, `\uXXXX`. Low practical impact for markdown prose but silently corrupts code blocks containing literal `\n` or Unicode escapes from Go's JSON marshaller.
- `lib/plan_batch.sh:399` — `: "$max_turns"` no-op is now redundant; `max_turns` is used in the `_shim_write_request` call on line 445. Harmless — can be removed for clarity.
- LOW security finding from the security agent (temp files `$_pf`/`$_rf`/`$_zf` are world-readable in `/tmp` fallback) was not auto-applied. Fix: `(umask 077; printf '%s' "$prompt" > "$_pf")` and restrict `$_sd` with `chmod 700`.

## Coverage Gaps
- `_plan_batch_emit_tail` has no unit test. The awk unescape logic is non-trivial; a `tests/test_plan_batch.sh` fixture exercising at least `\n`, `\t`, `\"`, `\\`, and the `\\n` ordering case would prevent silent regressions.
- No shim-boundary integration test for `label → PROVIDER_<LABEL>` routing through `_call_planning_batch` (e.g., verifying `PROVIDER=codex` skips the `claude` MCP/usage probes).

## Drift Observations
- `lib/replan_midrun.sh` sits at 299 lines — 1 line under the 300-line hard ceiling. The next addition forces a split.
- `lib/common.sh` sits at 291 lines — approaching ceiling.
- `PROVIDER:-codex,claude` default string appears independently in both `lib/common.sh:check_usage_threshold` and `lib/mcp_resolve.sh:_cli_supports_mcp_config`. If the canonical default changes there are two sites to update; a shared `_provider_includes_claude()` helper would unify them.
- Several sourced `lib/`/`stages/` files (including `plan_batch.sh:2`) carry `set -euo pipefail` explicitly, which the reviewer checklist flags as wrong for sourced files. Pre-existing pattern, not introduced by m20.
