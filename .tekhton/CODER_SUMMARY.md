# Coder Summary
## Status: COMPLETE

## What Was Implemented

**Milestone m50 — MANIFEST.cfg is finalize-owned: block stage-agent writes via a pre-commit guard.** All five goals landed:

1. **Goal 1 — `.tekhton/.finalize_active` sentinel writer** in `internal/finalize/orchestrator.go`. `Orchestrator.Run` writes the sentinel via the new `writeFinalizeActiveSentinel` helper at the top of the hook chain and clears it via a deferred closure so a panic mid-finalize cannot leave the sentinel set. The helper is a no-op when `ProjectDir` is empty (the debug-subcommand path).

2. **Goal 2 — bash pre-commit guard `_check_manifest_write_guard`** in `lib/finalize_commit.sh`. `_do_git_commit` invokes the guard immediately before the actual `git commit -m` invocation. Behavior: if MANIFEST.cfg is staged AND `.tekhton/.finalize_active` is absent AND `TEKHTON_MANIFEST_WRITE_OVERRIDE=1` is not set → log a warning, `git restore --staged` MANIFEST.cfg, return 0 (the rest of the commit proceeds). Operator escape hatch `TEKHTON_MANIFEST_WRITE_OVERRIDE=1` skips the unstage. Resolved the 300-line ceiling pressure on `finalize_commit.sh` by extracting `_write_commit_decision`, `_run_commit_bookkeeping`, `_tag_milestone_if_complete` into a new sibling `lib/finalize_commit_helpers.sh` (89 LOC).

3. **Goal 3 — Go-side observability defense** in `cmd/tekhton/run.go::emitAutoAdvanceCommitBanner`. Added `emitManifestWriteAuditBanner` + `headCommitTouchedManifest` helpers that surface `⚠ <id> MANIFEST.cfg committed by non-finalize source` when HEAD touched `.claude/milestones/MANIFEST.cfg` AND the commit subject does NOT match the `[MILESTONE <id> ✓]` prefix. Pure observability — bash guard is the hard enforcer; this banner catches future regressions that might bypass the bash guard.

4. **Goal 4 — coder prompt tightening** in `prompts/coder.prompt.md`. New `### File Boundaries` subsection under `## Required Reading` explicitly names `.claude/milestones/MANIFEST.cfg` as finalize-owned and instructs the agent to surface manifest needs in `## Drift Observations` instead of writing the file.

5. **Goal 5 — regression tests**:
   - `internal/finalize/orchestrator_test.go::TestOrchestrator_SetsAndClearsFinalizeActiveSentinel` — probes the sentinel mid-Run and asserts cleanup after Run returns.
   - `internal/finalize/orchestrator_test.go::TestOrchestrator_FinalizeActiveSentinel_NoProjectDir` — smoke coverage for the debug-subcommand no-op path.
   - `cmd/tekhton/run_test.go::TestEmitAutoAdvanceCommitBanner_ManifestWriteByNonFinalizeSource` — three sub-scenarios: rogue stage commit fires the banner; legitimate finalize commit does not; commit that doesn't touch MANIFEST.cfg does not.
   - `tests/test_manifest_write_guard.sh` (NEW, 157 lines) — three-scenario shim-boundary test exercising the bash guard end-to-end (scenario 1: stage-time → unstage + warn; scenario 2: sentinel present → no-op; scenario 3: override → keep staged + warn).

### Architecture refactor (in service of staying under the 300-line bash ceiling)

`lib/finalize_commit.sh` was at 297 LOC before m50. Adding the ~30-line `_check_manifest_write_guard` would have pushed it to 327, breaking CLAUDE.md Rule 8. Resolution: extract three pre-existing helpers (`_write_commit_decision`, `_run_commit_bookkeeping`, `_tag_milestone_if_complete`) to a new sibling `lib/finalize_commit_helpers.sh` (89 LOC). Net result: `lib/finalize_commit.sh` is 278 LOC after m50; the new helpers file is 89 LOC; both well under the ceiling. The three extracted functions still resolve at runtime via the existing source chain — `lib/finalize_commit.sh` now sources `lib/finalize_commit_helpers.sh` directly. `tests/test_final_checks_commit_gate.sh` continues to pass — it sources `lib/finalize_commit.sh` and reaches the extracted helpers through transitive sourcing.

### Acceptance Criteria — Final Status

| Criterion | Status |
|-----------|--------|
| `Orchestrator.Run` writes `.tekhton/.finalize_active` at top of chain (`grep -nE 'finalize_active' internal/finalize/orchestrator.go` returns matches) | ✓ (2 matches at lines 215, 232) |
| Sentinel cleaned up after `Run` returns | ✓ (verified by `TestOrchestrator_SetsAndClearsFinalizeActiveSentinel`) |
| `lib/finalize_commit.sh` contains `_check_manifest_write_guard` (≥3 grep matches: definition + call site + comment) | ✓ (4 matches: lines 88, 89, 98, 117) |
| `_do_git_commit` calls `_check_manifest_write_guard` within 5 lines above `git commit -m` | ✓ (call at line 89, commit at line 92) |
| Scenario 1 (stage-time, no sentinel) → unstage MANIFEST.cfg + proceed | ✓ (`tests/test_manifest_write_guard.sh` scenario 1) |
| Scenario 2 (finalize-time, sentinel present) → keep MANIFEST.cfg staged | ✓ (scenario 2) |
| Scenario 3 (`TEKHTON_MANIFEST_WRITE_OVERRIDE=1`) → bypass guard | ✓ (scenario 3) |
| `prompts/coder.prompt.md` mentions MANIFEST.cfg in File Boundaries (`grep -nE 'MANIFEST.cfg' ...`) | ✓ (2 matches at lines 203, 213) |
| Auto-advance banner emits MANIFEST.cfg warning under regression conditions | ✓ (`TestEmitAutoAdvanceCommitBanner_ManifestWriteByNonFinalizeSource`) |
| No regression: `internal/finalize/...` Go tests | ✓ (`go test ./internal/finalize/...` clean) |
| No regression: `cmd/tekhton/...` Go tests | ✓ |
| No regression: existing `tests/test_*.sh` files | ✓ (486 shell tests pass on retry — initial run flaked on `test_wedge_audit.sh` and `supervisor::TestRun_HappyPath_EmitsResultEnvelope`, both pre-existing flakes that pass individually and on re-run) |
| `shellcheck lib/finalize_commit.sh tests/test_manifest_write_guard.sh` clean | ✓ (warning-level clean; SC1091 info noise from sourced files, not a warning) |
| `go vet ./internal/finalize/... ./cmd/tekhton/...` clean | ✓ |
| `bash tests/run_tests.sh` + `go test ./...` pass | ✓ (after one supervisor flake retry — pre-existing) |
| `bash scripts/wedge-audit.sh` clean | ✓ (172 files audited, 12 allowed shim writers) |
| `bash scripts/audit-bash-env.sh` clean | ✓ |

## Root Cause (bugs only)

N/A — m50 is a hardening milestone. The underlying bug class (coder-agent writes to MANIFEST.cfg slipping through to commits) was documented in the m48 / 51aff09 incident; m50 closes the gap with a pre-commit guard + observability defense + prompt-level instruction.

## Files Modified

### Created (NEW)
- `lib/finalize_commit_helpers.sh` (NEW, 89 LOC) — extracted helpers (`_write_commit_decision`, `_run_commit_bookkeeping`, `_tag_milestone_if_complete`) freed from `finalize_commit.sh` to make room for `_check_manifest_write_guard`.
- `tests/test_manifest_write_guard.sh` (NEW, 157 LOC) — three-scenario shim-boundary test.

### Modified
- `internal/finalize/orchestrator.go` — added `path/filepath` import; injected sentinel-write into `Run` with deferred cleanup; added `writeFinalizeActiveSentinel` helper.
- `internal/finalize/orchestrator_test.go` — added `os` + `path/filepath` imports; added `TestOrchestrator_SetsAndClearsFinalizeActiveSentinel` and `TestOrchestrator_FinalizeActiveSentinel_NoProjectDir`.
- `lib/finalize_commit.sh` — source the new helpers file; removed the three extracted helpers (now in helpers.sh); added `_check_manifest_write_guard` definition; wired the call into `_do_git_commit` before `git commit -m`.
- `cmd/tekhton/run.go` — added `emitManifestWriteAuditBanner` + `headCommitTouchedManifest`; wired into both branches of `emitAutoAdvanceCommitBanner`.
- `cmd/tekhton/run_test.go` — added `TestEmitAutoAdvanceCommitBanner_ManifestWriteByNonFinalizeSource` with three sub-scenarios.
- `prompts/coder.prompt.md` — added `### File Boundaries` subsection naming MANIFEST.cfg.
- `CLAUDE.md` — repository layout updated: new `finalize_commit_helpers.sh` row; `finalize_commit.sh` description appended with `+ m50 _check_manifest_write_guard`.

## Docs Updated

- `CLAUDE.md` repository layout — updated the `finalize_commit.sh` description and added the new `finalize_commit_helpers.sh` row (m50 helper extraction).

## Human Notes Status

No HUMAN_NOTES.md items were attached to this milestone run.

## Observed Issues (out of scope)

- `internal/supervisor::TestRun_HappyPath_EmitsResultEnvelope` flaked on the initial full-suite run (`TurnsUsed: got 0, want 2`) but passes when run alone and on retry. This is an integration test that depends on an external claude binary; the flake is pre-existing and unrelated to m50.
- `tests/test_wedge_audit.sh` flaked on the same initial full-suite run but passes on retry. Pre-existing — likely a race between concurrent harness invocations of `git status` inside the audit's HEAD-vs-WT diff. Unrelated to m50.
- `gofmt -l internal/finalize/orchestrator.go` reports pre-existing alignment issues in the `goNativeHooks` map literal block (lines 113–119 and 126–127). NOT introduced by m50 — my changes don't touch those lines. Out of scope.
- `golangci-lint` reports a vendored-stdlib mismatch (`golang.org/x/crypto/chacha20poly1305/fips140only_go1.26.go` requires Go 1.26, application built with go1.23). This is an environment issue with the Go toolchain, not a code issue, and not introduced by m50.

## Architecture Change Proposals

None — m50 reuses the existing finalize chain hook, an existing per-iteration banner, and the existing source chain in `lib/finalize_commit.sh`. The bash helper extraction (`finalize_commit_helpers.sh`) follows the same pattern as the existing `finalize_commit_staging.sh` and `finalize_commit_sentinel.sh` siblings. No new layer boundaries; no new dependencies between systems; no changed interface contracts.

## Remaining Work

None.
