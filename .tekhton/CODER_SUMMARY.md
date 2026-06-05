# Coder Summary

## Status: COMPLETE

## What Was Implemented

m36.2 — Intake Helpers Port. Two bash files (`lib/intake_helpers.sh` and
`lib/intake_verdict_handlers.sh`) ported to a new `internal/intake/` Go
package. The bash files are now thin wedge shims that exec into a Hidden
`tekhton intake helpers|verdict ...` Cobra subcommand tree. Operator
vocabulary preserved byte-for-byte as Go constants.

### Go surface — `internal/intake/`

- `helpers.go` (508 LOC) — `Helpers` struct with 11 methods covering the
  full lib/intake_helpers.sh API: `ContentHash`, `ShouldSkip`, `SaveHash`,
  `ParseVerdict` (normalize + fallback to PASS), `ParseConfidence`
  (clamp 0..100), `ParseTweaks`, `ParseQuestions`, `MilestoneContent`
  (DAG-first with inline-CLAUDE.md fallback via `MilestoneFileResolver`
  seam), `ApplyTweakMilestone` (50% size guard with 20-line floor,
  atomic mv + `.pre-tweak` backup, REJECTED_TWEAK.md side-write on
  reject, `ErrTweakRejected` sentinel), `ApplyTweakTask` (persists
  to INTAKE_TWEAKED_TASK.md for resume), `AddPMMetadata` (atomic
  insert/update of `<!-- PM-tweaked: YYYY-MM-DD -->` comment).
- `verdict.go` (500 LOC) — `VerdictHandler` struct with 3 methods
  (`HandleTweaked`, `HandleSplitRecommended`, `HandleNeedsClarity`).
  Operator-facing constants block at the top (`MsgTweaksRejected`,
  `MsgClarifyCompleteHalt`, etc.) is the canonical source of every
  bash-era stderr line. Injected dependencies: `PipelineState`,
  `Split`, `Switch`, `ClarifyHandle`, Stdin/Stdout/Stderr seams.
  `ErrHalt` sentinel maps to bash exit-1 + write_pipeline_state.
- `date.go` + `timestamp.go` — pinnable time providers for tests.

### Operator-vocabulary preservation

Eleven `Msg*` constants in `verdict.go` carry the exact bash strings.
Two regression tests gate them:

- `TestRejectionMessageByteIdentity` — drives the full TWEAKED → reject
  flow and asserts the literal `"Tweaks rejected by user. Saving state."`
  appears in stderr and the PipelineState seam fires with the exact bash
  exit reason + message.
- `TestClarificationsFileFormat` — drives NEEDS_CLARITY through to
  CLARIFICATIONS.md and diffs against `testdata/clarifications_golden.md`
  after timestamp normalization.
- `TestBashShimDoesNotRedefineStrings` — guards the inversion in the
  other direction: the bash shim files must NOT contain literal operator
  text (the strings live only in Go now).

### Transition CLI shim — `cmd/tekhton/intake.go`

Hidden `tekhton intake helpers|verdict ...` subcommand tree (454 LOC).
Eleven helpers subcommands (one per Helpers method) plus three verdict
subcommands. State-write coordination: when a verdict handler hits
`ErrHalt`, the Go shim writes a tab-separated row to
`$TEKHTON_INTAKE_STATE_OUT` and exits 1; the bash wrapper reads the
sentinel and forwards to `write_pipeline_state` so the resume contract
is preserved across the wedge boundary. **Lifetime: m36.2 → m36.3 only**
— file is deleted in m36.3 alongside the bash shims and `stages/intake.sh`.

### Bash shims (NOT deleted in m36.2)

- `lib/intake_helpers.sh` — 113 LOC, 11 functions, all bodies are
  one-line execs into `tekhton intake helpers ...`.
- `lib/intake_verdict_handlers.sh` — 35 LOC, 3 functions, all bodies
  call a shared `_intake_invoke_verdict` private helper that runs the
  Go CLI and forwards state on halt.

Function names + signatures + exit codes + stdout shapes preserved
byte-for-byte. `stages/intake.sh` is unchanged and continues to call
the shimmed functions by name.

### Tests + parity gate

- `internal/intake/helpers_test.go` (363 LOC, 17 tests) — content hash
  round-trip, verdict parsing (4 happy + 3 fallback), confidence clamp,
  tweaks/questions extraction, **size-guard reject regression**,
  size-guard accept, small-milestone bypass (≤20 lines), PM-metadata
  insert (3 variants), apply-task happy + empty, milestone-content
  DAG/inline/non-milestone-mode.
- `internal/intake/verdict_test.go` (391 LOC, 12 tests) —
  **rejection-message byte identity**, tweaked accepted non-interactive,
  **clarifications-file golden**, complete-mode halt, split auto-split,
  split interactive s/c/q, no-questions warning, abort path,
  missing-report graceful, split-auto-failed fallback, readChoice
  fallback + TTYReader, stripQuestionTags table.
- `cmd/tekhton/intake_test.go` — 5 CLI smoke tests: Hidden visibility,
  parse-verdict for all 4 fixtures, content-hash via stdin,
  parse-confidence numeric, should-skip exit-code contract.
- `tests/test_intake_bash_passthrough.sh` (NEW, 180 LOC, 10 assertions)
  — drives all 4 verdict fixtures end-to-end through the bash shim
  into the Go CLI. Includes the NEEDS_CLARITY + COMPLETE_MODE halt
  path with state-forwarding assertion. Deleted in m36.3.

### Coverage

- `internal/intake/`: 80.0% (meets ≥80% acceptance threshold).

### Verification

- `go build ./...` clean.
- `go vet ./...` clean.
- `go test ./...` all packages pass.
- `bash tests/run_tests.sh` reports 512 / 0 (m36.1 baseline 511, +1 for
  the new `test_intake_bash_passthrough.sh`).
- `bash scripts/wedge-audit.sh` clean (193 files, 12 allowed shim writers).
- `shellcheck lib/intake_*.sh tests/test_intake*.sh` clean.
- `tests/test_intake.sh` updated to pin `TEKHTON_BIN` to the local build
  (matches the `test_notes_parity.sh` pattern) — all 38 existing tests
  still pass.
- `internal/stagerunner/parity_test.go::TestBashAdapterRealHelperIntegration`
  updated to set `BashAdapter.TekhtonBin` so the shimmed
  `_intake_content_hash` finds the Go binary.

### Bash residues

- `lib/intake_helpers.sh` — kept (now a 113-LOC shim).
- `lib/intake_verdict_handlers.sh` — kept (now a 35-LOC shim).
- `cmd/tekhton/intake.go` — kept (Hidden transition CLI).
- All three delete together in m36.3 when the in-process stage port lands.

## Root Cause (bugs only)

N/A — m36.2 is a Ship-of-Theseus port milestone, not a bug fix.

## Architecture Change Proposals

None — m36.2 follows the m17 wedge-shim pattern verbatim
(`lib/errors.sh` → `tekhton diagnose ...` is the canonical reference).
The state-sentinel pattern for verdict-handler halt coordination is a
new local invention (TSV file at `$TEKHTON_INTAKE_STATE_OUT`) but
falls under the established "bash shim forwards to Go binary; halt is
exit-1 + shim writes pipeline state" envelope, no new architectural
constraint introduced.

## Design Observations

None.

## Files Modified

- `internal/intake/helpers.go` (NEW)
- `internal/intake/verdict.go` (NEW)
- `internal/intake/date.go` (NEW)
- `internal/intake/timestamp.go` (NEW)
- `internal/intake/helpers_test.go` (NEW)
- `internal/intake/verdict_test.go` (NEW)
- `internal/intake/testdata/report_pass.md` (NEW)
- `internal/intake/testdata/report_tweaked.md` (NEW)
- `internal/intake/testdata/report_split.md` (NEW)
- `internal/intake/testdata/report_needs_clarity.md` (NEW)
- `internal/intake/testdata/milestone_long.md` (NEW)
- `internal/intake/testdata/clarifications_golden.md` (NEW)
- `cmd/tekhton/intake.go` (NEW — Hidden transition shim, deleted in m36.3)
- `cmd/tekhton/intake_test.go` (NEW)
- `cmd/tekhton/main.go` — registered `newIntakeCmd()` in root
- `lib/intake_helpers.sh` — rewritten as 113-LOC shim, 11 functions preserved
- `lib/intake_verdict_handlers.sh` — rewritten as 35-LOC shim, 3 functions preserved
- `tests/test_intake_bash_passthrough.sh` (NEW — deleted in m36.3)
- `tests/test_intake.sh` — pinned `TEKHTON_BIN` for wedge-aware run
- `internal/stagerunner/parity_test.go` — updated `TestBashAdapterRealHelperIntegration`
  to set `BashAdapter.TekhtonBin` (the shimmed helper now execs Go)
- `docs/v4-phase5-stub.md` — intake helpers row updated to "shimmed (m36.2)";
  closeout paragraph added covering the helpers / verdict split and the
  LOC budget (−471 bash logic / +1008 Go)
- `VERSION` — 4.43.6 → 4.44.0

## Docs Updated

- `docs/v4-phase5-stub.md` — long-tail row 23 marked shimmed; new m36.2
  closeout paragraph explaining the helpers-half / stage-half split, the
  operator-vocabulary preservation pattern, and the LOC budget.

## Observed Issues (out of scope)

- `make lint` fails with a vendor-cache typecheck error
  (`vendor/golang.org/x/crypto/chacha20poly1305/fips140only_go1.26.go`
  requires Go 1.26 against a 1.23 build). This is a system-Go-installation
  issue, not project code — the error reproduces on isolated files
  outside the project. Recording per coder.md's "out-of-scope issues"
  guidance; not addressed here.

## Human Notes Status

No active human notes in HUMAN_NOTES.md — none to claim.

## Remaining Work

None. All acceptance criteria met:

- [x] `internal/intake/helpers.go` exports `Helpers` with 11 methods (grep
  returns 11)
- [x] `internal/intake/verdict.go` exports `VerdictHandler` with 3 Handle*
  methods (grep returns 3)
- [x] Operator-facing constants exist in `verdict.go` and the
  `TestBashShimDoesNotRedefineStrings` test asserts the bash shims do
  not redefine them (inversion guard)
- [x] `TestApplyTweakMilestone_SizeGuardReject` passes — 100-line ms +
  10-line tweak → `ErrTweakRejected`, original unchanged, REJECTED_TWEAK.md
  written
- [x] `TestRejectionMessageByteIdentity` passes — stderr contains the
  exact bash rejection string and PipelineState fires with the exact
  exit reason + message
- [x] `TestClarificationsFileFormat` passes — CLARIFICATIONS.md
  byte-identical to `testdata/clarifications_golden.md` after timestamp
  normalization
- [x] `cmd/tekhton/intake.go` registers `tekhton intake helpers|verdict`
  as Hidden subcommands; `parse-verdict` prints the correct verdict for
  all 4 fixtures
- [x] `lib/intake_helpers.sh` has exactly 11 functions matching
  `^[a-z_]+\(\) {$`
- [x] `lib/intake_verdict_handlers.sh` has exactly 3 functions matching
  the same regex
- [x] `stages/intake.sh` runs end-to-end against the 4 verdict fixtures
  via `tests/test_intake_bash_passthrough.sh` (10 assertions, all pass)
- [x] Bash shim files NOT deleted in m36.2 (`test -f` both succeeds)
- [x] `go test ./internal/intake/... ./cmd/tekhton/...` passes with
  80.0% coverage on `internal/intake/`
- [x] `bash tests/run_tests.sh` reports 512 / 0 (m36.1 baseline 511 + 1
  new test file = expected delta, zero new failures)
- [x] `bash scripts/wedge-audit.sh` exits 0
- [x] `docs/v4-phase5-stub.md` intake helpers row marked shimmed; LOC
  delta table shows −471 bash / +1008 Go
- [x] `VERSION` bumped (4.43.6 → 4.44.0)
