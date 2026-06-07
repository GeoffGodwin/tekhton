<!-- milestone-meta
id: "47"
status: "todo"
-->

# m47 — Stage Verdict Envelope is the Source of Truth: Stop Letting Subprocess Errors Override a PASS Verdict

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Two consecutive auto-advance runs (m38.4 on 2026-06-06, m46 on 2026-06-07) finished with the reviewer agent emitting `APPROVED_WITH_NOTES` and **zero blockers**, but the pipeline reported `disposition: failure, error_class: review, "stagerunner: subprocess failed\nexit status 1"`. The work was correct, the verdict was a clean PASS, the manifest still didn't flip done. The operator did the manual-flip dance twice. The root cause is that the Go review stage propagates *any* subprocess error from its sub-calls (specialist runner, build gate, even the agent infra after the report has been parsed) as a `return nil, err`, which stagerunner wraps as `ErrSubprocess` and the pipeline treats as a failure outcome. The verdict envelope — which the agent and the m37.1 parser both produced cleanly — gets silently overridden. This is the design bug the operator named: *"the way we're calculating pass/fail is bad and we should revisit it."* |
| **Gap** | After m37.2 ported review to Go, `internal/stages/review/` has eight `return nil, err` / `return nil, fmt.Errorf(...)` sites (cycle.go:62, 103, 115, 124, 157, 161; run.go:94; specialist.go:111, 119). Several of them fire AFTER the reviewer report has been parsed and the verdict is known — i.e., after the stage has all the information it needs to decide PASS. The specialist-rework branch (`specialist.go:111`) and the rework build-gate escalation (`rework.go:53`) are the most likely culprits in the observed runs: when the agent's report says APPROVED, the specialist runner may still spin (security agent invoked, finds something, blockers populated), the rework path runs, the build gate exits non-zero, and the WHOLE STAGE returns a Go error — even though the originally-parsed verdict was APPROVED_WITH_NOTES. The stage envelope (`StageResultV1`) was designed to carry verdict + ExitReason + Metadata; using a Go-level error to abort the stage is a leak through the seam the envelope is supposed to seal. |
| **m47 fills** | A single principle applied across `internal/stages/review/`, `internal/stages/tester/` (when m38.6 lands), and any future stage that follows the GoImpl pattern: **once the agent has emitted a parseable verdict, the stage MUST return a non-nil `*StageResultV1` reflecting that verdict, even if downstream sub-calls (build gate, specialist runner, file ops) fail.** Failures from those sub-calls record as `Metadata["subprocess_warnings"]` JSON list entries on the envelope; they do NOT cause the stage to return a Go-level error. The narrow exceptions — infrastructure errors before the verdict is known (agent infra exec fails, report file unreadable, render-prompt failure on first cycle) — still return errors. Adds an envelope-level audit gate in `internal/stagerunner/adapter.go` that detects "GoImpl returned both a non-nil result AND a non-nil error" and prefers the result (the envelope's verdict wins) while logging the error to stderr. Adds three regression tests driving the observed-failure shape. |
| **Depends on** | m37.2 (the review stage's Go port that introduced the eight return-err sites), m46 (the loud warn at `_hook_commit`'s skip sites — without m46 this bug would still be invisible to operators) |
| **Files changed** | `internal/stages/review/cycle.go`, `internal/stages/review/run.go`, `internal/stages/review/specialist.go`, `internal/stages/review/rework.go`, `internal/stagerunner/adapter.go`, `internal/stages/review/run_test.go`, `internal/stages/review/specialist_test.go`, `internal/stagerunner/adapter_test.go`, `tests/test_stage_envelope_overrides_subprocess_err.sh` (new) |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m37.2 | Review stage ported to Go; introduces the eight `return nil, err` sites that m47 audits. |
| m41 | Finalize: stop false-blocking commit when milestone block can't be populated |
| m42 | Preflight: guard against no-op TEST_CMD |
| m43 | Version-bump completeness |
| m44 | Commit subject regression: stop falling back to `.claude/project_version.cfg` |
| m45 | Completion gate: stop false-halting on transient TEST_CMD failure |
| m46 | Replan detector body-grep + commit-skip cascade — added the loud warn that surfaced this bug |
| **m47** | **Stage verdict envelope is source of truth: subprocess errors from sub-calls do not override a PASS verdict** |

---

## Design

### Sequencing note

m47 is independent of the m38 stage-port arc. Land it before m38.5 if possible
— without m47, m38.5 and m38.6 are exposed to the same pass/fail-calculation
shape that bit m38.4 and m46. After m47 lands, the auto-advance chain becomes
self-sustaining: stage envelope decides verdict, sub-call errors are
observable but non-fatal, manifest flips correctly, commits fire with proper
`[MILESTONE X.Y ✓]` subjects.

### Core principle

> Once the agent has produced a parseable verdict envelope, the stage
> MUST return that envelope. Any post-parse sub-call failures attach to
> the envelope as `subprocess_warnings` metadata; they do NOT short-circuit
> with a Go-level error.

This sets up a clean seam: the envelope's `Verdict` field is the sole
determinant of stage pass/fail. The runner reads `result.Verdict`, not
`result.error`, to compute disposition.

### Goal 1 — Audit and reclassify return-err sites in the review stage

**Files:** `internal/stages/review/cycle.go`, `run.go`, `specialist.go`, `rework.go`.

For each of the eight current return-err sites, classify as:

- **Pre-parse infrastructure error** — agent exec fails, prompt render fails,
  reviewer report file unreadable. These STAY as `return nil, err`. The
  stage has no parseable verdict and the runner needs to know.
- **Post-parse subprocess error** — specialist runner errored, build gate
  exited non-zero, file-system op failed. These convert to envelope
  warnings: record the error message in `Metadata["subprocess_warnings"]`
  and continue to the envelope-emission point.

Concrete classifications (line numbers are approximate — locate by name):

| Site | File:Line | Today | After m47 |
|---|---|---|---|
| invokeReviewerAgent error | cycle.go:62 | return err | **stays** — pre-parse infra |
| synthesize minimal report | cycle.go:103 | return err | **stays** — synthesize is itself the envelope; if it fails, we have no envelope |
| ParseReviewerReport error | cycle.go:115 | return err | **stays** — pre-parse |
| triggerReplan error | cycle.go:124 | return err | **stays** — replan is an out-of-band user dialog; failure here is structural |
| render reviewer prompt | cycle.go:157 | return err | **stays** — pre-parse |
| write reviewer prompt | cycle.go:161 | return err | **stays** — pre-parse |
| runOneCycle error in RunStage | run.go:94 | return err | **stays** — propagates the above |
| specialist rework error | specialist.go:111 | return err | **converts** — verdict known, record warning, return envelope |

The actual culprit for the observed runs is the specialist-rework path at
`specialist.go:111`. The rework's build-gate escalation can exit non-zero
even when the originally-parsed verdict was APPROVED_WITH_NOTES; today
that error overrides the verdict. After m47, that error becomes a
`Metadata["subprocess_warnings"]` entry on an envelope whose `Verdict`
is still `pass`.

### Goal 2 — Adapter-level safety net: prefer envelope over error

**File:** `internal/stagerunner/adapter.go`.

Add a defense-in-depth gate at the GoImpl dispatch site:

```go
res, err := def.GoImpl(ctx, req)
// m47 — Envelope-over-error rule. A stage that has produced a parseable
// StageResultV1 has implicitly emitted its verdict; downstream callers
// (runner, finalize-hook chain) MUST use that verdict, not a Go-level
// error from a sub-call. Without this gate, a single failing subprocess
// inside the stage (build gate exit-1, specialist runner exec error)
// silently overrides an APPROVED_WITH_NOTES verdict — the m38.4 +
// m46 false-failure pattern observed 2026-06-06 / 2026-06-07.
if res != nil && err != nil {
    fmt.Fprintf(os.Stderr,
        "stagerunner: %s emitted both StageResult (verdict=%s) and "+
        "error (%v) — preferring envelope, discarding error\n",
        req.Stage, res.Verdict, err)
    // Record the discarded error on the envelope so it's observable.
    if res.Metadata == nil {
        res.Metadata = map[string]string{}
    }
    res.Metadata["subprocess_warning"] = err.Error()
    err = nil
}
```

This is intentionally defense-in-depth: Goal 1's source-level
classifications eliminate the offending paths, but the adapter gate
catches future regressions before they reach the operator.

### Goal 3 — Regression tests

**File:** `internal/stages/review/run_test.go` — add `TestRunStage_PreservesPassEnvelopeOnSpecialistRework Failure`:

- Stub the agent to return APPROVED_WITH_NOTES.
- Stub the specialist runner to populate blockers.
- Stub the build-gate runner to return a non-nil error.
- Assert: `RunStage` returns `res != nil`, `err == nil`,
  `res.Verdict == VerdictPass`, `res.Metadata["subprocess_warnings"]`
  contains the build-gate error.

**File:** `internal/stages/review/specialist_test.go` — add
`TestFinalizeApproved_SpecialistRunnerErrorDoesNotOverrideVerdict`:

- specialistRunner.Run returns `nil, errors.New("specialist exec failed")`.
- Assert: returns approvedResult (verdict pass), error recorded in
  Metadata, no Go-level error.

**File:** `internal/stagerunner/adapter_test.go` — add
`TestAdapter_GoImplBothResultAndErrorPrefersResult`:

- Stub GoImpl to return both a non-nil result with Verdict=Pass AND a
  non-nil error.
- Assert: adapter discards the error and returns the result;
  `res.Metadata["subprocess_warning"]` contains the discarded error
  message.

**File:** `tests/test_stage_envelope_overrides_subprocess_err.sh` (new,
~90 lines). Shim-boundary integration test that drives an actual
`tekhton run --milestone <fixture>` against a project setup where the
build gate is forced to exit 1, asserts the pipeline result reports
`disposition: success` not `disposition: failure`, and the milestone
manifest flips done.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/stages/review/specialist.go` | Modify | Convert the `return nil, err` at the SpecialistRework branch (line ~111) into an envelope warning + return approvedResult. |
| `internal/stages/review/rework.go` | Modify | Audit the `buildGateRunner.Run` error returns; surface as Metadata warnings rather than propagating up. |
| `internal/stages/review/cycle.go` | Modify (annotation only) | Add comments to the seven pre-parse return-err sites confirming they're INTENTIONALLY error-returning per m47 classification. |
| `internal/stages/review/run.go` | Modify (annotation only) | Same — line 94 comment confirming runOneCycle propagation is the intended pre-parse path. |
| `internal/stagerunner/adapter.go` | Modify | Add the envelope-over-error defense-in-depth gate at the GoImpl dispatch site. |
| `internal/stages/review/run_test.go` | Modify | Add `TestRunStage_PreservesPassEnvelopeOnSpecialistReworkFailure`. |
| `internal/stages/review/specialist_test.go` | Modify | Add `TestFinalizeApproved_SpecialistRunnerErrorDoesNotOverrideVerdict`. |
| `internal/stagerunner/adapter_test.go` | Modify | Add `TestAdapter_GoImplBothResultAndErrorPrefersResult`. |
| `tests/test_stage_envelope_overrides_subprocess_err.sh` | Create | Shim-boundary integration test (Goal 3). |
| `docs/v4-phase5-stub.md` | Modify | Document the envelope-over-error principle so the m38.6 / m39.x ports inherit it. |

---

## Acceptance Criteria

- [ ] `internal/stages/review/specialist.go`'s SpecialistRework branch
      no longer contains a `return nil, err` after the verdict is known.
      Verified by `grep -nE 'return nil, err' internal/stages/review/specialist.go`
      returning zero matches in the post-verdict block.
- [ ] Running `RunStage` with a stubbed agent emitting APPROVED_WITH_NOTES,
      a specialist runner producing blockers, AND a build-gate runner
      returning an error returns `(res, nil)` with `res.Verdict == VerdictPass`
      and `res.Metadata["subprocess_warnings"]` containing the error
      message. Verified by `TestRunStage_PreservesPassEnvelopeOnSpecialistReworkFailure`.
- [ ] `finalizeApproved` returns `approvedResult` (non-nil result, nil
      error) even when `specialistRunner.Run` returns a non-nil error.
      Verified by `TestFinalizeApproved_SpecialistRunnerErrorDoesNotOverrideVerdict`.
- [ ] `internal/stagerunner/adapter.go` contains an
      "envelope-over-error" gate that, when GoImpl returns both a
      non-nil result and a non-nil error, discards the error, records
      it on `result.Metadata["subprocess_warning"]`, and returns the
      result with `err == nil`. Verified by
      `TestAdapter_GoImplBothResultAndErrorPrefersResult`.
- [ ] A pipeline run with a forced build-gate exit-1 reports
      `disposition: success` when the reviewer verdict is APPROVED.
      Verified by `tests/test_stage_envelope_overrides_subprocess_err.sh`.
- [ ] After m47, an auto-advance run that produces an APPROVED_WITH_NOTES
      verdict on every milestone in its limit window flips every
      manifest entry to done WITHOUT the operator needing to manually
      flip. Verified by visual inspection of a multi-milestone
      auto-advance run after the fix.
- [ ] `RUN_RESULT.json` for a run with an APPROVED verdict + a
      subprocess-warning never reports `disposition: failure` or
      `error_class: review`. Verified by visual inspection +
      acceptance criterion above.
- [ ] No regression in existing tests:
      `internal/stages/review/...`, `internal/stagerunner/...`,
      `internal/runner/...`, `internal/finalize/...`.
- [ ] `shellcheck` clean on the new shim-boundary test file.
- [ ] `golangci-lint run ./internal/stages/review/... ./internal/stagerunner/...`
      and `go vet ./internal/stages/review/... ./internal/stagerunner/...`
      clean after the changes.
- [ ] Full suite passes: `bash tests/run_tests.sh` + `go test ./...`.

## Watch For

- **The classification table is the contract.** Eight sites today; each
  is either pre-parse (stays as error return) or post-parse (becomes
  envelope warning). Implementers MUST NOT collapse or expand the
  classification without updating the table. If a new site shows up
  during implementation (e.g. a sub-call added in the rework branch),
  classify it explicitly per the same pre-parse / post-parse rule.
- **The adapter-level gate is defense-in-depth, NOT the primary fix.**
  Goal 1 (source-level reclassification) eliminates the offending
  paths. Goal 2 (adapter gate) catches future regressions. Skipping
  Goal 1 and relying only on Goal 2 means the stage code still has
  the bug shape; that's a maintenance footgun.
- **The `subprocess_warnings` metadata key is plural for a reason** —
  multiple sub-calls can fail in one cycle (specialist runner AND
  build gate both error). Use a JSON array string format and append,
  not a single-value scalar. Document the format alongside the
  envelope proto.
- **Pre-parse errors are different.** A reviewer agent that fails to
  exec, a prompt template that can't render, a reviewer report file
  that doesn't exist — these legitimately prevent the stage from
  producing a verdict. Those MUST keep returning Go-level errors so
  the runner records `disposition: failure` correctly. The bug is NOT
  "all errors should be warnings"; it's "post-verdict errors should
  not override the verdict."
- **The tester stage will have the same shape after m38.6.** When the
  tester ports to Go, audit it for the same eight-site pattern.
  Document the principle in `docs/v4-phase5-stub.md` so the m38.6
  implementer applies it from day one.
- **CHANGES_REQUIRED verdict + build-gate failure is still a fail.**
  The post-parse envelope-warning rule applies when the verdict
  itself is APPROVED or APPROVED_WITH_NOTES. When the verdict is
  CHANGES_REQUIRED and a subprocess in the rework path fails, the
  envelope correctly reports CHANGES_REQUIRED — that's fail.
  The rule isn't "subprocess errors are always warnings"; it's
  "subprocess errors don't override the parsed verdict."
- **Specialist runner errors are a separate concern from specialist
  *blockers*.** A specialist runner that errors (exec fails, can't
  spawn the agent) is an infrastructure failure → warning. A specialist
  runner that successfully returns blockers is a content signal that
  must drive RouteSpecialistRework as today. Don't conflate the two.

## Seeds Forward

- **Tester stage parity (m38.6 prerequisite):** when the tester port
  lands, the m47 principle and the classification rule apply
  one-for-one. The implementer should audit `internal/stages/tester/`'s
  return-err sites the same way. Document this expectation in
  `docs/v4-phase5-stub.md`.
- **Envelope schema versioning:** the `subprocess_warnings` Metadata
  key is the first machine-readable warning channel on
  `StageResultV1`. A future arc could promote it to a typed
  `Warnings []StageWarning` field with structured fields (source
  sub-call, error class, error message, retry count). Tracked as
  Seeds Forward — not scheduled.
- **Operator-visible warnings in `RUN_SUMMARY.md`:** the
  `subprocess_warnings` metadata should surface in
  `RUN_SUMMARY.md`'s post-run banner so operators can see "the build
  gate flaked but the verdict was clean" without digging into
  `RUN_RESULT.json`. Light touch in `internal/finalize/emit_run_summary.go`.
- **Auto-advance per-milestone confirmation banner:** with m47 in
  place, the auto-advance loop can emit a one-liner per iteration:
  `✓ m38.5 verdict=pass committed=<hash>` or
  `⚠ m38.5 verdict=pass committed=<hash> warnings=2`. Makes the
  per-milestone success/warning state impossible to miss. Lands as
  part of the auto-advance polish arc, not m47.
- **Subprocess-warning rate as a reliability signal:** once
  `subprocess_warnings` are recorded, the metrics subsystem can
  surface their rate over time. A spike in build-gate-failure
  warnings on otherwise-passing runs signals an environment problem
  (CI runner flakiness, file-system pressure) that today is invisible
  because the warnings either get hidden (silent stage error) or get
  dropped on the floor (after m47, without metrics integration).
