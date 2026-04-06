## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/indexer.sh` is 302 lines — 2 lines over the 300-line soft ceiling. The overage is a 5-line comment block (lines 298–302) that documents the extracted cache functions. Could be trimmed to a single pointer line if the ceiling is enforced strictly.
- `timing.sh` cosmetic edge case: when `REPO_MAP_CACHE_HITS=0` but `INDEXER_GENERATION_TIME_MS>0` (first run, no cache hits yet), the timing report line reads "Repo map: 1 generation + 0 cache hits (saved ~0s)". "0 cache hits" is grammatically odd. Consider guarding with `[[ "${_rmc_hits:-0}" -gt 0 ]]` so the line only appears when hits > 0.
- `_REVIEW_MAP_FILES` in `stages/review.sh` (line 41) is not declared `local` — it leaks as a global after `run_stage_review()` returns. No current consumer collides with this name, but follows the existing global-variable convention. Low risk.
- CODER_SUMMARY says "19 test cases" but there are 11 test groups with 18 total pass assertions. Minor documentation discrepancy only.

## Coverage Gaps
- No unit test for the timing.sh repo map stats section — the timing report is typically exercised via integration runs. Consider adding a test that exercises `_hook_emit_timing_report` with a non-zero `_REPO_MAP_CACHE_HITS` to cover the new branch.
- No test covers the review.sh cache invalidation heuristic (new files detected across review cycles). This would require mocking `extract_files_from_coder_summary` and `invalidate_repo_map_run_cache` — similar to the pattern in `test_coder_stage_split_wiring.sh`.

## Drift Observations
- `stages/review.sh:56` — `export REPO_MAP_CONTENT=""` uses `export` on a reassignment inside a function. The variable is already exported at module init in `indexer.sh`. Using `REPO_MAP_CONTENT=""` (without `export`) would suffice here and matches the pattern used elsewhere in the codebase. Not a correctness issue.
