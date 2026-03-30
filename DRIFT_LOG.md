# Drift Log

## Metadata
- Last audit: 2026-03-30
- Runs since audit: 1

## Unresolved Observations
- [2026-03-30 | "architect audit"] **`lib/dashboard_parsers.sh:236–239` and shell fallback — duration estimation dead code (obs 1 and 3)** The observation is explicitly conditional: "worth a cleanup note *when `_STAGE_DURATION` coverage is confirmed complete*." That condition is not yet met. Current coverage of `_STAGE_DURATION`:
- [2026-03-30 | "architect audit"] **Populated:** `intake`, `scout`, `coder`, `security`, `reviewer`, `tester_write`, `tester`
- [2026-03-30 | "architect audit"] **Not populated:** `build_gate`, `architect`, `cleanup` The turn-proportional estimation fallback in `dashboard_parsers.sh:236–239` (Python) and lines `~326–336` (shell) exists for legacy JSONL records that predate per-stage duration tracking. It remains correct behavior for any run that did not emit `*_duration_s` fields. Removing it now would corrupt historical trend data. When `_STAGE_DURATION` coverage is confirmed complete (all active stages emit durations every run), re-open this as a dead code removal. At that point it is a two-block deletion with a corresponding test update in `test_duration_estimation_jsonl.sh` and `test_duration_estimation_shell_fallback.sh`. **Note:** `lib/finalize_summary.sh:153` and `lib/finalize_summary.sh:169` contain the same hardcoded stage list pattern as `metrics.sh:107` and also omit `tester_write`. This is a related staleness issue not reported in the current drift log. It can be bundled with the `metrics.sh` fix in the same jr coder pass since the files are adjacent and the fix is identical in structure.
(none)

## Resolved
- [RESOLVED 2026-03-30] Duration estimation fallback: `lib/dashboard_parsers.sh:236–239` and equivalent Python block use turns-per-stage as a proxy for time-per-stage. Becomes dead code when `_STAGE_DURATION` coverage is confirmed complete for all active stages.
- [RESOLVED 2026-03-30] Hardcoded stage list: `lib/metrics.sh:107` iterates over a hardcoded list to sum `_STAGE_DURATION`. Future stages would be silently missed. Consider `"${!_STAGE_DURATION[@]}"` loop when stage coverage is complete.
- [RESOLVED 2026-03-30] Awk syntax error in drift pruning: `test_drift_prune_realistic.sh` — platform-specific awk compatibility (gawk vs mawk) caused syntax error in `prune_resolved_entries`. Fixed by normalizing awk pattern.
- [RESOLVED 2026-03-30] Watchtower Trends average times: total_time_s was under-reported in JSONL metrics. Fixed metric recording; historical records will gradually be outweighed by correct new records.
