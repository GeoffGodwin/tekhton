## Planned Tests
- [x] `internal/review/parser_test.go` — verify parser: fixture table (all 10 fixtures), RawBody round-trip, inline-fallback priority, None sentinel (case-sensitivity + optional dash/whitespace), ACP delimiter leniency, open error
- [x] `internal/review/cycle_test.go` — verify CycleBudget: Increment, Remaining (overrun→0), IsLastCycle, IsExhausted, BumpFromUsage (10-row table + receiver invariance)
- [x] `internal/review/specialist_test.go` — verify HasSpecialistBlockers (10 cases), FormatSpecialistSection bash-byte parity (4 shapes), RouteSpecialistRework (6 cases including overrun)

## Test Run Results
Passed: 35  Failed: 0

All 35 tests in `internal/review` pass. Coverage: 96.3% (≥85% required).
Full `internal/...` suite: 36 packages, all pass. No regression in `internal/intake/`.

Acceptance criteria verified:
- `parser.go`: exports `Report`, `Verdict`, `ACPVerdict`, `ParseReviewerReport`, plus 4 methods — confirmed via grep
- `cycle.go`: exports `CycleBudget` with 5 methods — confirmed via grep
- `specialist.go`: exports 3 functions — confirmed via grep
- `internal/stages/review/` does NOT exist — confirmed
- `stages/review.sh` and `stages/review_helpers.sh` remain untouched — confirmed
- No imports from `internal/orchestrate` or `internal/stagerunner` — confirmed via `go list -deps`
- `go vet ./internal/review/...` exits 0 — confirmed
- `gofmt -l internal/review/` returns empty — confirmed
- All 10 fixture files exist under `internal/review/testdata/` — confirmed

## Bugs Found
None

## Files Modified
- [x] `internal/review/parser_test.go`
- [x] `internal/review/cycle_test.go`
- [x] `internal/review/specialist_test.go`
