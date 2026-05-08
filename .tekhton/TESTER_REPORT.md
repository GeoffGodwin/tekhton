## Planned Tests
- [x] `internal/errors/classify_test.go` — table-driven cases for pnpm notice and yarn notice in IsNonDiagnosticLine (including allow-list precedence and case-insensitive variants)
- [x] `internal/config/config_test.go` — applyLateDefaults empty-slice fast path and non-empty path (verifies the guard is tested before lateDefaults is ever populated)

## Test Run Results
Passed: 16  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `internal/errors/classify_test.go`
- [x] `internal/config/config_test.go`
