# Coder Summary

## Status: COMPLETE

## What Was Implemented

Milestone **m31.1 — Build + Completion Gates** (first of two sub-milestones
in the m31 Gates Port arc). Ported `lib/gates.sh`, `lib/gates_phases.sh`,
and `lib/gates_completion.sh` (~576 LOC total) to the new
`internal/gates/` Go package. The UI gate (`lib/gates_ui*.sh`) stays bash
through m31.2 and is reached via a thin bash-shim placeholder in the new
package.

### `internal/gates/` package (NEW, 7 production files)

- **`build.go`** — `BuildGate` orchestrator + `Phase` interface +
  `PhaseError`. `BuildGate.Run(ctx, stageLabel)` walks five registered
  phases under an omnibus `BUILD_GATE_TIMEOUT` budget. Failure short-
  circuits with a `*PhaseError` wrapping `ErrPhaseFailed`; deadline
  expiry returns `ErrGateTimeout`. `PhaseOrder()` is the canonical
  `[analyze, compile, constraints, ui_test, ui_validation]` slice; the
  `TestBuildGate_PhaseOrder` invariant test fails red on any reorder.

- **`phases.go`** — `AnalyzePhase`, `CompilePhase`, `ConstraintsPhase`,
  `UIBashShim`, `UIValidationPhase`. M54 remediation re-runs are
  preserved (one retry per phase via the `Remediator` interface). The
  bash `timeout 124 → pass` semantics are mirrored (`timedOut==true` ⇒
  `StatusPass`). Compile errors are `head -20`-limited like the bash
  side.

- **`completion.go`** — `CompletionGate.Run(ctx)` ports
  `run_completion_gate`. Five preserved branches: IN PROGRESS, COMPLETE
  + TEST_CMD pass, COMPLETE + new failures, COMPLETE + pre-existing
  failures (M92), and no-status (with M86 substantive-work probe).
  Dependency injection: `BaselineComparator`, `SubstantiveProbe`,
  `TestDedup`, `SummaryDriftHook`. M27.2 hang guard:
  `cmd.Stdin = nil` in `ExecRunner` so `read < /dev/tty` cannot block.
  Failure dump → `COMPLETION_GATE_LAST_FAILURE.log`.

- **`errors_writer.go`** — `ErrorsWriter` interface + `FSErrorsWriter`
  implementation + `NoopErrorsWriter` for tests. Byte-identity points
  preserved from the bash side: analyze writes raw stream in
  truncate mode (`>`), compile appends (`>>`); the H1 + `## Stage` block
  is written once per round (compile only writes H1 if BUILD_ERRORS.md
  doesn't yet exist); annotated headers via `terr.AnnotateBuildErrors`.

- **`runner.go`** — `CommandRunner` interface + `ExecRunner`
  implementation (production: `bash -c` with `cmd.Stdin = nil` for the
  M27.2 guard, `exec.CommandContext` deadline-cancellation,
  `timeout 124` exit-code mapping).

- **`remediation.go`** — `Remediator` interface + `BashRemediator` shim.
  m31.1 keeps the remediation registry in bash (`lib/remediation.sh`);
  the Go gate shells out via `bash -c 'source common.sh; source
  errors.sh; source remediation.sh; attempt_remediation ...'`. The
  ERRORS_STREAM is passed via env so newlines/quotes/`$` survive.

- **`helpers.go`** — Tiny package-level shim for `os.Environ()` so tests
  can stub the environment without monkey-patching globally.

### `cmd/tekhton/` additions

- **`gate.go`** (NEW) — `newGateCmd()` registers the parent `gate`
  command (Hidden so it stays out of `tekhton --help`) with three
  visible children: `build`, `completion`, `ui` (m31.2 stub returning
  exit 64). `buildGateFromEnv(stageLabel)` and `completionGateFromEnv()`
  assemble the gate types from the m26 env contract; `resolveUnder`
  joins relative paths under `PROJECT_DIR` so artifacts land at the
  target-project root rather than the binary's CWD.

- **`gate_ui_shim.go`** (NEW) — `uiBashRunner` exec's
  `bash -c "source lib/gates_ui_helpers.sh; source lib/gates_ui.sh;
  _run_ui_test_phase '$stage_label'"` when `UI_TEST_CMD` is set. m31.2
  deletes this file and replaces with a native `internal/gates/ui.go`.

- **`main.go`** — `newGateCmd()` added to the root command's
  `AddCommand` list.

### Bash compatibility shims (`tekhton-legacy.sh`)

- Replaced the three `source lib/gates{,_phases,_completion}.sh` lines
  with inline `run_build_gate()` and `run_completion_gate()` shim
  functions that exec `tekhton gate build --stage-label "$1"` and
  `tekhton gate completion` respectively. The shims emit a clear error
  and return 0 when the binary is missing (matching the
  `run_preflight_checks` post-m22 fallback shape). `lib/gates_ui.sh` +
  `lib/gates_ui_helpers.sh` remain sourced for the bash UI phase
  through m31.2.

### Bash test retirement / updates

- **`tests/test_gates_extraction.sh`** — deleted. Tested the m28 bash
  extraction of `gates_ui.sh` from `gates.sh`; superseded by the full
  port.
- **`tests/test_gates_stale_raw_errors.sh`**,
  **`tests/test_build_errors_phase2_header.sh`**,
  **`tests/test_build_gate_timeouts.sh`**,
  **`tests/test_gates_bypass_flow.sh`**,
  **`tests/test_ui_build_gate.sh`**,
  **`tests/test_dependency_constraints.sh`** — self-skip with a
  forward-pointer comment when `lib/gates.sh` is absent (the m31.1
  state). Behavioural coverage moved to the new Go tests.
- **`tests/test_pristine_state_enforcement.sh`** Suite 6 — stubbed
  with a pointer to `internal/gates/completion_test.go::TestCompletionGate_PreExistingFailure*`.
- **`tests/test_dedup_callsites.sh`** Suite 4.2 — removed (the bash
  callsite is gone; the M105 dedup hook is now `CompletionGate.Dedup`
  exercised by `TestCompletionGate_DedupSkipsTestCmd`).
- **`tests/test_file_size_ceilings.sh`** — flipped from "gates.sh
  must exist + under ceiling" to "gates*.sh must NOT exist" invariant
  (the m31.1 deletion guard).

### Tests (NEW)

- **`internal/gates/build_test.go`** — phase-order invariant, pass/fail/
  timeout/skip/cancel paths.
- **`internal/gates/phases_test.go`** — table-driven analyze + compile +
  constraints + UI-shim coverage; M54 remediation one-retry-cap
  enforcement; `timeout 124 → pass` parity.
- **`internal/gates/completion_test.go`** — all five branches; the
  critical `TestCompletionGate_StdinDevNull` proves the M27.2 hang
  guard works against a real `bash -c "read -t 1 ..."` TEST_CMD with a
  10-second wall-clock timeout.
- **`internal/gates/errors_writer_test.go`** — structural equivalence
  for analyze, compile (append mode!), constraints, timeout, and
  clear-on-pass paths.
- **`internal/gates/coverage_test.go`** — `Phase.Name()` + `ExecRunner`
  exec paths + sentinel error coverage so package coverage stays above
  the 80% target.
- **`cmd/tekhton/gate_test.go`** — Cobra subcommand registration, help
  listing, UI-stub exit code, env-helper unit tests.

### Bash integration tests (NEW)

- **`tests/test_gates_parity.sh`** — eight-scenario parity gate driving
  `tekhton gate build` and `tekhton gate completion` against captured
  baselines under `tests/testdata/gates/`. 13 assertions, all passing.
  Reuses `tests/lib/parity.sh`.
- **`tests/test_buildfix_against_go_gate.sh`** — cross-seam coverage:
  drives the Go gate to produce `BUILD_RAW_ERRORS.txt`, then exercises
  `stages/coder_buildfix.sh::_bf_read_raw_errors` against the Go-written
  stream AND drives `tekhton diagnose classify --mode routing` to
  assert the m17 classifier reports `code_dominant` for a TS2304
  failure. 5 assertions, all passing.

### Test fixtures (NEW)

- `tests/testdata/gates/{analyze_dirty,compile_dirty,gate_timeout}/expected/BUILD_ERRORS.md`
  and matching `BUILD_RAW_ERRORS.txt` files. Timestamp normalisation via
  `_gates_normalise` (sed) collapses the `# Build Errors — YYYY-MM-DD ...`
  line to `TIMESTAMP` before diffing.

### Other updates

- **`internal/stagerunner/helpers.go`** — `DefaultLibHelpers` no longer
  includes the three deleted bash files. Parity test
  (`TestDefaultLibHelpersParityWithLegacy`) re-passes.
- **`scripts/wedge-audit-patterns.sh`** — gained 11 new forbidden
  patterns: the three deleted `lib/gates*.sh` source-line patterns plus
  10 bash function names (`_gate_check_timeout`, `_gate_effective_timeout`,
  `_gate_phase_analyze`, `_gate_phase_compile`, `_gate_try_remediation`,
  `_gate_run_analyze`, `_gate_run_compile`, `_gate_write_analyze_errors`,
  `_gate_write_compile_errors`, `_warn_summary_drift`). Wedge-audit
  reports clean (194 files audited).
- **`.claude/milestones/MANIFEST.cfg`** — m31.1 row title updated from
  "Build and Completion Gates" to "Build + Completion Gates" per the
  acceptance criterion. Status flip to `done` is handled by the
  finalize hook.
- **`ARCHITECTURE.md`** — added `internal/gates/`, `cmd/tekhton/gate.go`,
  and `tekhton-legacy.sh::run_build_gate / ::run_completion_gate` entries;
  removed the `lib/gates.sh` and `lib/gates_phases.sh` entries; updated
  the `lib/gates_ui_helpers.sh` and `lib/test_dedup.sh` entries' sourcing
  notes.

## Root Cause (bugs only)
N/A — feature port milestone.

## Files Modified

### Created (NEW)
- `internal/gates/build.go` (NEW)
- `internal/gates/build_test.go` (NEW)
- `internal/gates/phases.go` (NEW)
- `internal/gates/phases_test.go` (NEW)
- `internal/gates/completion.go` (NEW)
- `internal/gates/completion_test.go` (NEW)
- `internal/gates/errors_writer.go` (NEW)
- `internal/gates/errors_writer_test.go` (NEW)
- `internal/gates/coverage_test.go` (NEW)
- `internal/gates/runner.go` (NEW)
- `internal/gates/remediation.go` (NEW)
- `internal/gates/helpers.go` (NEW)
- `cmd/tekhton/gate.go` (NEW)
- `cmd/tekhton/gate_test.go` (NEW)
- `cmd/tekhton/gate_ui_shim.go` (NEW)
- `tests/test_gates_parity.sh` (NEW)
- `tests/test_buildfix_against_go_gate.sh` (NEW)
- `tests/testdata/gates/analyze_dirty/expected/BUILD_ERRORS.md` (NEW)
- `tests/testdata/gates/analyze_dirty/expected/BUILD_RAW_ERRORS.txt` (NEW)
- `tests/testdata/gates/compile_dirty/expected/BUILD_ERRORS.md` (NEW)
- `tests/testdata/gates/compile_dirty/expected/BUILD_RAW_ERRORS.txt` (NEW)
- `tests/testdata/gates/gate_timeout/expected/BUILD_ERRORS.md` (NEW)

### Modified
- `cmd/tekhton/main.go` — `newGateCmd()` registered
- `tekhton-legacy.sh` — three source lines replaced with inline
  `run_build_gate` / `run_completion_gate` exec-shim functions
- `internal/stagerunner/helpers.go` — `DefaultLibHelpers` dropped
  `lib/gates.sh`, `lib/gates_phases.sh`, `lib/gates_completion.sh`
- `scripts/wedge-audit-patterns.sh` — 11 new m31.1 regression guards
- `.claude/milestones/MANIFEST.cfg` — m31.1 title hyphenation fix
- `ARCHITECTURE.md` — gates entries updated
- `tests/test_pristine_state_enforcement.sh` — Suite 6 stubbed
- `tests/test_dedup_callsites.sh` — Suite 4.2 removed
- `tests/test_file_size_ceilings.sh` — flipped to deletion invariant
- `tests/test_gates_stale_raw_errors.sh`,
  `tests/test_build_errors_phase2_header.sh`,
  `tests/test_build_gate_timeouts.sh`,
  `tests/test_gates_bypass_flow.sh`,
  `tests/test_ui_build_gate.sh`,
  `tests/test_dependency_constraints.sh` — self-skip when
  `lib/gates.sh` is absent

### Deleted
- `lib/gates.sh` (217 lines, ported to `internal/gates/build.go` +
  `phases.go` + `errors_writer.go`)
- `lib/gates_phases.sh` (205 lines, ported to `internal/gates/phases.go`)
- `lib/gates_completion.sh` (154 lines, ported to
  `internal/gates/completion.go`)
- `tests/test_gates_extraction.sh` (the m28 bash-extraction structural
  test — superseded)

## Test Results
- **Go**: `go test ./internal/gates/ ./cmd/tekhton/` PASS;
  `internal/gates/` coverage 82.9% of statements (above the 80%
  acceptance target).
- **`go vet ./...`**: clean.
- **Bash**: `bash tests/run_tests.sh` reports 501 shell + all 26 Go
  packages PASS (was 500 before m31.1; the two new bash tests added a
  count of one each).
- **`shellcheck -S warning`** on all touched bash files: clean.
- **Wedge audit**: clean (194 files audited).
- **`test_gates_parity.sh`**: 13/13 PASS across 8 scenarios
  (analyze_clean, analyze_dirty, compile_clean, compile_dirty,
  completion_pass, completion_test_fail, completion_no_status,
  gate_timeout). Build-error fixtures byte-identical after timestamp
  normalisation; raw-error fixtures byte-identical without normalisation.
- **`test_buildfix_against_go_gate.sh`**: 5/5 PASS — confirms
  `_bf_read_raw_errors` consumes the Go-written stream and the m17
  classifier emits `code_dominant` for the captured failure.

## Human Notes Status
No human notes referenced for m31.1.

## Docs Updated
- `ARCHITECTURE.md` — `internal/gates/` and `cmd/tekhton/gate.go` entries
  added; `lib/gates.sh` and `lib/gates_phases.sh` entries removed;
  `lib/gates_ui_helpers.sh` and `lib/test_dedup.sh` sourcing notes
  updated.

## Architecture Change Proposals

### `internal/gates/` is a sibling package to `internal/pipeline/`, not a replacement

- **Current constraint**: ARCHITECTURE.md previously had a single
  `lib/gates.sh` row; the m18 `internal/pipeline.BuildGate` /
  `CompletionGate` types exist as a SIMPLER scheduling-level gate used
  by the per-attempt scheduler, distinct from the bash gate that ran
  inside the coder subprocess.
- **What triggered this**: m31.1's Goal 1 was to port the bash gate
  (the one with phase boundaries, M54 remediation, raw-stream output
  files) — not to replace the m18 simpler gate that the in-process
  scheduler uses. Two different abstractions, two different call paths.
- **Proposed change**: m31.1 ships `internal/gates/` as a NEW package.
  The m18 `internal/pipeline/gates.go` stays for the per-attempt
  scheduler (the call site at `internal/pipeline/runner.go:247`). The
  bash-equivalent gate is reached via the CLI seam (`tekhton gate`).
  ARCHITECTURE.md now documents both.
- **Backward compatible**: Yes. m18 in-process gates unchanged.
- **ARCHITECTURE.md update needed**: Already applied — the `internal/gates/`
  + `cmd/tekhton/gate.go` rows replace the deleted bash entries and
  carry a m31.2 forward-pointer for the UI phase.
