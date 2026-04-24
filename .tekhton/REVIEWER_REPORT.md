# Reviewer Report — M125: Quota Pause Refresh Accuracy & Probe Budget

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `tests/test_quota.sh:396` — The "Config defaults" test block asserts `QUOTA_MAX_PAUSE_DURATION is 14400` (the old value), but the actual new default from `config_defaults.sh` is `18900`. The assertion passes only because the test primes the variable to `14400` at lines 44, 360, and 383. The assertion label is now factually wrong and will mislead anyone reading the test. Fix: update the assertion to `18900` and remove the manual override where it shadows the real default, or rename the block to clarify it is testing "module compatibility with a custom value", not the canonical default.
- `_extract_retry_after_seconds` is inlined verbatim in `tests/test_quota.sh` (lines 412–431) and `tests/test_quota_retry_after_integration.sh` (lines 56–75) to avoid pulling in the full agent monitoring stack. If the canonical definition in `lib/agent_retry.sh` ever diverges, both test copies silently go stale. Consider extracting to a shared test helper sourced by both test files.

## Coverage Gaps
- No test exercises the fallback-mode throttle path inside `_quota_probe` where `_QUOTA_PROBE_LAST_TS` causes the probe to skip the expensive call and return 1 immediately (the "min-interval not yet elapsed" branch at `quota_probe.sh:76-79`).
- No test verifies that `_QUOTA_PROBE_MODE` is reused (not re-detected) on a second `enter_quota_pause` call within the same pipeline session, confirming the `[[ -n "$_QUOTA_PROBE_MODE" ]] && return 0` early-exit in `_quota_detect_probe_mode` is actually hit.

## ACP Verdicts
None — no Architecture Change Proposals in CODER_SUMMARY.md.

## Drift Observations
- `lib/config_defaults.sh` is 621 lines, more than double the 300-line ceiling stated in the reviewer checklist. The file contains no logic (only `:=` default assignments and `_clamp_config_value` calls), so it is arguably a data file rather than a code file. However, there is no explicit carve-out for it in CLAUDE.md. As the file continues to grow each milestone, this gap should be acknowledged — either document `config_defaults.sh` as exempt from the ceiling, or plan a split (e.g., quota-related defaults into their own file).
