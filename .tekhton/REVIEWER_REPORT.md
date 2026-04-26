# Reviewer Report — M128 Build-Fix Continuation Loop & Adaptive Turn Budgeting

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `stages/coder.sh:1111-1121`: `BUILD_GATE_RETRY=0` and the inner `if [ "$BUILD_GATE_RETRY" -lt 1 ]` guard are vestigial from the pre-M128 single-retry pattern. The inner condition is always true, and setting `BUILD_GATE_RETRY=1` serves no purpose now that `run_build_fix_loop` owns all retry logic. Safe to remove in a future cleanup pass.
- `stages/coder.sh:1109`: comment still reads "with one retry" but retry depth is now config-driven via `BUILD_FIX_MAX_ATTEMPTS`. Minor doc rot.
- `lib/config_defaults.sh:74` and `lib/artifact_defaults.sh:25`: `BUILD_FIX_REPORT_FILE` default is declared in both files. The artifact_defaults.sh placement is per-spec; the config_defaults.sh one is redundant (`:=` is a no-op if already set). Remove the config_defaults.sh duplicate in a cleanup pass.
- `tests/build_fix_loop_fixtures.sh:41`: `filter_code_errors() { cat; }` stub reads stdin instead of its positional argument, returning empty string rather than passing `$raw` through. Comment says "pass-through" but it isn't. Doesn't break any current test since none assert on prompt content. Fix: `filter_code_errors() { printf '%s\n' "${1:-}"; }`.
- `BUILD_FIX_TURN_BUDGET_USED` tracks allocated budget per attempt (full `budget` value), not actual `LAST_AGENT_TURNS`. Conservative (prevents cap overrun) but the name implies "turns spent." M132 consumers should treat this as an upper-bound count.
- Acceptance criterion "stages/coder.sh lines decreased" is technically unmet (+6 lines net). The coder's explanation is accurate — M127 had already extracted the inline block; M128 adds only the Goal-7 reset exports. Non-issue.

## Coverage Gaps
- `BUILD_FIX_ENABLED=false` path (T9d) verifies `OUTCOME=not_run` but does not assert that `write_pipeline_state` is called and `exit 1` fires, unlike the analogous coverage in `test_m127_buildfix_routing.sh`. Low priority given the path is short and unambiguous.

## ACP Verdicts

## Drift Observations
- `stages/coder.sh` is 1131 lines, far over the 300-line ceiling. Pre-existing and noted by the coder. `run_stage_coder` is the primary offender; splitting into discrete sub-stage orchestrators would address this debt in a future milestone.
