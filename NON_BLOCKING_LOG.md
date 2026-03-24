# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-24 | "Implement Milestone 19: Distribution & Install Experience"] Prior cycle 1 blocker FIXED: `tekhton.sh:296` — `_TEKHTON_CLEAN_EXIT=true` is now correctly set before `exit 1` in the unsupported-shell case of `_setup_shell_completions`. Crash diagnostic box no longer fires on unsupported shell.
- [ ] [2026-03-24 | "Implement Milestone 19: Distribution & Install Experience"] `lib/finalize.sh:389` — `# shellcheck disable=SC2034` comment says "exit_code used by convention" but SC2034 is "assigned but unused" — `exit_code` is a local variable that is assigned `"$1"` and never read. The disable is correct in effect but the comment is misleading. Low priority: harmless.
- [ ] [2026-03-24 | "Implement Milestone 19: Distribution & Install Experience"] `tekhton.sh` — `--update`, `--uninstall`, and `--setup-completion` produce "Unknown flag" if passed after any other flag. This is consistent with the existing early-exit pattern for `--init`, `--plan`, etc., so not a regression — note for a future polish pass or docs.
- [ ] [2026-03-24 | "[BUG] The CLARIFICATIONS.md file structure is not working as intended. I just tried a bug fixing call of Tekhton with ` tekhton --complete "Implement fixes for all of the NON_BLOCKING_LOG items until they are all resolved."` and that resulted in the "Clarification Required" process kicking off in Task Intake. It asked for 4 clarifying questions then alleged to have answered them. If you check the CLARIFICATIONS.md file it generated you will see the answers are all nonsensical."] JR_CODER_SUMMARY.md is absent for this run (the archived version at `.claude/logs/archive/20260324_085104_JR_CODER_SUMMARY.md` contains Milestone 18 content, not this remediation). Changes were verified directly in source files. No impact on correctness.
- [ ] [2026-03-24 | "Implement Milestone 18: Documentation Site (MkDocs + GitHub Pages)"] `tests/test_docs_site.sh:260` — The first condition `grep -q '--docs' "$TEKHTON" | grep -q 'documentation' 2>/dev/null` pipes a quiet (no-output) grep into a second grep, making the second grep receive empty input and always fail. The test still passes because the `||` chain falls through to working alternatives, but the first clause is effectively dead code. Simplify to just the third clause: `grep '--docs' "$TEKHTON" | grep -q 'documentation'`.
- [ ] [2026-03-24 | "Implement Milestone 18: Documentation Site (MkDocs + GitHub Pages)"] `docs/guides/watchtower.md` — No screenshots present. The milestone's Watch For section explicitly called out that screenshots need to be generated from a real dashboard with sample data in `docs/assets/screenshots/`. The guide is textually complete but visual aids would improve it.

## Resolved
