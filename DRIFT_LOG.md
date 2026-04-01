# Drift Log

## Metadata
- Last audit: 2026-03-31
- Runs since audit: 5

## Unresolved Observations
- [2026-03-31 | "Implement M43 Test-Aware Coding"] `grep -oP` (PCRE mode) is used in `stages/coder.sh` lines 340–341 (M43 additions) and was already present at lines 115 and 573. This is GNU grep-specific and not POSIX. Shellcheck passes because SC2196/SC2197 are not flagged for `-P` under bash. No action needed now — existing pattern is accepted — but worth noting if portability to macOS-native grep ever becomes a goal.
- [2026-03-31 | "Address all 10 open non-blocking notes in NON_BLOCKING_LOG.md. Fix each item and note what you changed."] lib/notes_triage_flow.sh:60 — `PROMOTED_MILESTONE_ID=""` is declared as a module-level global variable rather than using `declare -g`; the pattern is inconsistent with how other module-level state is exposed across the codebase (minor naming/pattern drift)
- [2026-03-31 | "Address all 10 open non-blocking notes in NON_BLOCKING_LOG.md. Fix each item and note what you changed."] lib/notes_acceptance.sh:63–70 — `_new_files` combination appends `_staged_new` with an embedded newline via parameter expansion; if `git ls-files` output already ends with a trailing newline, `sort -u` will include an empty entry that must be guarded by `[[ -z "$newfile" ]] && continue` downstream — the guard exists and works, but the construction is fragile for future readers
- [2026-03-31 | "[BUG] The following tests now fail per the most recent changes: test_human_workflow.sh, test_human_mode_resolve_notes_edge.sh, test_finalize_run.sh. We should analyze if they still make sense and the code needs to be fixed, or if the code change is correct and the tests are no longer good tests."] `tests/test_finalize_run.sh:415–418` — The comment "On failure: resolve_human_notes should NOT be called" describes a constraint that is no longer meaningful (the function is simply absent from the code path). This comment was valid documentation pre-M42 but is now misleading. Minor cleanup opportunity.
(none)

## Resolved
