## Planned Tests
- [x] `tests/test_plan_batch_provider_boundary.sh` — shim-boundary: PROVIDER=codex routes through tekhton supervise; lib/plan_batch.sh has no raw claude call (Goals 1, 4)
- [x] `tests/test_audit_raw_claude.sh` — audit gate catches all 3 raw-claude forms; exits 0 on clean tree; quota_probe.sh allowlisted (Goal 3)
- [x] `tests/test_mcp_resolve_provider_guard.sh` — _cli_supports_mcp_config skips probe + logs when claude not in provider spec (Goal 2)
- [x] `tests/test_common_usage_threshold_guard.sh` — check_usage_threshold skips claude usage invocation when PROVIDER excludes claude (Goal 2)

## Test Run Results
Passed: 2  Failed: 5

(2 passing: test_mcp_resolve_provider_guard.sh assertion B, test_common_usage_threshold_guard.sh assertion C.
 5 failing: test_plan_batch_provider_boundary.sh A; test_audit_raw_claude.sh existence; test_mcp_resolve_provider_guard.sh A; test_common_usage_threshold_guard.sh A and B — all due to m20 not yet implemented.)

## Bugs Found
- BUG: [lib/plan_batch.sh:88] raw `claude \` invocation in command position — _call_planning_batch does not route through tekhton supervise (Goal 1 absent)
- BUG: [scripts/audit-raw-claude.sh] file does not exist — audit gate for raw claude invocations not created (Goal 3 absent)
- BUG: [lib/mcp_resolve.sh:158] _cli_supports_mcp_config() calls `claude --help` unconditionally; PROVIDER spec guard absent (Goal 2 absent)
- BUG: [lib/common.sh:175] check_usage_threshold() calls `claude usage` unconditionally; PROVIDER spec guard absent (Goal 2 absent)

## Files Modified
- [x] `tests/test_plan_batch_provider_boundary.sh`
- [x] `tests/test_audit_raw_claude.sh`
- [x] `tests/test_mcp_resolve_provider_guard.sh`
- [x] `tests/test_common_usage_threshold_guard.sh`

## Timing
- Test executions: 5
- Approximate total test execution time: 20s
- Test files written: 4
