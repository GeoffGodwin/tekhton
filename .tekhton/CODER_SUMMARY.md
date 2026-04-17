# Coder Summary
## Status: COMPLETE

## What Was Implemented
M92 — Pristine Test State Enforcement. The pipeline now treats `pre_existing`
test failures as blocking (not auto-pass) and runs a pre-coder clean sweep
when tests are failing before the coder runs.

1. **Default flip** — `TEST_BASELINE_PASS_ON_PREEXISTING` defaults to `false`
   (was `true`). Projects that genuinely cannot fix some tests can opt back in
   via `pipeline.conf`. The escape hatch is documented in
   `docs/configuration.md` and `docs/concepts/test-baseline.md`.
2. **Strict post-run gates** — Three sites that previously auto-passed on
   `pre_existing` (milestone acceptance, completion gate, orchestrator
   pre-finalization gate) now only auto-pass when `PASS_ON_PREEXISTING=true`
   is explicitly set. Otherwise they route back to fix/rework like
   `new_failures`.
3. **Pre-coder clean sweep** — New `stages/coder_prerun.sh` runs at the top
   of `run_stage_coder()`. If `PRE_RUN_CLEAN_ENABLED=true` (default) and
   `TEST_CMD` fails, it spawns a restricted fix agent (reusing
   `preflight_fix` prompt, `PRE_RUN_FIX_MAX_TURNS=20`,
   `PRE_RUN_FIX_MAX_ATTEMPTS=1`). On success the test baseline is
   re-captured so downstream gates compare against the clean state.
   On failure, the pipeline warns loudly and proceeds — "can't fix
   everything" is acknowledged; silent acceptance is not.
4. **Config defaults + clamps** — Three new keys (`PRE_RUN_CLEAN_ENABLED`,
   `PRE_RUN_FIX_MAX_TURNS`, `PRE_RUN_FIX_MAX_ATTEMPTS`) added to
   `lib/config_defaults.sh` with documented defaults.

## Root Cause (bugs only)
N/A — behavioral change, not a bug fix.

## Files Modified
- `lib/config_defaults.sh` — flipped `TEST_BASELINE_PASS_ON_PREEXISTING`
  default to `false`; added `PRE_RUN_CLEAN_ENABLED`, `PRE_RUN_FIX_MAX_TURNS`,
  `PRE_RUN_FIX_MAX_ATTEMPTS` keys.
- `lib/milestone_acceptance.sh` — removed auto-pass on `pre_existing`;
  routes back to fix unless `PASS_ON_PREEXISTING=true`.
- `lib/gates_completion.sh` — same treatment inside the completion gate
  test integrity check.
- `lib/orchestrate.sh` — same treatment inside the pre-finalization test
  gate.
- `stages/coder.sh` — sources `coder_prerun.sh` and calls
  `run_prerun_clean_sweep` at the top of `run_stage_coder()`.
- `stages/coder_prerun.sh` — **(NEW)** 141 lines. Provides
  `run_prerun_clean_sweep` + `_run_prerun_fix_agent`.
- `tests/test_pristine_state_enforcement.sh` — **(NEW)** 227 lines,
  7 suites / 14 assertions covering config defaults, acceptance gate
  behavior, completion gate behavior, pre-run sweep enable/skip, fix
  success path (baseline re-capture), and fix failure path (graceful
  fallthrough).
- `docs/configuration.md` — added pre-coder clean sweep row to the
  feature table; `PASS_ON_PREEXISTING=false` caveat added to the test
  baseline row.
- `docs/concepts/test-baseline.md` — updated explanation of
  `PASS_ON_PREEXISTING` default flip.
- `docs/reference/configuration.md` — three new config rows.
- `templates/pipeline.conf.example` — commented-out entries for the
  three new keys with rationale.
- `ARCHITECTURE.md` — Layer 3 entry for `stages/coder_prerun.sh`;
  updated `stages/coder.sh` entry to note the pre-run sweep sub-stage.
- `CLAUDE.md` — new template variables added to the table.

## Verification Results
- `bash tests/test_pristine_state_enforcement.sh` — 14 passed, 0 failed.
- `bash tests/run_tests.sh` — Shell: 376 passed / 0 failed; Python: 87
  passed.
- `shellcheck tekhton.sh lib/*.sh stages/*.sh` — zero warnings.
- File-length self-check: all files I created or modified significantly
  are under the 300-line ceiling (`coder_prerun.sh`=141, test=227,
  `milestone_acceptance.sh`=217, `gates_completion.sh`=121).
  `lib/orchestrate.sh` (440) and `stages/coder.sh` (1166) were already
  over ceiling pre-M92; my edits add only 10 lines net to each.
  `lib/config_defaults.sh` (593) is a config registry by design.

## Docs Updated
- `docs/configuration.md` — pre-coder clean sweep table entry + updated
  test baseline row.
- `docs/concepts/test-baseline.md` — `PASS_ON_PREEXISTING` default flip.
- `docs/reference/configuration.md` — three new config key rows.
- `templates/pipeline.conf.example` — opt-out comments.
- `ARCHITECTURE.md` — Layer 3 entry for `stages/coder_prerun.sh`.
- `CLAUDE.md` — template variable table entries.

## Human Notes Status
No unchecked human notes to address this run.

## Acceptance Criteria Mapping
- [x] Default flipped to `false` in `config_defaults.sh`.
- [x] `pre_existing` no longer auto-passes at milestone acceptance,
  completion gate, or pre-finalization gate under the new default
  (covered by suites 2, 6 of the pristine-state test).
- [x] Legacy opt-in preserved with `PASS_ON_PREEXISTING=true`
  (covered by suites 3, 6).
- [x] Pre-coder fix agent spawned when tests fail and
  `PRE_RUN_CLEAN_ENABLED=true` (suite 5).
- [x] Graceful fallthrough when fix agent fails — no hard abort
  (suite 7).
- [x] Sweep skipped when `PRE_RUN_CLEAN_ENABLED=false` (suite 4).
- [x] `bash tests/test_pristine_state_enforcement.sh` passes.
- [x] `shellcheck` zero warnings on touched files.
- [x] `tests/test_orchestrate.sh` still passes (no pre_existing
  assertions in that file — no update needed).
