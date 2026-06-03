## Planned Tests
- [x] `internal/security/severity_test.go` — rank table + threshold predicate: 4×4 known pairs, 8 unknown-input pairs, 4 case-sensitive pairs
- [x] `internal/security/findings_test.go` — ParseReport: 6 fixtures + missing/malformed cases; IsDocsOnly: full allowlist smoke-test
- [x] `internal/security/blocks_test.go` — 18 golden-file parity baselines (6 fixtures × 3 block kinds) + threshold + unfixable/notes logic
- [x] `internal/security/escalation_test.go` — 4 policy branches (escalate/halt/waiver/unknown) + empty-block short-circuit + error propagation + real drift.HumanAction write
- [x] `cmd/tekhton/security_test.go` — 5 Hidden subcommand registration, TSV/JSON format, subprocess exit-code contracts (meets-threshold, is-docs-only, handle-unfixable)
- [x] `internal/stages/security/coverage_test.go` — writePromptTmpFile error paths, resolveTekhtonBin fallback chain (TEKHTON_HOME/bin and LookPath), writeHaltState with store.Update failure and milestone mode, humanActionFile relative path, subprocessBuildGate.Run, RunStage scan_failed via CreateTemp error
- [x] `tests/test_wedge_audit_m35.sh` — 6-scenario regression: clean baseline exits 0, file-presence bans (stages/security.sh, lib/security_helpers.sh) exit 1 and name path, deleted-function-name ban exits 1, --m35-allowlist marker honored, post-cleanup exits 0
- [x] `tests/test_security_parity.sh` — 3-scenario end-to-end parity gate (pass-no-findings, fixable-cycle-1-resolved, unfixable-escalate) diffing stdout.json + SECURITY_NOTES.md + HUMAN_ACTION_REQUIRED.md against baselines after timestamp/path normalization

## Test Run Results
Passed: 502 shell + all Go packages (m35.3 verification run)  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `internal/security/severity_test.go`
- [x] `internal/security/findings_test.go`
- [x] `internal/security/blocks_test.go`
- [x] `internal/security/escalation_test.go`
- [x] `cmd/tekhton/security_test.go`
- [x] `internal/stages/security/coverage_test.go`
- [x] `tests/test_wedge_audit_m35.sh`
- [x] `tests/test_security_parity.sh`
