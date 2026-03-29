# Reviewer Report — M38 Re-Review (Cycle 2)

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `stages/coder.sh`: The `declare -p _STAGE_STATUS &>/dev/null 2>&1` guard duplicates stderr redirect (`&>` already redirects both; the trailing `2>&1` is redundant but harmless).
- `dashboard_emitters.sh:159`: `IFS=',' read -ra _dep_arr <<< "$dep_list"` uses a leading underscore on a local array name; unconventional but harmless — the leading `_` is generally reserved for library-internal globals in this codebase.
- `app.js:326`: `setTimeout(..., 1500)` hardcodes the animation duration to match the CSS keyframe. If the CSS animation duration ever changes, this will silently diverge. Low risk but worth a comment.

## Coverage Gaps
- No new shell tests cover `_extract_milestone_summary()` (positive path: finds `## Overview`; negative paths: no Overview section, file missing). The function is a pure text parser and is testable without mocking. Consider adding cases to an existing dashboard test file.
- No test covers the emit-time `"pending"→"active"` override in `emit_dashboard_run_state()` — specifically the case where `CURRENT_STAGE` is set but its `_STAGE_STATUS` entry was never updated from pending.

## Drift Observations
- `dashboard.sh:163`: The live elapsed computation `$(( SECONDS - _STAGE_START_TS[$stg] ))` will produce a large positive integer if `_STAGE_START_TS[$stg]` is 0 (default for unset array key, because `${_STAGE_START_TS[$stg]:-}` is empty but arithmetic treats it as 0 while `SECONDS` may be 300+). This only fires for non-active stages that coincidentally get `stg_status=active` from the emit-time override — a narrow but possible edge case worth noting.

## Prior Blocker Resolution

**FIXED** — All four M38 features now implemented:
1. `tekhton.sh`: `_STAGE_START_TS` array declared, `_STAGE_STATUS[intake]="active"` + `_STAGE_START_TS[intake]="$SECONDS"` set before `run_stage_intake`, pre-emit call present (line 1799). All six stage sites updated with timestamps and "active" status.
2. `dashboard.sh`: Defensive `declare -p _STAGE_START_TS` guard (lines 143–145), emit-time `"pending"→"active"` override (lines 158–160), live elapsed computation for active stages (lines 163–165).
3. `dashboard_emitters.sh`: `_extract_milestone_summary()` helper present (lines 80–117). `emit_dashboard_milestones()` rewritten with 3-pass approach; `summary` and `enables` fields emitted in JSON (line 185).
4. `stages/coder.sh`: Scout `active`/`complete` status tracking with `declare -p` guard (lines 128–133, 234–239).
5. `templates/watchtower/app.js`: Scout skipped in top-level `renderStageChips` loop (line 154); scout sub-badge rendered inside coder chip (lines 157–164); stage-detail shows `fmtDuration · budget: N turns` for active and `N turns used · fmtDuration` for completed (lines 181–186, 225–231); `scrollToMilestone()` with highlight animation (lines 321–328); milestone card summary + dep chips with `stopPropagation` click handlers (lines 342–373, 420–425).
6. `templates/watchtower/style.css`: All six CSS additions present (lines 428–442): `.scout-sub-badge`, `.milestone-summary`, `.ms-dep-section`, `.dep-chip-enabledby`, `.dep-chip-enables`, `@keyframes msHighlight` / `.milestone-highlight`.
