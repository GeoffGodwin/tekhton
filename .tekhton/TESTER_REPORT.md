## Planned Tests
- [x] `tests/test_mcp_resolve_provider_guard.sh` — Confirm guard unskips and passes (PROVIDER=codex skips probe; PROVIDER=claude allows it)
- [x] `tests/test_common_usage_threshold_guard.sh` — Confirm guard unskips and passes (PROVIDER=codex skips `claude usage`; disabled path still works)
- [ ] `tests/test_plan_batch_emit_tail.sh` — Unit tests for `_plan_batch_emit_tail`: extracts stdout_tail lines from response JSON, handles empty/missing inputs and escape sequences
- [ ] `tests/test_clear_commit_skip_sentinels.sh` — Unit tests for `_clear_commit_skip_sentinels`: removes sentinel files, returns 0 when absent, works with abs/rel TEKHTON_DIR

## Test Run Results
Passed: 0  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_mcp_resolve_provider_guard.sh`
- [x] `tests/test_common_usage_threshold_guard.sh`
- [ ] `tests/test_plan_batch_emit_tail.sh`
- [ ] `tests/test_clear_commit_skip_sentinels.sh`
