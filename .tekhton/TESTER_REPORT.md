## Planned Tests
- [x] `internal/drift/observe_test.go` — add AppendEntries (0% coverage), ShouldTriggerAudit runs-threshold path, ResolveObservations dedup guard, ResetRunsSinceAudit missing-file, ClearResolved empty section, GetResolved missing-file
- [x] `internal/drift/router_test.go` — add Disposition.String() coverage (was 0%), standalone nit-pattern test
- [x] `internal/drift/prune_test.go` — add appendArchive with existing archive, Prune without archive path
- [x] `internal/drift/artifacts_test.go` — add ADR.EnsureFile idempotent, parseACPLine no-ACP-prefix branch, ConsolidateLegacy when canonical missing, HumanAction.CountUnchecked on missing file
- [x] `internal/drift/nonblocking_test.go` — add EnsureFile repairs missing Resolved, AppendNotes empty-input no-create
- [x] `internal/clarify/handle_test.go` — add HandleInteractive missing-path error, ClearStaleEntries empty-file, PollUntilAnswered nil-items

## Test Run Results
Passed: 386 (Go) + 486 (Shell)  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `internal/drift/observe_test.go`
- [x] `internal/drift/router_test.go`
- [x] `internal/drift/prune_test.go`
- [x] `internal/drift/artifacts_test.go`
- [x] `internal/drift/nonblocking_test.go`
- [x] `internal/clarify/handle_test.go`
