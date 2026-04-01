# Reviewer Report

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- lib/notes_triage_flow.sh is 328 lines — 28 lines over the 300-line ceiling; log for the next cleanup pass
- lib/notes_acceptance.sh is 308 lines — 8 lines over the 300-line ceiling; log for the next cleanup pass
- tests/test_finalize_run.sh:428 — `assert "8.2 ..." "0"` passes a hardcoded literal "0"; the test relies on `set -euo pipefail` to catch a crash, which works, but the assert itself is vacuous and adds no diagnostic value if the behavior regresses silently
- lib/notes_acceptance.sh:279 — `local _msg="${w#*: }"` inside the second while loop (the CODER_SUMMARY.md append block) was not hoisted; the primary fix moved `_code`/`_msg` in the first loop, but this second `local` inside a while loop remains; not a shellcheck SC2155 hit (parameter expansion, not command substitution), but worth keeping consistent
- tests/test_human_workflow.sh:779 — assert message reads "Bulk resolution marks [x]" while the enclosing `test_case` describes the "orphan safety net"; the two descriptions are inconsistent and could confuse future readers

## Coverage Gaps
- None

## Drift Observations
- lib/notes_triage_flow.sh:60 — `PROMOTED_MILESTONE_ID=""` is declared as a module-level global variable rather than using `declare -g`; the pattern is inconsistent with how other module-level state is exposed across the codebase (minor naming/pattern drift)
- lib/notes_acceptance.sh:63–70 — `_new_files` combination appends `_staged_new` with an embedded newline via parameter expansion; if `git ls-files` output already ends with a trailing newline, `sort -u` will include an empty entry that must be guarded by `[[ -z "$newfile" ]] && continue` downstream — the guard exists and works, but the construction is fragile for future readers
