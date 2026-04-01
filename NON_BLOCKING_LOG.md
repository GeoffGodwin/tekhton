# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-04-01 | "M46"] `lib/timing.sh` & `stages/coder.sh`: `context_assembly` and `coder_prompt` are nested phases (coder_prompt starts/ends inside context_assembly). Both appear in TIMING_REPORT.md with independent durations, causing the sum of all phase percentages to slightly exceed 100% in production runs. Not a correctness bug — timing is accurate — but the report header could note this to avoid user confusion.
- [ ] [2026-04-01 | "M46"] `lib/timing.sh:64`: `build_gate_constraints` is listed in `_phase_display_name()` but `gates.sh` never calls `_phase_start "build_gate_constraints"` — the constraint validation phase is unmetered. The display name entry is forward-compatible dead code for now. Consider either instrumenting the constraint phase or removing the dead entry.
- [ ] [2026-04-01 | "M46"] `tests/test_timing_report_generation.sh:101`: Uses `grep -oP` (Perl regex). This is fine on Linux/WSL2 but would fail on macOS BSD grep. Low risk given the Linux-only deployment context, but worth noting for any future macOS contributors.
- [ ] [2026-04-01 | "Implement Milestones 44 a
nd then 45"] `CODER_SUMMARY.md` "Files Modified" section lists only `CODER_SUMMARY.md` but git status shows many staged files (`lib/config_defaults.sh`, `lib/orchestrate.sh`, `lib/orchestrate_helpers.sh`, `stages/coder.sh`, plus 4 untracked new files). Accurate file lists help the reviewer gate and the drift system. Future coder runs should enumerate all files changed in the session.
- [ ] [2026-04-01 | "Implement Milestones 44 a
nd then 45"] `m44-jr-coder-test-fix-gate.md` has stale `status: "pending"` in its `<!-- milestone-meta -->` comment while `MANIFEST.cfg` correctly shows `done`. MANIFEST is authoritative so there is no behavior impact, but the stale inline metadata is confusing.
- [ ] [2026-03-31 | "Implement M43 Test-Aware Coding"] `stages/coder.sh` uses `declare -f has_test_baseline` to guard the baseline summary block, while `lib/finalize_summary.sh` and `lib/milestone_acceptance.sh` use `command -v has_test_baseline` for the same guard. Both forms work correctly for shell functions, but the codebase is inconsistent. `declare -f` is slightly more correct (only matches functions, not executables), but this is cosmetic — no behavior difference in practice.
- [ ] [2026-03-31 | "Implement M43 Test-Aware Coding"] `tests/test_m43_test_aware.sh` duplicates the `_extract_affected_test_files` and `_build_test_baseline_summary` logic inline rather than sourcing `stages/coder.sh`. This is consistent with the existing test style in the project (tests avoid sourcing complex stage files to reduce coupling), but means a logic drift between test fixtures and production code won't be caught by the test. Acceptable tradeoff given the test does validate the actual prompt files directly in Suite 3.
- [ ] [2026-03-31 | "M43"] `tests/test_m43_test_aware.sh` duplicates the awk extraction logic and baseline-parsing logic as inline helpers (`_extract_affected_test_files`, `_build_test_baseline_summary`) rather than sourcing them from `stages/coder.sh`. If the logic in `coder.sh` changes, the tests won't catch the regression. Acceptable for now but worth migrating if the extraction logic grows.

## Resolved
