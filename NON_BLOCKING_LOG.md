# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-04-06 | "M60"] `tests/test_platform_mobile_game.sh` is 477 lines and `tests/test_platform_m60_integration.sh` is 374 lines — both exceed the 300-line soft ceiling. Tests work correctly and cover the full platform matrix; log for a future cleanup pass.
- [ ] [2026-04-06 | "[POLISH] The Run Summary print out in Tekhton should also reflect which model was used at that stage. For instance if the Coder was using sonnet-4-6 or opus-4-6, that should be printed in the summary for that stage. This is important for debugging and understanding performance differences between models."] `lib/metrics.sh:293` — The comment above `_extract_stage_turns()` documents the old STAGE_SUMMARY format (`" Coder: 45/100 turns, 5m30s"`) and no longer reflects the updated format with the model suffix (`" Coder (claude-sonnet-4-6): 45/100 turns, 5m30s"`). Minor stale comment; the parser logic itself already handles both formats correctly.
- [ ] [2026-04-05 | "[BUG] The Milestone Map is no longer showing the currently active milestone in the Active column. It remains in the READY column and then jumps to DONE when completed, without ever showing as ACTIVE."] `templates/watchtower/app.js`: `msIdMatch()` is defined as an inner function mid-body inside `renderMilestonesByStatus()` rather than near the top of that function. Minor readability concern — inner functions are easier to spot when hoisted to the top of the enclosing function.
- [ ] [2026-04-05 | "[BUG] The Milestone Map is no longer showing the currently active milestone in the Active column. It remains in the READY column and then jumps to DONE when completed, without ever showing as ACTIVE."] `orchestrate.sh` / `orchestrate_helpers.sh`: The `command -v emit_dashboard_milestones &>/dev/null` guard is always true when these files run under `tekhton.sh` (since `dashboard_emitters.sh` is unconditionally sourced). The guard is harmless and defensive, but a comment noting why it exists would help future readers understand the intent vs. a dead check.



## Resolved
