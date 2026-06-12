## Planned Tests
- [x] `tests/test_mcp_resolve_provider_guard.sh` — Fix test B (inert assertion → real fail if claude not invoked when PROVIDER=claude); add B2 return-code assertion
- [x] `tests/test_common_usage_threshold_guard.sh` — Re-stub log functions post-source; add test D (positive-path: PROVIDER=claude, threshold=50, 99% usage → invoked + returns 1)
- [x] `tests/test_plan_batch_emit_tail.sh` — Add case G: empty stdout_tail array produces no output and returns 0
- [x] `tests/test_plan_batch_label_routing.sh` — New test: _call_planning_batch passes label arg to _shim_write_request for all planning labels

## Test Run Results
Passed: 503  Failed: 1

## Bugs Found
- BUG: [lib/plan_batch.sh:165] `_plan_batch_emit_tail` awk does not handle inline empty array `"stdout_tail": []` — the `\[` pattern matches and sets `in_tail=1; next`, skipping past the closing `]` on the same line so `in_tail` is never cleared; the next line (`}`) is then emitted as output instead of nothing; test G in test_plan_batch_emit_tail.sh fails with `output=\}`

## Files Modified
- [x] `tests/test_mcp_resolve_provider_guard.sh`
- [x] `tests/test_common_usage_threshold_guard.sh`
- [x] `tests/test_plan_batch_emit_tail.sh`
- [x] `tests/test_plan_batch_label_routing.sh`

## Timing
- Test executions: 4
- Approximate total test execution time: 120s
- Test files written: 1
