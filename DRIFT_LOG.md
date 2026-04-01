# Drift Log

## Metadata
- Last audit: 2026-03-31
- Runs since audit: 1

## Unresolved Observations
- [2026-04-01 | "Implement Milestones 44 a
nd then 45"] `_try_preflight_fix()` (`lib/orchestrate_helpers.sh:87,134`) counts failure lines via `grep -ciE '(FAIL|ERROR|error|failure)'` for the regression detection heuristic. The pattern matches lowercase "error" and "failure" literally, which can produce false-positive counts in test frameworks that print "0 errors" or "no failures found" in passing output. The core fix logic uses exit codes (correct), so this only affects the regression abort heuristic — not a correctness issue, but worth noting for future calibration.
- [2026-04-01 | "Implement Milestones 44 a
nd then 45"] Regression abort threshold is `initial_fail_count + 2` (`orchestrate_helpers.sh:135`). The magic constant `2` is undocumented. A comment explaining why +2 (allow slight variance in noisy grep counts) would improve maintainability.
- [2026-03-31 | "architect audit"] **OOS-1 — `grep -oP` PCRE mode in `stages/coder.sh:340–341`** The drift observation explicitly states: "No action needed now — existing pattern is accepted." GNU grep PCRE usage (`-oP`) is an established pattern already present at multiple sites in the codebase (confirmed at lines 115, 340, 341, 573 of `coder.sh`). The portability concern is valid only if macOS-native grep support becomes a stated goal. It is not a current goal. No remediation planned. **OOS-2 — Misleading comment at `tests/test_finalize_run.sh:415–418`** The comment described in the drift observation ("On failure: resolve_human_notes should NOT be called") does not exist in the current file. Lines 415–418 contain unrelated test suite 8 setup code. The accurate replacement comment is at lines 847–849: `# 15.6 removed: resolve_human_notes was eliminated in M42...`, which correctly explains the removal context and points to the live guard. The stated concern was already resolved before or during the triggering pipeline run. No further action required.
(none)

## Resolved
- [RESOLVED 2026-03-31] `grep -oP` (PCRE mode) is used in `stages/coder.sh` lines 340–341 (M43 additions) and was already present at lines 115 and 573. This is GNU grep-specific and not POSIX. Shellcheck passes because SC2196/SC2197 are not flagged for `-P` under bash. No action needed now — existing pattern is accepted — but worth noting if portability to macOS-native grep ever becomes a goal.
- [RESOLVED 2026-03-31] lib/notes_triage_flow.sh:60 — `PROMOTED_MILESTONE_ID=""` is declared as a module-level global variable rather than using `declare -g`; the pattern is inconsistent with how other module-level state is exposed across the codebase (minor naming/pattern drift)
- [RESOLVED 2026-03-31] lib/notes_acceptance.sh:63–70 — `_new_files` combination appends `_staged_new` with an embedded newline via parameter expansion; if `git ls-files` output already ends with a trailing newline, `sort -u` will include an empty entry that must be guarded by `[[ -z "$newfile" ]] && continue` downstream — the guard exists and works, but the construction is fragile for future readers
- [RESOLVED 2026-03-31] The following tests now fail per the most recent changes: test_human_workflow.sh, test_human_mode_resolve_notes_edge.sh, test_finalize_run.sh. We should analyze if they still make sense and the code needs to be fixed, or if the code change is correct and the tests are no longer good tests."] `tests/test_finalize_run.sh:415–418` — The comment "On failure: resolve_human_notes should NOT be called" describes a constraint that is no longer meaningful (the function is simply absent from the code path). This comment was valid documentation pre-M42 but is now misleading. Minor cleanup opportunity.
