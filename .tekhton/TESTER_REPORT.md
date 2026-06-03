## Planned Tests
- [x] `internal/security/severity_test.go` — rank table + threshold predicate: 4×4 known pairs, 8 unknown-input pairs, 4 case-sensitive pairs
- [x] `internal/security/findings_test.go` — ParseReport: 6 fixtures + missing/malformed cases; IsDocsOnly: full allowlist smoke-test
- [x] `internal/security/blocks_test.go` — 18 golden-file parity baselines (6 fixtures × 3 block kinds) + threshold + unfixable/notes logic
- [x] `internal/security/escalation_test.go` — 4 policy branches (escalate/halt/waiver/unknown) + empty-block short-circuit + error propagation + real drift.HumanAction write
- [x] `cmd/tekhton/security_test.go` — 5 Hidden subcommand registration, TSV/JSON format, subprocess exit-code contracts (meets-threshold, is-docs-only, handle-unfixable)
- [x] `internal/stages/security/coverage_test.go` — writePromptTmpFile error paths, resolveTekhtonBin fallback chain (TEKHTON_HOME/bin and LookPath), writeHaltState with store.Update failure and milestone mode, humanActionFile relative path, subprocessBuildGate.Run, RunStage scan_failed via CreateTemp error

## Test Run Results
Passed: 514 (all internal/... packages, security stage: 88.9% coverage)  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `internal/security/severity_test.go`
- [x] `internal/security/findings_test.go`
- [x] `internal/security/blocks_test.go`
- [x] `internal/security/escalation_test.go`
- [x] `cmd/tekhton/security_test.go`
- [x] `internal/stages/security/coverage_test.go`
