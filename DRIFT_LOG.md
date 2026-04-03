# Drift Log

## Metadata
- Last audit: 2026-04-03
- Runs since audit: 1

## Unresolved Observations
(none)

## Resolved
- [RESOLVED 2026-04-03] `lib/gates.sh` Phase 4 (UI test path) does not write `BUILD_RAW_ERRORS.txt`. When UI tests fail with non-code errors, `coder.sh` falls back to `BUILD_ERRORS.md` (annotated markdown), which causes `has_only_noncode_errors` to return 1 (markdown headers produce unclassified→code fallback), preventing bypass. Phase 4 has auto-remediation for `env_setup` issues but not the full bypass routing that Phases 1–2 provide. This is intentionally documented as a known limitation in `test_gates_bypass_flow.sh` (Test 2). Candidate for M54 improvement.
- [RESOLVED 2026-04-03] `classify_build_error` (single-line semantics, first-match on full multi-line input) and `classify_build_errors_all` (per-line with dedup) serve different purposes but are easily confused. Phase 4 auto-remediation uses `classify_build_error` on the full UI test output — this works in practice because env_setup patterns (e.g., "npx playwright install") appear early in playwright output, but the inconsistency could mislead future maintainers.
