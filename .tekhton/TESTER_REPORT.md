## Planned Tests
- [x] `internal/runner/provider_chain_test.go` — update TestChain_RunAgent_EmptyProviders to assert EMPTY_CHAIN guard (Goal 4)
- [ ] `internal/runner/supervise_bridge_test.go` — SKIPPED: supervise_bridge.go does not exist; implementation absent
- [ ] `cmd/tekhton/supervise_test.go` — SKIPPED: Provider field not in AgentRequestV1; provider routing not implemented
- [x] `tests/test_supervise_provider_boundary.sh` — shim-boundary: fake codex binary invoked, claude PATH-shim never fires (Goal 5)

## Test Run Results
Passed: 1  Failed: 7

(1 passing: test_supervise_provider_boundary.sh assertion E — envelope format valid.
 1 failing Go: TestChain_RunAgent_EmptyProviders — EMPTY_CHAIN guard missing.
 6 failing bash: test_supervise_provider_boundary.sh assertions A/B/B2/C/C2/D — m19 not implemented.)

## Bugs Found
- BUG: [internal/runner/provider_chain.go:RunAgent] empty chain returns (nil,nil) instead of EMPTY_CHAIN result+error (Goal 4 guard absent)
- BUG: [cmd/tekhton/supervise.go:67] supervisor.New(nil,nil) hardcoded; PROVIDER env and envelope provider field ignored (Goal 2 absent)
- BUG: [cmd/tekhton/run_stage.go:76] claude.New(supervisor.New(nil,nil)) hardcoded; per-stage ResolveProvider not implemented (Goal 3 absent)
- BUG: [internal/tester/tdd/tdd.go:123] supervisor.New direct construction; injected provider interface not yet wired (Goal 3 absent)
- BUG: [internal/test_audit/audit.go:87] supervisor.New direct construction; injected provider interface not yet wired (Goal 3 absent)
- BUG: [internal/proto/agent_v1.go:AgentRequestV1] Provider string field absent; json:"provider,omitempty" not added (Goal 1 absent)

## Files Modified
- [x] `internal/runner/provider_chain_test.go`
- [ ] `internal/runner/supervise_bridge_test.go`
- [ ] `cmd/tekhton/supervise_test.go`
- [x] `tests/test_supervise_provider_boundary.sh`

## Timing
- Test executions: 6
- Approximate total test execution time: 75s
- Test files written: 2
