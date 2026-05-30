## Planned Tests
- [x] `internal/detect/detect_test.go` — engine invariants (languages-first, error propagation, cache reset, Summary.ProjectType fallback)
- [x] `internal/detect/languages_test.go` — LanguagesDetector happy paths, confidence scoring, framework detection, CLAUDE.md fallback
- [x] `internal/detect/report_test.go` — Render() markdown shape matches bash baseline format
- [x] `internal/detect/readonly_test.go` — package read-only contract (no forbidden write APIs)
- [x] `cmd/tekhton/detect_test.go` — CLI smoke tests (help, --json shape, --markdown default, mutual-exclusion guard)
- [x] `tests/test_detect_parity.sh` — byte-identical parity gate across three fixtures

## Test Run Results
Passed: 25  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `internal/detect/detect_test.go`
- [x] `internal/detect/languages_test.go`
- [x] `internal/detect/report_test.go`
- [x] `internal/detect/readonly_test.go`
- [x] `cmd/tekhton/detect_test.go`
- [x] `tests/test_detect_parity.sh`
