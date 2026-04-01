# Drift Log

## Metadata
- Last audit: 2026-04-01
- Runs since audit: 3

## Unresolved Observations
- [2026-04-01 | "Address all 4 open non-blocking notes in NON_BLOCKING_LOG.md. Fix each item and note what you changed."] `lib/drift_cleanup.sh:219` — `echo "$line" | grep -qi "^- [x]"` for the skip-in-open branch is inconsistent with the awk-based `[x]` detection used everywhere else in the same file (lines 182, 190, 243). The `echo | grep` pattern also carries a latent risk if `$line` ever starts with `-e` or `-n`. The existing `_resolve_addressed_nonblocking_notes()` at line 136 uses the same pattern, so this is a pre-existing drift, not introduced here — still worth a consolidation pass.
- [2026-04-01 | "M49"] `lib/run_memory.sh:281–285` — field extraction from JSONL uses `grep -oP` rather than a shared JSONL parsing helper. `lib/causality.sh` may already have related extraction patterns; if a future milestone adds more JSONL consumers, consolidating the parse logic into a helper would reduce duplication.
- [2026-04-01 | "M48"] None.
nd then 45"] `_try_preflight_fix()` (`lib/orchestrate_helpers.sh:87,134`) counts failure lines via `grep -ciE '(FAIL|ERROR|error|failure)'` for the regression detection heuristic. The pattern matches lowercase "error" and "failure" literally, which can produce false-positive counts in test frameworks that print "0 errors" or "no failures found" in passing output. The core fix logic uses exit codes (correct), so this only affects the regression abort heuristic — not a correctness issue, but worth noting for future calibration.
nd then 45"] Regression abort threshold is `initial_fail_count + 2` (`orchestrate_helpers.sh:135`). The magic constant `2` is undocumented. A comment explaining why +2 (allow slight variance in noisy grep counts) would improve maintainability.
(none)

## Resolved
