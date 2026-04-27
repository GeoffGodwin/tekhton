# Reviewer Report — M131 Preflight Test Framework Config Audit & Interactive-Mode Detection

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/preflight_checks_ui.sh` uses `grep -P` (PCRE) throughout all five scanners. PCRE grep is not available on macOS (BSD grep). Not an issue on the documented Linux/WSL target, but worth tracking if macOS support is ever added.
- `_pf_uitest_playwright`, `_pf_uitest_cypress`, and `_pf_uitest_jest_watch` each emit a `pass` record when zero issues are found. A project with both a Playwright and a Cypress config (both clean) emits two `pass` records — minor verbosity, not a correctness issue.

## Coverage Gaps
- `_ui_deterministic_env_list` M131 escalation path is not directly unit-tested: when `PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1`, the function must produce `CI=1` without the caller passing `hardened=1`. The existing `test_ui_gate_force_noninteractive.sh` exercises the `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1` path (a separate escalation vector). A dedicated assertion for the M131 detection → hardened escalation would catch regressions in `_ui_deterministic_env_list`.
- CY-2 pass case not tested: no assertion that `reporter: 'mochawesome'` in `cypress.config` combined with `--exit` present in `UI_TEST_CMD` produces zero warns (the inner guard's "no issue" exit path).

## Drift Observations
- `lib/preflight_checks_ui.sh` comments reference m132/m133/m134/m135/m136 (future milestones) as downstream contract consumers. Forward-looking milestone references become silently stale if numbering shifts. The rest of the codebase references already-landed milestones. Neutral phrasing ("see downstream consumers in the milestone definition") would age better.
