# Reviewer Report — M135: Resilience Arc Artifact Lifecycle Management

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `tests/test_ensure_gitignore_entries.sh:72` — Section comment says "All 18 Tekhton runtime patterns" but the `EXPECTED_ENTRIES` array now has 20 entries. Stale count.
- `tests/resilience_arc_fixtures.sh:88-109` — Security agent LOW: `_arc_write_v2_failure_context` and `_arc_write_v1_failure_context` interpolate shell variables directly into JSON heredocs without escaping. No current exploit path (all callers use hardcoded literals), but a `_json_escape` helper guard would prevent future misuse.

## Coverage Gaps
- No test verifies that `_trim_preflight_bak_dir` is actually invoked from the preflight flow. Tests S8.T6–T9 cover the function in isolation but not the integration: the coder's claim that "m131's existing `declare -f` guard automatically activates the trim" is untested here. A scenario that runs `_preflight_check_ui_test_config` on a dir with more than N backups and then asserts the bak dir was trimmed would close this gap.

## Drift Observations
- `lib/preflight_checks.sh:247-250` — `find | sort | head | xargs rm -f` is fragile for filenames containing spaces or newlines. In practice, m131's `YYYYMMDD_HHMMSS_<name>` prefix makes this safe for all current callers, but `find -exec rm -f {} +` would be more robust if the bak dir naming convention ever changes.

---

### Review Notes

**Goal 1 (`PREFLIGHT_BAK_DIR` registration):** The `${PROJECT_DIR:+...}` form is the correct deviation from the design's literal `:=` form. Baking the path at source time from an inherited `PROJECT_DIR` would produce the wrong value inside the test harness (and any other early-source context). The deviation rationale is sound and documented.

**Goal 2 (`.gitignore` entries):** Both `.tekhton/BUILD_FIX_REPORT.md` and `.claude/preflight_bak/` are present in the `_gi_entries` array and covered by updated assertions in `test_ensure_gitignore_entries.sh`. Idempotency guards are intact.

**Goal 3 (`_clear_arc_artifacts_on_success`):** Placement in `finalize_summary_collectors.sh` is the correct resolution for the 300-line ceiling (file would have gone 287 → 302 lines). The call site in `_hook_emit_run_summary` on the success branch is correct. Path construction — `"${_p}/${BUILD_FIX_REPORT_FILE:-.tekhton/BUILD_FIX_REPORT.md}"` — is consistent with the relative-path contract in `artifact_defaults.sh` and matches how S8.T4 sets up its fixture.

**Goal 4 (`_trim_preflight_bak_dir`):** The function is correct. `(( retain == 0 ))` disables trimming; `(( total <= retain ))` short-circuits when no deletion is needed; lexicographic sort equals chronological order because the `YYYYMMDD_HHMMSS_` prefix is left-padded. The `wc -l | tr -d '[:space:]'` idiom matches `count_lines` in `common.sh`. Coverage gap noted above is the only concern.

**Test hermeticity fix (`unset PROJECT_DIR PREFLIGHT_BAK_DIR`):** Correct and necessary. Without it the test inherits the caller's `PROJECT_DIR` and bakes the wrong `PREFLIGHT_BAK_DIR` at `common.sh` source time — the exact scenario the `:=` change introduced.

**File sizes:** All modified files are under the 300-line ceiling: `common.sh` 251, `finalize_summary.sh` 290, `finalize_summary_collectors.sh` 191, `preflight_checks.sh` 254. `artifact_defaults.sh` at 58 lines is exempt as a data-only file.
