# Drift Log

## Metadata
- Last audit: 2026-03-31
- Runs since audit: 3

## Unresolved Observations
- [2026-04-01 | "Address all 8 open non-blocking notes in NON_BLOCKING_LOG.md. Fix each item and note what you changed."] `lib/finalize_summary.sh:128` — `grep -oP '"exit_code"s*:s*K[0-9]+'` uses Perl regex (`-oP`), the same portability class as the `grep -oP` fixed in `test_timing_report_generation.sh`. This pre-existing occurrence was not in scope here but is consistent drift.
- [2026-04-01 | "M46"] `stages/coder.sh:531–623`: The `context_assembly` phase encompasses both the build_context_packet call and prompt rendering. Sub-phase `coder_prompt` is nested inside it. The pattern of nested/overlapping phases is used here for the first time in the codebase — a brief comment in `timing.sh` explaining that phases may nest (and therefore percentages may not sum to 100%) would help future readers interpreting the report.
- [2026-04-01 | "Implement Milestones 44 a
nd then 45"] `_try_preflight_fix()` (`lib/orchestrate_helpers.sh:87,134`) counts failure lines via `grep -ciE '(FAIL|ERROR|error|failure)'` for the regression detection heuristic. The pattern matches lowercase "error" and "failure" literally, which can produce false-positive counts in test frameworks that print "0 errors" or "no failures found" in passing output. The core fix logic uses exit codes (correct), so this only affects the regression abort heuristic — not a correctness issue, but worth noting for future calibration.
- [2026-04-01 | "Implement Milestones 44 a
nd then 45"] Regression abort threshold is `initial_fail_count + 2` (`orchestrate_helpers.sh:135`). The magic constant `2` is undocumented. A comment explaining why +2 (allow slight variance in noisy grep counts) would improve maintainability.
- [2026-03-31 | "architect audit"] **OOS-1 — `grep -oP` PCRE mode in `stages/coder.sh:340–341`** The drift observation explicitly states: "No action needed now — existing pattern is accepted." GNU grep PCRE usage (`-oP`) is an established pattern already present at multiple sites in the codebase (confirmed at lines 115, 340, 341, 573 of `coder.sh`). The portability concern is valid only if macOS-native grep support becomes a stated goal. It is not a current goal. No remediation planned. **OOS-2 — Misleading comment at `tests/test_finalize_run.sh:415–418`** The comment described in the drift observation ("On failure: resolve_human_notes should NOT be called") does not exist in the current file. Lines 415–418 contain unrelated test suite 8 setup code. The accurate replacement comment is at lines 847–849: `# 15.6 removed: resolve_human_notes was eliminated in M42...`, which correctly explains the removal context and points to the live guard. The stated concern was already resolved before or during the triggering pipeline run. No further action required.
(none)

## Resolved
