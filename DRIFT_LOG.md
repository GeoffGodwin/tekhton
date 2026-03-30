# Drift Log

## Metadata
- Last audit: 2026-03-30
- Runs since audit: 1

## Unresolved Observations
- [2026-03-30 | "[BUG] Watchtower Reports page: Test Audit section never displays any information"] `templates/watchtower/app.js` — The emitter→renderer contract (data shape) is implicit; a comment on `renderTestAuditBody()` documenting the expected fields (`verdict`, `high_findings`, `medium_findings`) would prevent re-introducing the same mismatch
(none)

## Resolved
- [RESOLVED 2026-03-30] Watchtower Trends page: Per-stage breakdown — fix Last Run column content, remove redundant Budget Util column, fix Avg Turns/Last Run identity bug, and fix unpopulated Build stage row"] `config_defaults.sh:287-290` vs `config_defaults.sh:59-62` — Two parallel auto-fix-on-test-failure feature families now exist: `AUTO_FIX_ON_TEST_FAILURE` / `AUTO_FIX_MAX_DEPTH` / `AUTO_FIX_OUTPUT_LIMIT` (tester stage, recursive invocation, opt-in default) and `TEST_FIX_ENABLED` / `TEST_FIX_MAX_ATTEMPTS` / `TEST_FIX_MAX_TURNS` (final checks, inline agent, opt-out default). The different pipeline phases justify two implementations, but the naming divergence will confuse operators configuring via `pipeline.conf`. A single naming family (e.g., `FINAL_TEST_FIX_*`) or a shared prefix with a scope suffix would reduce cognitive load.
- [RESOLVED 2026-03-30] Currently if there are failures during the Tekhton Self-Tests, the pipeline gives its final summary and then notes there are failed tests and exits cleanly. Instead of exiting it should immediately spawn a fix run with the same notes + a new note to "Fix failed tests" so that the user can get right into fixing instead of having to trigger a new run manually."] `config_defaults.sh:287-290` vs `config_defaults.sh:59-62` — Two parallel auto-fix-on-test-failure feature families now exist: `AUTO_FIX_ON_TEST_FAILURE` / `AUTO_FIX_MAX_DEPTH` / `AUTO_FIX_OUTPUT_LIMIT` (tester stage, recursive invocation, opt-in default) and `TEST_FIX_ENABLED` / `TEST_FIX_MAX_ATTEMPTS` / `TEST_FIX_MAX_TURNS` (final checks, inline agent, opt-out default). The different pipeline phases justify two implementations, but the naming divergence will confuse operators configuring via `pipeline.conf`. A single naming family (e.g., `FINAL_TEST_FIX_*`) or a shared prefix with a scope suffix would reduce cognitive load.
