# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-04-06 | "M62"] `tests/test_m62_resume_cumulative_overcount.sh:206–208` — The comment on scenario 4 reads "cumulative report (first continuation)" and the inline comment says "fires 'accumulate' on a cumulative report". In the new delta-based contract, agents never write cumulative totals — the report in that scenario is a delta, same as any other continuation. The comment is stale and slightly misleading. Worth updating to say "delta report (first continuation, no prior replace)" to match the actual invariant.
- [ ] [2026-04-06 | "M62"] `lib/timing.sh:138` — The second condition in the sub-phase detection check (`[[ "$_spk" != "${_pfx%_}" ]]`) is dead code: any key that matches `build_gate_*` can never equal `build_gate`, so the first condition already excludes the parent. Harmless, but confusing on re-read.
- [ ] [2026-04-06 | "M62"] `lib/finalize_summary.sh:164` — The condition `[[ "${_TESTER_TIMING_EXEC_COUNT:--1}" != "" ]]` always evaluates to true (the `:-` default is `-1`, which is never empty), making the guard effectively `[[ "$_stg" == "tester" ]]`. The intent is clearly correct — emit fields for every tester stage with -1 as unavailable sentinel — but the condition is misleading. A comment clarifying the intent would help future readers.
- [ ] [2026-04-06 | "M62"] `stages/tester.sh:13-15` — `_TESTER_TIMING_WRITING_S` is not initialized alongside the other three timing globals. It's set at line 402 just before export, and `finalize_summary.sh` uses `${_TESTER_TIMING_WRITING_S:--1}` as a safe fallback, so there's no functional risk. Still worth initializing at declaration site for consistency.
- [ ] [2026-04-06 | "M61"] `lib/indexer.sh` is 302 lines — 2 lines over the 300-line soft ceiling. The overage is a 5-line comment block (lines 298–302) that documents the extracted cache functions. Could be trimmed to a single pointer line if the ceiling is enforced strictly.
- [ ] [2026-04-06 | "M61"] `timing.sh` cosmetic edge case: when `REPO_MAP_CACHE_HITS=0` but `INDEXER_GENERATION_TIME_MS>0` (first run, no cache hits yet), the timing report line reads "Repo map: 1 generation + 0 cache hits (saved ~0s)". "0 cache hits" is grammatically odd. Consider guarding with `[[ "${_rmc_hits:-0}" -gt 0 ]]` so the line only appears when hits > 0.
- [ ] [2026-04-06 | "M61"] `_REVIEW_MAP_FILES` in `stages/review.sh` (line 41) is not declared `local` — it leaks as a global after `run_stage_review()` returns. No current consumer collides with this name, but follows the existing global-variable convention. Low risk.
- [ ] [2026-04-06 | "M61"] CODER_SUMMARY says "19 test cases" but there are 11 test groups with 18 total pass assertions. Minor documentation discrepancy only.

## Resolved
