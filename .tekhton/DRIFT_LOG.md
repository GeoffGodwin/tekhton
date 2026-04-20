# Drift Log

## Metadata
- Last audit: 2026-04-19
- Runs since audit: 4

## Unresolved Observations
- [2026-04-20 | "M106"] `tools/tests/test_tui.py` is now ~768 lines, well over the 300-line soft ceiling. Not a blocker (test files grow naturally), but worth tracking for eventual split.
- [2026-04-20 | "Address all 11 open non-blocking notes in .tekhton/NON_BLOCKING_LOG.md. Fix each item and note what you changed."] `lib/agent.sh`, `lib/agent_helpers.sh`, `lib/agent_retry.sh`, `lib/drift_cleanup.sh`, `lib/test_dedup.sh`, `lib/finalize_commit.sh`, `lib/finalize_dashboard_hooks.sh` — seven sourced-only lib files lack `set -euo pipefail`, drifting from CLAUDE.md Non-Negotiable Rule #2; all inherit the setting from their parent, so no functional impact, but the gap is growing and warrants a sweep milestone
- [2026-04-19 | "M105"] `lib/orchestrate.sh` is 463 lines — 54% over the 300-line ceiling. Pre-existing and noted by coder; extraction is its own pass.
- [2026-04-19 | "M104"] `lib/tui_ops.sh` accesses globals declared in `lib/tui.sh` (`_TUI_ACTIVE`, `_TUI_RECENT_EVENTS`, `_TUI_STAGES_COMPLETE`, `_TUI_CURRENT_STAGE_*`, `_TUI_AGENT_*`, `_tui_write_status`) with no `# shellcheck source=tui.sh` directive. Consistent with the pre-existing gap in `tui_helpers.sh` — not new drift.

## Resolved
