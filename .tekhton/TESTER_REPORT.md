## Planned Tests
- [ ] `internal/runner/provider_chain_test.go` — update TestChain_RunAgent_EmptyProviders to assert EMPTY_CHAIN guard (Goal 4)
- [ ] `internal/runner/supervise_bridge_test.go` — new: label sanitization + claude retry parity + RunProtoRequest mapping (Goal 2)
- [ ] `cmd/tekhton/supervise_test.go` — add PROVIDER env routing + unknown-provider exitUsage + empty-label fallback tests (Goal 2 AC)
- [ ] `tests/test_supervise_provider_boundary.sh` — shim-boundary: fake codex binary invoked, claude PATH-shim never fires (Goal 5)

## Test Run Results
Passed: 0  Failed: 0

## Bugs Found
None

## Files Modified
- [ ] `internal/runner/provider_chain_test.go`
- [ ] `internal/runner/supervise_bridge_test.go`
- [ ] `cmd/tekhton/supervise_test.go`
- [ ] `tests/test_supervise_provider_boundary.sh`
