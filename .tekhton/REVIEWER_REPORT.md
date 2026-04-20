# Reviewer Report — M109: Init Feature Wizard (Cycle 2)

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/init_wizard.sh:208–219` — Both the indexer and Serena setup scripts write to the same `$indexer_log` file. Serena's run will overwrite the indexer log, potentially losing indexer failure output for debugging. A separate `serena_setup.log` would be cleaner.
- `lib/init_wizard.sh:175–177` — `return $?` after `bash "$script" "$@"` in the VERBOSE branch is redundant; the function's exit code is already the last command's exit code.
- `lib/init_wizard.sh:224` — `_INIT_FILES_WRITTEN+=` is mutated directly from `_run_wizard_venv_setup`, reaching across module boundaries into init.sh's bookkeeping. Works correctly but blurs array ownership.

## Coverage Gaps
- `_wizard_attention_lines` has no direct unit test; it's exercised only implicitly through the init banner flow. A unit test covering the `true` (features enabled), `false` (no Python), and unset (wizard never ran) cases would guard against future regressions.
- `_wizard_run_setup_script` VERBOSE_OUTPUT=true path and `_run_wizard_venv_setup` are not tested (hard to unit-test without the actual setup scripts; appropriate to leave for a later integration test pass).

## ACP Verdicts
(none — no Architecture Change Proposals in CODER_SUMMARY.md)

## Drift Observations
- `lib/init_wizard.sh:224` — `_INIT_FILES_WRITTEN` is a global array declared in `init.sh` and mutated by `_run_wizard_venv_setup` in `init_wizard.sh`. If more wizard-style modules are extracted in the future, registration points will scatter. Consider a `_init_register_file path desc` helper as a single registration entry point.

---
**Prior blocker resolved:** `set -euo pipefail` is now present on line 2 of all three new files (`lib/init_wizard.sh`, `lib/init_config_workspace.sh`, `lib/init_report_banner_next.sh`). Verified by direct read.
