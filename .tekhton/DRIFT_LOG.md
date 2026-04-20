# Drift Log

## Metadata
- Last audit: 2026-04-20
- Runs since audit: 1

## Unresolved Observations
- [2026-04-20 | "architect audit"] **`stages/review.sh` Jr-after-Sr TUI path (lines 294–303) — no `tui_stage_begin`/`tui_stage_end` brackets** The coder summary confirms this is intentional: "Jr-after-Sr pill-sharing path is deliberately left unwired per spec." The pipeline spec §5 also confirms the decision. The behavior is correct. No remediation action is warranted; the drift log entry can be cleared. --- **`tools/tests/test_tui.py` at 768 lines (over 300-line soft ceiling)** The 300-line ceiling is a convention for shell library files in `lib/` — it was established to keep individual sourced modules auditable and to limit context window cost when loading files into agent prompts. Python test files have no equivalent constraint: they grow naturally with test coverage, are never sourced into shell context, and are not subject to the same auditing economics. No action is warranted; the drift log entry can be cleared.

## Resolved
- [RESOLVED 2026-04-20] `stages/review.sh` Jr-after-Sr path (lines 294–303): when `HAS_SIMPLE > 0` fires after Sr rework, the Jr Coder `run_agent` call has no `tui_stage_begin`/`tui_stage_end` brackets. The coder summary notes this is intentional ("Jr-after-Sr pill-sharing path is deliberately left unwired per spec"), and the spec §5 confirms it. Noted here as a drift observation for future audit in case the reasoning changes.
- [RESOLVED 2026-04-20] `tools/tests/test_tui.py` is now ~768 lines, well over the 300-line soft ceiling. Not a blocker (test files grow naturally), but worth tracking for eventual split.
- [RESOLVED 2026-04-20] `lib/agent.sh`, `lib/agent_helpers.sh`, `lib/agent_retry.sh`, `lib/drift_cleanup.sh`, `lib/test_dedup.sh`, `lib/finalize_commit.sh`, `lib/finalize_dashboard_hooks.sh` — seven sourced-only lib files lack `set -euo pipefail`, drifting from CLAUDE.md Non-Negotiable Rule #2; all inherit the setting from their parent, so no functional impact, but the gap is growing and warrants a sweep milestone
- [RESOLVED 2026-04-20] `lib/orchestrate.sh` is 463 lines — 54% over the 300-line ceiling. Pre-existing and noted by coder; extraction is its own pass.
- [RESOLVED 2026-04-20] `lib/tui_ops.sh` accesses globals declared in `lib/tui.sh` (`_TUI_ACTIVE`, `_TUI_RECENT_EVENTS`, `_TUI_STAGES_COMPLETE`, `_TUI_CURRENT_STAGE_*`, `_TUI_AGENT_*`, `_tui_write_status`) with no `# shellcheck source=tui.sh` directive. Consistent with the pre-existing gap in `tui_helpers.sh` — not new drift.
