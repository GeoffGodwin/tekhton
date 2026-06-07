# Coder Summary

## Status: COMPLETE

## What Was Implemented

Milestone **m47 — Stage Verdict Envelope is the Source of Truth: Stop Letting
Subprocess Errors Override a PASS Verdict**. Three changes that together
prevent the m38.4 + m46 manifest false-failure pattern (auto-advance runs on
2026-06-06 / 2026-06-07 where the reviewer emitted APPROVED_WITH_NOTES but
the pipeline reported `disposition: failure / error_class: review` because a
post-verdict sub-call returned a Go-level error that overrode the envelope).

### Goal 1 — Source-level reclassification of return-err sites in review

Audited every `return nil, err` site in `internal/stages/review/`. Each is
either pre-parse infrastructure (stays as error return — runner needs the
structural signal) or post-parse subprocess failure (converts to
`Metadata["subprocess_warnings"]` envelope warning + returns the originally-
parsed verdict's envelope with `err == nil`).

**Converted site (the m47 culprit):** `specialist.go:111` — the post-
specialist `runOneCycle` error inside the SpecialistRework branch. Pre-m47
this overrode an originally-parsed APPROVED verdict whenever the specialist
runner spawned a post-specialist reviewer cycle that itself failed. Post-m47
it appends to `subprocess_warnings` and returns `approvedResult(report)` with
nil error. The specialist runner error path (line 49) and the
`invokeCoderRework` / `invokeBuildFixMinimal` failure paths in the rework
branch are now also recorded as subprocess warnings (they were already log-
only no-ops, now they leave a machine-readable trace).

**Annotated pre-parse sites (no behavior change):** six sites in `cycle.go`
(invokeReviewerAgent, synthesizeMinimalReport, ParseReviewerReport,
triggerReplan, render reviewer prompt, write reviewer prompt) and one in
`run.go` (runOneCycle err propagation in the main cycle loop). Each
carries an `// m47 classification: pre-parse ...` comment so the contract
is visible inline — m38.6 (tester port) inherits the same audit
requirement.

**Hard fail preserved:** the `post-specialist-retry` build gate failure
path at `specialist.go:104` is intentionally kept as `failResult(...)`
per the m47 Watch For — when the build is broken AND a corrective coder
pass failed to fix it, the only correct verdict is fail.

### Goal 2 — Adapter-level envelope-over-error gate (defense-in-depth)

`internal/stagerunner/adapter.go::runGo()`: when a GoImpl returns BOTH a
non-nil `*StageResultV1` AND a non-nil error, the adapter logs to stderr,
records the error message on `result.Metadata["subprocess_warning"]`
(singular — adapter-level), clears the error to nil, and returns the
envelope. Future stage-code regressions can never silently override an
emitted verdict — even if a stage author forgets to follow the Goal 1
classification rule, the adapter catches the leak before the runner sees it.

### Envelope schema

Added `Metadata map[string]string` to `proto.StageResultV1` with two
reserved keys documented in the type comment:

- `subprocess_warnings` (plural — used by stage code via
  `appendSubprocessWarning`): JSON-array string format; multiple warnings
  append, never overwrite.
- `subprocess_warning` (singular — used by the adapter gate): single-string
  fallback for the defense-in-depth path.

New file `internal/stages/review/warnings.go` (48 lines): the
`appendSubprocessWarning(res, msg)` helper that future Go stages copy.
Hermetic JSON marshalling — falls back to a scalar value if the prior
field is malformed, so the field is always observable.

### Goal 3 — Regression tests

Four new tests:

- **`TestRunStage_PreservesPassEnvelopeOnSpecialistReworkFailure`**
  (run_test.go) — end-to-end RunStage drive: APPROVED verdict, specialist
  blockers, build gate flake on post-specialist-rework then recover on
  retry. Pre-m47 this combination returned `(nil, err)`; post-m47 it
  returns the pass envelope.
- **`TestRunStage_RecordsSubprocessWarningOnPostSpecialistCycleError`**
  (run_test.go) — exercises the exact specialist.go:111 site the
  classification table calls out. Reviewer cycle 1 = APPROVED, specialist
  returns blockers, post-specialist reviewer cycle errors. Asserts
  verdict=pass + `Metadata["subprocess_warnings"]` contains
  `post_specialist_cycle` as a JSON-list entry.
- **`TestFinalizeApproved_SpecialistRunnerErrorDoesNotOverrideVerdict`**
  (specialist_test.go) — directly drives `finalizeApproved` with a
  specialist runner that errors. Asserts the approved verdict survives
  and the runner error is recorded as a single subprocess_warnings entry.
- **`TestAdapter_GoImplBothResultAndErrorPrefersResult`**
  (adapter_test.go) — drives the adapter-level gate. GoImpl returns both
  a pass result and an error; asserts the adapter clears err to nil and
  populates `Metadata["subprocess_warning"]`.

Plus the shim-boundary test:

- **`tests/test_stage_envelope_overrides_subprocess_err.sh`** (new, 165
  lines, shellcheck-clean, skips cleanly when the binary isn't built) —
  drives `tekhton stage emit` to verify the envelope JSON shape carries
  the new Metadata field; hand-authors a Metadata-bearing envelope to
  verify the m47 plural-key contract (subprocess_warnings as a JSON-array
  string) parses cleanly; back-compat check that envelopes without
  Metadata still round-trip. 9 assertions, all pass.

## Root Cause (bugs only)

The Go-side review stage (`internal/stages/review/` — ported in m37.2) had
eight `return nil, err` sites. The runner translates a non-nil Go error
into `disposition: failure / error_class: review`. After cycle 1 produces
an APPROVED verdict, the `finalizeApproved` path runs the specialist post-
loop branch. If that branch needs a post-specialist reviewer cycle and that
cycle hits any error (agent dispatch failure, render error, transient
infra), `specialist.go:111`'s `return nil, err` propagated the failure up
through stagerunner as `ErrSubprocess`, the runner recorded `disposition:
failure`, and the manifest entry for the milestone never flipped to done —
even though the originally-parsed verdict was clean APPROVED_WITH_NOTES.
Two consecutive auto-advance dogfood runs (m38.4 on 2026-06-06, m46 on
2026-06-07) tripped this and required manual milestone flips.

## Files Modified

- `internal/proto/stage_v1.go` — add `Metadata map[string]string` field
  to `StageResultV1` with the two reserved-key documentation.
- `internal/stages/review/warnings.go` (NEW, 48 lines) — `appendSubprocessWarning`
  helper for the m47 plural-key envelope contract.
- `internal/stages/review/specialist.go` — convert the post-specialist
  `runOneCycle` err return into a warning + approvedResult; record other
  sub-call failures (append section, coder rework, build_fix_minimal) as
  subprocess_warnings; preserve the post-specialist-retry hard-fail path.
- `internal/stages/review/cycle.go` — annotation-only: add `// m47
  classification: pre-parse ...` comments to the six pre-parse return-err
  sites confirming intentional retention.
- `internal/stages/review/run.go` — annotation-only: add same comment to
  the cycle-loop runOneCycle err propagation.
- `internal/stagerunner/adapter.go` — add the envelope-over-error
  defense-in-depth gate in `runGo()`.
- `internal/stages/review/run_test.go` — two new RunStage end-to-end tests
  for the m47 contract.
- `internal/stages/review/specialist_test.go` — new finalizeApproved test
  for the specialist-runner-error path.
- `internal/stagerunner/adapter_test.go` — new test for the adapter gate.
- `tests/test_stage_envelope_overrides_subprocess_err.sh` (NEW, 165 lines)
  — shim-boundary integration test, 9 assertions, shellcheck-clean.
- `docs/v4-phase5-stub.md` — document the envelope-over-error principle
  under the Stage-Port Matrix so m38.6 (tester port) and m39 (coder port)
  inherit the classification rule.

## Docs Updated

- `docs/v4-phase5-stub.md` — new "m47 — Envelope-over-error rule for
  every Go-impl stage" subsection under Stage-Port Matrix. Documents the
  two reserved Metadata keys, the pre-parse vs post-parse classification
  rule, the hard-fail exception, and the explicit m38.6 (tester) inheritance
  requirement.

`StageResultV1`'s new `Metadata` field is part of the public
`internal/proto/` surface (cross-language envelope contract), documented
inline via the type doc comment. No external CLI flags changed.

## Human Notes Status

N/A — no actionable human notes were attached to this task. The
CLARIFICATIONS.md content shown in the run context contains only stale
clarification sessions from prior unrelated runs (Watchtower dashboard,
NON_BLOCKING_LOG, brownfield --init flow) that the human had self-answered
with restatements of the questions. None applied to m47.
