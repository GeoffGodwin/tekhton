# Coder Summary
## Status: COMPLETE

## What Was Implemented

Milestone **m31.2 — UI Gates** (second of two sub-milestones in the m31
Gates Port arc). Closes the m31 arc: ports `lib/gates_ui.sh` (183 lines)
and `lib/gates_ui_helpers.sh` (190 lines) to native Go, deletes both bash
files, and replaces the m31.1 bash-shim `UIBashShim` with a native
`UIPhase` Go implementation. All five `gates*.sh` files are now zero.

### `internal/gates/` additions

- **`ui_helpers.go`** (NEW, 170 lines) — Pure helpers ported from
  `lib/gates_ui_helpers.sh`:
  - `DetectFramework(in FrameworkDetectInput) Framework` — priority order
    matches the bash cascade: P0 `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1`
    (M130) → P1 `UI_FRAMEWORK==playwright` → P2 `UI_TEST_CMD` word-boundary
    regex → P3 `playwright.config.{ts,js,mjs,cjs}` in `PROJECT_DIR` → P4
    `none`.
  - `DeterministicEnvList(fw, hardened, preflightInteractive) []string` —
    M131 `PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1` escalates to
    hardened on the FIRST run, not just retry. Returns nil for
    non-playwright frameworks.
  - `TimeoutSignature(exitCode, output) string` — pure classifier:
    `interactive_report` | `generic_timeout` | `none`.
  - `HardenedTimeout(base, factor) time.Duration` — clamped to
    `[1, base]`; factor==0 clamps to 1s, factor>=1 clamps to base.
  - `RenderDiagnosis(in DiagnosisInput) string` — byte-identical port of
    the bash `_ui_write_gate_diagnosis` heredoc; the four-line block is
    appended to UI_TEST_ERRORS.md and BUILD_ERRORS.md by the caller.

- **`ui.go`** (NEW, 245 lines) — Native `UIPhase` Go implementation.
  - Skip when `UI_TEST_CMD` unset or `UI_VALIDATION_ENABLED=false`.
  - Skip when the command's first token is not on PATH (npx/npm
    always pass; everything else uses `exec.LookPath`).
  - Run #1 with the deterministic non-interactive env profile.
  - On exit 0 → Pass.
  - On `interactive_report` timeout signature (M126): skip M54
    remediation AND generic retry; attempt the hardened rerun once
    (timeout = `UI_TEST_TIMEOUT * UI_GATE_ENV_RETRY_TIMEOUT_FACTOR`,
    clamped to [1, base]).
  - Otherwise: one M54 remediation re-run, then one generic flakiness
    retry.
  - On terminal failure: `WriteUIFailure` truncates BUILD_RAW_ERRORS.txt,
    writes a fresh UI_TEST_ERRORS.md, and appends `## UI Test Failures`
    to BUILD_ERRORS.md (creating its `# Build Errors — TS` header only
    if the file does not yet exist — preserves the bash `>` vs `>>`
    parity from when analyze/compile may have written it earlier in the
    same gate run).
  - Then `WriteUIDiagnosis` appends the structured `## UI Gate
    Diagnosis` block to both files.

- **`UICommandRunner` interface + `UIEnvRunner` production impl**
  (`runner.go`) — UI-aware command runner that injects the deterministic
  env list at `exec.Cmd.Env` boundary. `runBashCmd` helper shared with
  `ExecRunner` so the M27.2 stdin-nil guard and `timeout 124` mapping
  stay byte-equivalent across both runners.

- **`ErrorsWriter` interface extended**
  (`errors_writer.go`) — added `WriteUIFailure(stageLabel, cmd, output,
  exitCode, now)` and `WriteUIDiagnosis(block)`. Implemented on
  `FSErrorsWriter` (byte-identical bash heredoc format with `tail -100`)
  and `NoopErrorsWriter`. The bash `## UI Test Failures` section is
  appended to BUILD_ERRORS.md only if the file already exists; otherwise
  the H1 header is created first.

### `cmd/tekhton/` updates

- **`gate.go`** — Replaced the m31.1 stub `gateUICmd` body with the real
  implementation. `tekhton gate ui [--stage-label LABEL]` drives the
  native `UIPhase` via `uiPhaseFromEnv`. New `--print-framework` flag
  prints the detected framework (`playwright | none`) and exits 0; used
  by the parity test. `uiPhaseFromEnv()` reads the m26 env contract
  (UI_TEST_CMD, UI_TEST_TIMEOUT, UI_VALIDATION_ENABLED, UI_FRAMEWORK,
  UI_GATE_ENV_RETRY_*, TEKHTON_UI_GATE_FORCE_NONINTERACTIVE,
  PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED) and assembles a complete
  `UIPhase`. The build gate's `ui_test` factory now also calls
  `uiPhaseFromEnv()` — `UIBashShim` is fully retired.
- **`gate_ui_shim.go`** — Deleted. The m31.1 bash-shim entry point.
- **`gate_test.go`** — Replaced the `TestGateUI_StubReturnsNonZero`
  m31.1 stub assertion with `TestGateUI_SkipWhenCmdUnset` and
  `TestGateUI_DisabledReturnsSkip` (m31.2 native gate behaviour).

### `internal/gates/` test updates

- **`build_test.go::captureWriter`** — Extended to implement the new
  `WriteUIFailure` / `WriteUIDiagnosis` methods.
- **`coverage_test.go`** — Removed three `TestUIBashShim_*` tests (the
  type is deleted), replaced the `{&UIBashShim{}, "ui_test"}` entry in
  the phase-name coverage table with `{&UIPhase{}, "ui_test"}`, removed
  the `bashRunnerFunc` adapter. Added `WriteUIFailure` /
  `WriteUIDiagnosis` calls to `TestNoopErrorsWriter_Methods` for
  coverage.
- **`phases_test.go`** — Removed `TestUIBashShim_SkipsWhenCmdUnset`.
- **`phases.go`** — Removed `UIBashShim` struct + `BashShimRunner`
  interface (35 lines). `UIValidationPhase` retained as the m31.1 stub.
- **`errors_writer_test.go`** — Added 5 new tests covering
  `WriteUIFailure` (fresh + append-to-existing-build-errors paths),
  `WriteUIDiagnosis` (only-appends-when-file-exists, empty-block-noop),
  the `tailLines` helper, and the nil-receiver safety guards.
- **`ui_helpers_test.go`** (NEW, 224 lines) — Table-driven coverage of
  all five exported helpers, including the M130 priority-0 force hook,
  the four-priority cascade for `DetectFramework`, the env-list matrix
  across (framework × hardened × preflight-interactive), the timeout
  signature truth table, the `HardenedTimeout` clamping edge cases
  (factor==0 → 1s; factor>=1 → base), and the byte-identical RenderDiagnosis
  block.
- **`ui_test.go`** (NEW, 364 lines) — UIPhase branch coverage:
  pass-first-run, assertion-fail (terminal), interactive-timeout
  triggers hardened-rerun, hardened-retry-disabled fails immediately,
  generic-timeout diagnosis, remediation-then-pass, non-playwright
  framework skips env injection, runner-error propagation, nil-receiver
  guard, `checkUITestCmdAvailable` (npx/npm/PATH).

### Bash compatibility shims (`tekhton-legacy.sh`)

- Removed the two `source lib/gates_ui*.sh` lines (m31.1 left them in
  place; m31.2 deletes them). The five gates*.sh files are now zero in
  the lib/ tree; the only remaining bash entry points are the inline
  `run_build_gate` / `run_completion_gate` exec-shims (still needed for
  callers in stages/coder.sh + lib/milestone_acceptance.sh).

### Bash test retirement / updates

- **`tests/test_file_size_ceilings.sh`** — Extended the file-deletion
  invariant from three files (m31.1: gates.sh + gates_phases.sh +
  gates_completion.sh) to five (m31.2 adds gates_ui.sh +
  gates_ui_helpers.sh).
- **`tests/test_ui_gate_force_noninteractive.sh`** — Added a
  `lib/gates_ui_helpers.sh` self-skip guard (the bash file is gone, M130
  P0 coverage moved to `ui_helpers_test.go::TestDetectFramework_ForceNonInteractive`).
- **`tests/test_m138_coverage_gaps.sh`** — Wrapped the GAP-2 block
  (depends on `_normalize_ui_gate_env` which no longer exists) in a
  conditional skip; GAP-1 still runs.
- **`tests/test_gates_parity.sh`** — Bound `TEKHTON_BIN` to the in-repo
  binary path (`${REPO_ROOT}/bin/tekhton`) so a stale env var pointing
  at a different checkout doesn't poison the parity gate. (Found via
  test failure during m31.2; the m31.1 gate had the same bug latent.)

### Bash integration tests (NEW)

- **`tests/test_gates_ui_parity.sh`** (NEW, 212 lines) — Five-scenario
  parity gate driving `tekhton gate ui` against captured baselines.
  21 assertions, all passing. Reuses `tests/lib/parity.sh`. Scenarios:
  - `ui_clean` — UI_TEST_CMD exits 0; no error files emitted.
  - `ui_assertion_fail` — exit 1 with assertion text; generic retry
    attempted; failure-path artifacts written (byte-identical).
  - `ui_interactive_report` — exit 124 + HTML-report marker → hardened
    rerun attempted; diagnosis block reports
    `Timeout class: interactive_report` and
    `Hardened rerun attempted: yes`.
  - `ui_generic_timeout` — exit 124 without marker;
    `UI_GATE_ENV_RETRY_ENABLED=false` so no hardened rerun;
    `Timeout class: generic_timeout` / `Hardened rerun attempted: no`.
  - `ui_framework_detect` — 5 sub-assertions covering the P0-P4 priority
    cascade via `tekhton gate ui --print-framework`.

### Test fixtures (NEW)

- `tests/testdata/gates/ui_assertion_fail/expected/{UI_TEST_ERRORS.md,BUILD_ERRORS.md,BUILD_RAW_ERRORS.txt}`
- `tests/testdata/gates/ui_interactive_report/expected/{UI_TEST_ERRORS.md,BUILD_ERRORS.md,BUILD_RAW_ERRORS.txt}`
- `tests/testdata/gates/ui_generic_timeout/expected/{UI_TEST_ERRORS.md,BUILD_ERRORS.md,BUILD_RAW_ERRORS.txt}`
- Timestamp normalisation via the parity gate's `_ui_normalise` sed
  callback collapses the `# UI Test Errors — YYYY-MM-DD HH:MM:SS` and
  `# Build Errors — YYYY-MM-DD HH:MM:SS` headers to `TIMESTAMP` before
  diffing.

### Other updates

- **`internal/stagerunner/helpers.go`** — `DefaultLibHelpers` dropped
  `lib/gates_ui_helpers.sh` and `lib/gates_ui.sh`. Parity test still
  passes.
- **`scripts/wedge-audit-patterns.sh`** — Added m31.2 forbidden patterns:
  the source-line patterns for the two deleted bash files plus the eight
  bash function names (`_run_ui_test_phase`, `_ui_run_cmd`,
  `_ui_detect_framework`, `_ui_deterministic_env_list`,
  `_normalize_ui_gate_env`, `_ui_timeout_signature`,
  `_ui_hardened_timeout`, `_ui_write_gate_diagnosis`). Wedge audit
  reports clean (192 files audited).
- **`ARCHITECTURE.md`** — Updated the `internal/gates/` entry to cover
  the m31.2 UI gate addition + the `WriteUIFailure` / `WriteUIDiagnosis`
  errors writer additions. Updated `cmd/tekhton/gate.go` entry to cover
  the new `--print-framework` flag and `uiPhaseFromEnv`. Updated
  `tekhton-legacy.sh` entry to note all five gates*.sh are now gone.
  Replaced the `lib/gates_ui_helpers.sh` entry with an HTML comment
  marking the m31.2 deletion. Updated the `lib/test_dedup.sh` sourcing
  note (no longer sourced after the deleted gates_ui*.sh block).
- **`docs/v4-phase5-stub.md`** — Added a new row 13a for the m31 arc
  (`gates*.sh`, done m31 — five files deleted). Added an `End of Phase
  5 m31.2` row to the LOC table.
- **`VERSION`** — Bumped to `4.31.0` (parent-arc bump on m31.2 close).

## Root Cause (bugs only)
N/A — feature port milestone.

## Files Modified

### Created (NEW)
- `internal/gates/ui.go` (NEW) — Native `UIPhase` implementation
- `internal/gates/ui_helpers.go` (NEW) — Pure helpers
- `internal/gates/ui_test.go` (NEW) — `UIPhase` test coverage
- `internal/gates/ui_helpers_test.go` (NEW) — Helper test coverage
- `tests/test_gates_ui_parity.sh` (NEW) — Parity gate
- `tests/testdata/gates/ui_assertion_fail/expected/UI_TEST_ERRORS.md` (NEW)
- `tests/testdata/gates/ui_assertion_fail/expected/BUILD_ERRORS.md` (NEW)
- `tests/testdata/gates/ui_assertion_fail/expected/BUILD_RAW_ERRORS.txt` (NEW)
- `tests/testdata/gates/ui_interactive_report/expected/UI_TEST_ERRORS.md` (NEW)
- `tests/testdata/gates/ui_interactive_report/expected/BUILD_ERRORS.md` (NEW)
- `tests/testdata/gates/ui_interactive_report/expected/BUILD_RAW_ERRORS.txt` (NEW)
- `tests/testdata/gates/ui_generic_timeout/expected/UI_TEST_ERRORS.md` (NEW)
- `tests/testdata/gates/ui_generic_timeout/expected/BUILD_ERRORS.md` (NEW)
- `tests/testdata/gates/ui_generic_timeout/expected/BUILD_RAW_ERRORS.txt` (NEW)

### Modified
- `cmd/tekhton/gate.go` — Replaced gate ui stub with real RunE; added
  `--print-framework` flag; added `uiPhaseFromEnv` + `envFloat`; swapped
  the `ui_test` factory in `buildGateFromEnv` to use `uiPhaseFromEnv`
- `cmd/tekhton/gate_test.go` — Replaced the stub-returns-error assertion
  with two `TestGateUI_*` skip-path tests
- `internal/gates/phases.go` — Removed `UIBashShim` + `BashShimRunner`
- `internal/gates/phases_test.go` — Removed `TestUIBashShim_SkipsWhenCmdUnset`
- `internal/gates/coverage_test.go` — Swapped `UIBashShim` for `UIPhase`,
  removed three `TestUIBashShim_*` tests + the `bashRunnerFunc` adapter,
  added UI methods to `TestNoopErrorsWriter_Methods`
- `internal/gates/errors_writer.go` — Added `WriteUIFailure` +
  `WriteUIDiagnosis` to the interface, implemented on `FSErrorsWriter`
  and `NoopErrorsWriter`; added the `tailLines` helper
- `internal/gates/errors_writer_test.go` — Added 5 new tests for the UI
  failure-path writers
- `internal/gates/build_test.go` — Extended `captureWriter` with UI
  fields and methods
- `internal/gates/runner.go` — Added `UIEnvRunner` + `runBashCmd` helper
  shared with `ExecRunner`
- `internal/gates/completion_test.go` — gofmt-driven whitespace fix
  only (incidental)
- `internal/gates/remediation.go` — gofmt-driven whitespace fix only
  (incidental)
- `internal/stagerunner/helpers.go` — Dropped the two `lib/gates_ui*.sh`
  entries from `DefaultLibHelpers`
- `tekhton-legacy.sh` — Removed the two `source lib/gates_ui*.sh` lines
- `scripts/wedge-audit-patterns.sh` — Added m31.2 forbidden patterns
- `tests/test_file_size_ceilings.sh` — Extended the deletion invariant
  to all five gates*.sh files
- `tests/test_ui_gate_force_noninteractive.sh` — Added skip guard
- `tests/test_m138_coverage_gaps.sh` — Skip GAP-2 when gates_ui_helpers.sh missing
- `tests/test_gates_parity.sh` — Bound `TEKHTON_BIN` to in-repo path
- `ARCHITECTURE.md` — Gates entries updated for m31.2
- `docs/v4-phase5-stub.md` — Added m31 arc row + LOC table entry
- `VERSION` — `4.30.8` → `4.31.0`

### Deleted
- `lib/gates_ui.sh` (183 lines, ported to `internal/gates/ui.go`)
- `lib/gates_ui_helpers.sh` (190 lines, ported to
  `internal/gates/ui_helpers.go`)
- `cmd/tekhton/gate_ui_shim.go` (m31.1's bash-shim entry point)

## Test Results
- **Go**: `go test ./internal/gates/ ./cmd/tekhton/` PASS;
  `internal/gates/` coverage 85.8% of statements (above the 80%
  acceptance target).
- **`go vet ./...`**: clean.
- **`gofmt`**: clean.
- **`shellcheck -S warning`** on all touched bash files: clean.
- **Bash**: `bash tests/run_tests.sh` reports 502 shell PASS + all 26 Go
  packages PASS (was 501 before m31.2; the new `test_gates_ui_parity.sh`
  adds one count).
- **Wedge audit**: clean (192 files audited).
- **`test_gates_parity.sh`**: 16/16 PASS across 11 scenarios (no
  regression from the m31.1 baseline).
- **`test_gates_ui_parity.sh`**: 21/21 PASS across 5 scenarios.

## Human Notes Status
No human notes referenced for m31.2.

## Docs Updated
- `ARCHITECTURE.md` — `internal/gates/` entry expanded for UIPhase +
  helpers + errors-writer additions; `cmd/tekhton/gate.go` entry expanded
  for `--print-framework` + `uiPhaseFromEnv`; `tekhton-legacy.sh` entry
  notes the m31 arc closes with five files deleted; `lib/test_dedup.sh`
  sourcing note updated; the deleted `lib/gates_ui_helpers.sh` entry
  replaced with an HTML deletion-marker comment.
- `docs/v4-phase5-stub.md` — Added row 13a (`gates*.sh`, done m31) and
  an `End of Phase 5 m31.2` LOC entry.
