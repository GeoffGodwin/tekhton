# Coder Summary

## Status: COMPLETE

## What Was Implemented

Milestone **m38.4 — Test Audit Family**. Ported the entire test-audit
subsystem (six bash files, 846 LOC) to a new Go package
`internal/test_audit/` (six source files + six test files, ~1560 + ~1140
LOC).

Highlights:

- **`internal/test_audit/audit.go`** — orchestrator with rework loop.
  `Run` is the pipeline-integration entry point; `RunStandalone` is the
  `--audit-tests` path. `DefaultOptions().MaxReworkCycles == 1` (regression-canary).
- **`internal/test_audit/helpers.go`** — `CollectAuditContext`,
  `DiscoverAllTestFiles`, `BuildTestAuditContext`. Reads
  `TESTER_REPORT.md` for ticked test files; reads `CODER_SUMMARY.md`
  for impl files (test/spec filter applied); reads git diff for deletes.
- **`internal/test_audit/detection.go`** — orphan + weakening
  detectors. Pure regex scans on git diff output. Detects net assertion
  loss, broadening swaps, and removed test functions.
- **`internal/test_audit/sampler.go`** — M89 K=3 rolling sampler with
  JSONL history at `cache_dir/test_audit_history.jsonl`. Atomic prune
  at `MaxRecords=500` (tmp + rename).
- **`internal/test_audit/symbols.go`** — M88 stale-symbol detector.
  **Native Go `encoding/json` — no python shell-out.** Gated by
  `TEST_AUDIT_SYMBOL_MAP_ENABLED` + `SERENA_ACTIVE`. Appends findings
  to `OrphanFindings` (mirrors the bash global merge).
- **`internal/test_audit/verdict.go`** — 4-outcome parser
  (PASS / CONCERNS / NEEDS_WORK + missing-report→PASS). `ErrAuditNeedsWork`
  sentinel; CONCERNS appends `#### CATEGORY` headers to
  `NON_BLOCKING_LOG.md` under a dated section header.

Integration changes:

- **`internal/tester/continuation.go`** — default `TestAuditRunner` seam
  flipped from `noopTestAuditRunner` to the new `nativeTestAuditRunner`.
  Calls `test_audit.Run` directly in-process. Tests can still override
  via `SetContinuationTestAuditRunner`.
- **`internal/stagerunner/helpers.go`** —
  `DefaultStageDefs[StageTester].Helpers` cleared (the six
  `lib/test_audit*.sh` entries are gone).
- **`internal/stagerunner/parity_test.go`** — `wantHelpers[StageTester]`
  shrunk to `{}` to match.
- **`tekhton-legacy.sh`** — replaced the six `source` lines with a tiny
  `run_test_audit()` shim that execs `tekhton test-audit run`.
  Standalone `--audit-tests` block execs `tekhton test-audit run-standalone`.
- **`cmd/tekhton/test_audit.go`** — new Hidden Cobra parent `tekhton
  test-audit` with two subs (`run`, `run-standalone`). Wired into
  `main.go`'s subcommand list.
- **`scripts/wedge-audit-companions.sh`** — added m38.4 ban:
  re-introducing any `lib/test_audit*.sh` file fails the audit.
- **`CLAUDE.md`** + **`ARCHITECTURE.md`** — repository-layout and
  layer-3 entries updated to reflect the port.

Deletions:
- `lib/test_audit.sh`
- `lib/test_audit_detection.sh`
- `lib/test_audit_helpers.sh`
- `lib/test_audit_sampler.sh`
- `lib/test_audit_symbols.sh`
- `lib/test_audit_verdict.sh`
- Eight bash test files under `tests/test_audit*.sh` + `tests/test_m88_stale_sym_accumulation.sh` + `tests/test_test_audit_split.sh` (their underlying bash logic ported; replaced by Go-side tests).

Acceptance criteria status:
- ✓ `audit.go` exports `Run` and `RunStandalone`.
- ✓ `verdict.go` exports `Verdict` with exactly three values; missing report maps to `VerdictPASS` (covered by `TestParseAuditVerdict_MissingReportIsPASS`).
- ✓ Four-case table test on `ParseAuditVerdict` (PASS / CONCERNS / NEEDS_WORK / unparseable→PASS).
- ✓ `RouteAuditVerdict` returns nil for PASS/CONCERNS, `ErrAuditNeedsWork` for NEEDS_WORK.
- ✓ Orphan / weakening / stale-sym detection tests pass against fixtures.
- ✓ `grep -nE 'exec\.Command' internal/test_audit/symbols.go` returns zero.
- ✓ M88 gated by `TEST_AUDIT_SYMBOL_MAP_ENABLED=false` or empty `TEST_SYMBOL_MAP_FILE`.
- ✓ Sampler K=3 sorting tests.
- ✓ `RecordAuditHistory` writes one JSONL entry per file with `ts` + `file`.
- ✓ `PruneAuditHistory` truncates atomically.
- ✓ `Run` skips when `Enabled=false`.
- ✓ Rework loop runs up to `MaxReworkCycles=1`.
- ✓ `continuation.go::RunAndRecordTestAudit` has no `exec.Command.*audit`.
- ✓ Six `lib/test_audit*.sh` files deleted.
- ✓ `DefaultStageDefs[StageTester].Helpers` no longer references test_audit.
- ✓ `scripts/wedge-audit.sh` rejects re-introducing any of the six files (regression verified by planting a dummy and seeing the audit exit 1).
- ✓ `bash scripts/wedge-audit.sh` exits 0 against the m38.4 tree.
- ✓ `go test ./internal/test_audit/... ./internal/tester/...` passes with coverage 83.0% (≥ 75% target).
- ✓ `bash tests/run_tests.sh` reports 500 passes, 0 failures.

## Root Cause (bugs only)

N/A — milestone implementation, not bug fix.

## Files Modified

- `internal/test_audit/audit.go` (NEW)
- `internal/test_audit/audit_test.go` (NEW)
- `internal/test_audit/helpers.go` (NEW)
- `internal/test_audit/helpers_test.go` (NEW)
- `internal/test_audit/detection.go` (NEW)
- `internal/test_audit/detection_test.go` (NEW)
- `internal/test_audit/sampler.go` (NEW)
- `internal/test_audit/sampler_test.go` (NEW)
- `internal/test_audit/symbols.go` (NEW)
- `internal/test_audit/symbols_test.go` (NEW)
- `internal/test_audit/verdict.go` (NEW)
- `internal/test_audit/verdict_test.go` (NEW)
- `internal/test_audit/testdata/stale-sym/test_map.json` (NEW)
- `internal/test_audit/testdata/stale-sym/tags.json` (NEW)
- `internal/test_audit/testdata/verdict/pass.md` (NEW)
- `internal/test_audit/testdata/verdict/concerns.md` (NEW)
- `internal/test_audit/testdata/verdict/needs_work.md` (NEW)
- `cmd/tekhton/test_audit.go` (NEW)
- `cmd/tekhton/main.go` — register `newTestAuditCmd`
- `internal/tester/continuation.go` — flip default seam to `nativeTestAuditRunner`; build audit Request from env
- `internal/tester/continuation_test.go` — swap `noopTestAuditRunner` → `nativeTestAuditRunner` in the safety test
- `internal/stagerunner/helpers.go` — drop six test_audit Helpers entries
- `internal/stagerunner/parity_test.go` — `wantHelpers[StageTester]={}`
- `tekhton-legacy.sh` — replace source lines + standalone block with `run_test_audit` shim and `tekhton test-audit run-standalone` exec
- `scripts/wedge-audit-companions.sh` — add m38.4 ban
- `CLAUDE.md` — repository-layout collapse
- `ARCHITECTURE.md` — layer-3 entry for `internal/test_audit/` + `cmd/tekhton/test_audit.go` + `nativeTestAuditRunner`
- `lib/test_audit.sh` (DELETED)
- `lib/test_audit_detection.sh` (DELETED)
- `lib/test_audit_helpers.sh` (DELETED)
- `lib/test_audit_sampler.sh` (DELETED)
- `lib/test_audit_symbols.sh` (DELETED)
- `lib/test_audit_verdict.sh` (DELETED)
- `tests/test_audit_coverage_gaps.sh` (DELETED — bash unit test for ported code)
- `tests/test_audit_sampler.sh` (DELETED)
- `tests/test_audit_standalone.sh` (DELETED)
- `tests/test_audit_symbol_orphan.sh` (DELETED)
- `tests/test_audit_tests.sh` (DELETED)
- `tests/test_audit_verdict_unknown_catch_all.sh` (DELETED)
- `tests/test_m88_stale_sym_accumulation.sh` (DELETED)
- `tests/test_test_audit_split.sh` (DELETED)

## Docs Updated

- `ARCHITECTURE.md` — replaced four bash-file entries with three Go-package entries (`internal/test_audit/`, `cmd/tekhton/test_audit.go`, `nativeTestAuditRunner`).
- `CLAUDE.md` — repository-layout block collapsed; bash files commented out per the m30/m17 precedent.

## Human Notes Status

No actionable human notes were attached to this task. The HUMAN_NOTES.md
content shown in the run context contains only stale clarifications
from unrelated prior runs (Watchtower dashboard, NON_BLOCKING_LOG,
brownfield `--init` flow) that the human had already self-answered.
None applied to m38.4.
