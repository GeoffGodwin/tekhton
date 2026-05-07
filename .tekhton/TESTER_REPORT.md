## Planned Tests
- [x] `internal/errors/classify_test.go` — ClassifyAll unmatched sentinel, FormatAllLegacy, empty input, noncode threshold boundary
- [x] `internal/errors/recovery_test.go` — All SuggestRecovery paths (14 uncovered pairs)
- [x] `internal/errors/agent_test.go` — IsKnownAgentSubcategory, capHead truncation via ClassifyAgent
- [x] `cmd/tekhton/diagnose_test.go` — --mode all, --mode filter-code, --mode annotate, --mode unknown (unknown exit 1)

## Test Run Results
Passed: 498 shell + all Go  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `internal/errors/classify_test.go`
- [x] `internal/errors/recovery_test.go`
- [x] `internal/errors/agent_test.go`
- [x] `cmd/tekhton/diagnose_test.go`
