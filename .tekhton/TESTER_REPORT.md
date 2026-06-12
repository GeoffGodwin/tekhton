## Planned Tests
- [ ] `tests/test_mcp_resolve_provider_guard.sh` — Fix test B (inert assertion → real fail if claude not invoked when PROVIDER=claude); add B2 return-code assertion
- [ ] `tests/test_common_usage_threshold_guard.sh` — Re-stub log functions post-source; add test D (positive-path: PROVIDER=claude, threshold=50, 99% usage → invoked + returns 1)
- [ ] `tests/test_plan_batch_emit_tail.sh` — Add case G: empty stdout_tail array produces no output and returns 0
- [ ] `tests/test_plan_batch_label_routing.sh` — New test: _call_planning_batch passes label arg to _shim_write_request for all planning labels

## Test Run Results
Passed: 0  Failed: 0

## Bugs Found
None

## Files Modified
- [ ] `tests/test_mcp_resolve_provider_guard.sh`
- [ ] `tests/test_common_usage_threshold_guard.sh`
- [ ] `tests/test_plan_batch_emit_tail.sh`
- [ ] `tests/test_plan_batch_label_routing.sh`
