# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-04-20 | "M109: Init Feature Wizard"] `lib/init_wizard.sh:208–219` — Both the indexer and Serena setup scripts write to the same `$indexer_log` file. Serena's run will overwrite the indexer log, potentially losing indexer failure output for debugging. A separate `serena_setup.log` would be cleaner.
- [ ] [2026-04-20 | "M109: Init Feature Wizard"] `lib/init_wizard.sh:175–177` — `return $?` after `bash "$script" "$@"` in the VERBOSE branch is redundant; the function's exit code is already the last command's exit code.
- [ ] [2026-04-20 | "M109: Init Feature Wizard"] `lib/init_wizard.sh:224` — `_INIT_FILES_WRITTEN+=` is mutated directly from `_run_wizard_venv_setup`, reaching across module boundaries into init.sh's bookkeeping. Works correctly but blurs array ownership.
- [ ] [2026-04-20 | "M108: TUI Stage Timings Column"] `tools/tests/test_tui.py:774` — `import time as _time` appears mid-file after ~770 lines of test functions, suppressed with `# noqa: E402`. Functionally correct; importing at module top would follow PEP 8 without requiring the suppression.
- [ ] [2026-04-20 | "M107: TUI Stage Wiring: All Stages Instrumented"] `tui_stage_begin` is called before the `should_run_stage` check in the pipeline loop (line 2341 is before the `case` block, line 2502 `tui_stage_end` is after). When a user resumes with `--start-at review`, the coder, docs, and security pills will flash active→complete instantly with 0/0 turns, appearing as skipped rather than grayed-out. Cosmetically confusing for resume runs but harmless functionally. Scope gap; not required by M107 acceptance criteria.
- [ ] [2026-04-20 | "M106"] `get_stage_display_label`'s `*` fallback uses underscore-to-hyphen replacement (`${1//_/-}`) while `get_display_stage_order`'s `*` case passes internal names unmodified. A future stage added only to the pipeline order will produce different labels from each function until explicitly mapped in both.

## Resolved
