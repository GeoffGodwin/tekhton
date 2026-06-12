## Planned Tests
- [x] `tests/test_mcp_resolve_provider_guard.sh` — Confirm guard unskips and passes (PROVIDER=codex skips probe; PROVIDER=claude allows it)
- [x] `tests/test_common_usage_threshold_guard.sh` — Confirm guard unskips and passes (PROVIDER=codex skips `claude usage`; disabled path still works)
- [x] `tests/test_plan_batch_emit_tail.sh` — Unit tests for `_plan_batch_emit_tail`: extracts stdout_tail lines from response JSON, handles empty/missing inputs and escape sequences
- [x] `tests/test_clear_commit_skip_sentinels.sh` — Unit tests for `_clear_commit_skip_sentinels`: removes sentinel files, returns 0 when absent, works with abs/rel TEKHTON_DIR

## Test Run Results
Passed: 471  Failed: 1

## Bugs Found
- BUG: [scripts/audit-raw-claude.sh:67] script ignores positional arguments — `_resolve_targets()` always scans `lib/`, `stages/`, `tekhton.sh`; `test_audit_raw_claude.sh` passes target paths via argv expecting per-file scanning, so fixture tests (cases 1–8) all scan the real repo instead of the synthetic temp files
- BUG: [lib/common.sh:180] `usage_output=$(claude usage 2>/dev/null || true)` is a raw claude invocation not routed through `tekhton supervise` and not in the audit allowlist — `scripts/audit-raw-claude.sh` correctly flags it, causing the "full lib/ scan exits 0" assertion in `test_audit_raw_claude.sh` to fail

## Files Modified
- [x] `tests/test_mcp_resolve_provider_guard.sh`
- [x] `tests/test_common_usage_threshold_guard.sh`
- [x] `tests/test_plan_batch_emit_tail.sh`
- [x] `tests/test_clear_commit_skip_sentinels.sh`

## Timing
- Test executions: 8
- Approximate total test execution time: 180s
- Test files written: 2
