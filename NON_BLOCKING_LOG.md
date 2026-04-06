# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-04-06 | "M61"] `lib/indexer.sh` is 302 lines — 2 lines over the 300-line soft ceiling. The overage is a 5-line comment block (lines 298–302) that documents the extracted cache functions. Could be trimmed to a single pointer line if the ceiling is enforced strictly.
- [ ] [2026-04-06 | "M61"] `timing.sh` cosmetic edge case: when `REPO_MAP_CACHE_HITS=0` but `INDEXER_GENERATION_TIME_MS>0` (first run, no cache hits yet), the timing report line reads "Repo map: 1 generation + 0 cache hits (saved ~0s)". "0 cache hits" is grammatically odd. Consider guarding with `[[ "${_rmc_hits:-0}" -gt 0 ]]` so the line only appears when hits > 0.
- [ ] [2026-04-06 | "M61"] `_REVIEW_MAP_FILES` in `stages/review.sh` (line 41) is not declared `local` — it leaks as a global after `run_stage_review()` returns. No current consumer collides with this name, but follows the existing global-variable convention. Low risk.
- [ ] [2026-04-06 | "M61"] CODER_SUMMARY says "19 test cases" but there are 11 test groups with 18 total pass assertions. Minor documentation discrepancy only.

(none)

## Resolved
